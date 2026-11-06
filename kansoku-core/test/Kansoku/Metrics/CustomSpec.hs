module Kansoku.Metrics.CustomSpec (spec) where

import Control.Monad (forM_)
import Data.Aeson qualified as A
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Either (isLeft, isRight)
import Data.Text qualified as T
import Data.Time (fromGregorian)
import Kansoku.Event (AccountId (..), defaultRegistry)
import Kansoku.Metrics.Api (TimeGrain (..))
import Kansoku.Metrics.Custom
import Kansoku.Metrics.Definition
import Kansoku.Metrics.Filter qualified as F
import Kansoku.Metrics.Query qualified as Q
import Kansoku.Prelude
import Test.Hspec
import Web.HttpApiData (parseUrlPiece, toUrlPiece)

spec :: Spec
spec = describe "Custom metrics" $ do
  it "roundtrips exact grain spellings in JSON and URLs" $ do
    forM_ [Hour, Day, Week, Month, NoTimeBucket] $ \grain -> do
      A.eitherDecode (A.encode grain) `shouldBe` Right grain
      parseUrlPiece (toUrlPiece grain) `shouldBe` Right grain
    toUrlPiece NoTimeBucket `shouldBe` "none"
    A.toJSON NoTimeBucket `shouldBe` A.String "none"
    forM_ ["None", "notimebucket", "unknown", ""] $ \bad -> do
      (parseUrlPiece bad :: Either Text TimeGrain) `shouldSatisfy` isLeft
      (A.fromJSON (A.String bad) :: A.Result TimeGrain) `shouldSatisfy` (\case A.Error _ -> True; _ -> False)
  it "validates every aggregation, finite event scopes and declared numeric properties" $ do
    mapM_ (\kind -> adhoc "payment_completed" kind Nothing `shouldSatisfy` isRight) ["count", "unique_count"]
    mapM_ (\kind -> adhoc "payment_completed" kind (Just "amount") `shouldSatisfy` isRight) ["sum", "average"]
    mapM_
      (`shouldSatisfy` isLeft)
      [ adhoc "" "count" Nothing,
        adhoc "bad'name" "count" Nothing,
        adhoc "payment_completed" "sum" (Just "plan"),
        adhoc "payment_completed,feature_used" "sum" (Just "amount"),
        adhoc "payment_completed" "sum" Nothing,
        adhoc "payment_completed" "count" (Just "amount"),
        adhoc "payment_completed" "unknown" Nothing
      ]
  it "validates percentile quantiles and rejects ratio components and irrelevant quantiles" $ do
    let percentile = base {aggregation = Percentile, aggregationProperty = Just "amount", quantile = Just 0.75}
    validateCustom defaultRegistry (CustomSimple percentile) `shouldBe` Right ()
    forM_ [Nothing, Just 0, Just 1, Just (-0.1), Just 1.1, Just (0 / 0), Just (1 / 0), Just (-1 / 0)] $ \q -> do
      let def = CustomSimple percentile {quantile = q}
      validateCustom defaultRegistry def `shouldSatisfy` isLeft
      Q.buildSQL defaultRegistry (customBuiltin def) request `shouldSatisfy` isLeft
    forM_ [Count, UniqueCount, Sum, Average] $ \kind -> do
      let def = CustomSimple percentile {aggregation = kind}
      validateCustom defaultRegistry def `shouldSatisfy` isLeft
      Q.buildSQL defaultRegistry (customBuiltin def) request `shouldSatisfy` isLeft
    forM_ [percentile {aggregationProperty = Nothing}, percentile {aggregationProperty = Just "plan"}] $ \def ->
      validateCustom defaultRegistry (CustomSimple def) `shouldSatisfy` isLeft
    forM_ [(percentile, base), (base, percentile)] $ \(n, d) -> do
      let def = CustomRatio (RatioMetric "rate" Nothing n d)
      validateCustom defaultRegistry def `shouldSatisfy` isLeft
      Q.buildSQL defaultRegistry (customBuiltin def) request `shouldSatisfy` isLeft
    adHocDefinition (Just "payment_completed") (Just "percentile") (Just "amount") (Just 0.75) (Just "feature_used") Nothing `shouldSatisfy` isLeft
    adHocDefinition (Just "payment_completed") (Just "count") (Just "amount") Nothing (Just "feature_used") (Just "percentile") `shouldSatisfy` isLeft
  it "roundtrips percentile and legacy JSON and compiles the exact native aggregate" $ do
    let percentile = base {aggregation = Percentile, aggregationProperty = Just "amount", quantile = Just 0.75}
    forM_ [base, base {aggregation = Sum, aggregationProperty = Just "amount"}, base {aggregation = Average, aggregationProperty = Just "amount"}, percentile] $ \def ->
      A.eitherDecode (A.encode (CustomSimple def)) `shouldBe` Right (CustomSimple def)
    A.toJSON base `shouldSatisfy` (\case A.Object fields -> not (KeyMap.member "quantile" fields); _ -> False)
    sql <- either (fail . show) pure (Q.buildSQL defaultRegistry (customBuiltin (CustomSimple percentile)) request)
    sql `shouldSatisfy` T.isInfixOf "quantileExactInclusive(0.75)("
    sql `shouldSatisfy` T.isInfixOf "isNotNull("
    sql `shouldSatisfy` T.isInfixOf "analytics.events_canonical"
    sql `shouldSatisfy` T.isInfixOf "account_id = {account_id:String}"
  it "keeps saved defaults, conjoins filters and honors request overrides within the combined bound" $ do
    let def = CustomSimple base {filters = ["source:eq:web|source:eq:app"], groupBy = ["prop:plan"], timeGrain = Just Day}
    validateCustom defaultRegistry def `shouldBe` Right ()
    input <- either (fail . T.unpack) pure (F.parseMetricFilter "source_service:eq:billing")
    result <- either (fail . T.unpack) pure (customRequest def request {Q.filters = [input], Q.groupBy = Just ["source"]})
    Q.groupBy result `shouldBe` Just ["source"]
    Q.timeGrain result `shouldBe` Just Day
    length (Q.filters result) `shouldBe` 2
    customRequest def request {Q.filters = replicate 8 input} `shouldSatisfy` isLeft
    sql <- either (fail . show) pure (Q.buildSQL defaultRegistry (customBuiltin def) result)
    sql `shouldSatisfy` T.isInfixOf " OR "
    sql `shouldSatisfy` T.isInfixOf "account_id = {account_id:String}"
  it "preserves explicit whole-range grains and saved override precedence" $ do
    forM_ [Nothing, Just Day, Just NoTimeBucket] $ \saved -> do
      let def = CustomSimple base {timeGrain = saved}
      A.eitherDecode (A.encode def) `shouldBe` Right def
      forM_ [Nothing, Just Day, Just NoTimeBucket] $ \requested -> do
        result <- either (fail . T.unpack) pure (customRequest def request {Q.timeGrain = requested})
        Q.timeGrain result `shouldBe` (requested <|> saved)
    let ratio = CustomRatio (RatioMetric "rate" Nothing base base)
    customRequest ratio request {Q.timeGrain = Just NoTimeBucket} `shouldSatisfy` isLeft
    validateCustom defaultRegistry (CustomRatio (RatioMetric "rate" Nothing base {timeGrain = Just NoTimeBucket} base)) `shouldSatisfy` isLeft
  it "does not dispatch custom names through builtin sessions/conversion special cases" $ do
    let def = CustomSimple base {name = "sessions"}
    sql <- either (fail . show) pure (Q.buildSQL defaultRegistry (customBuiltin def) request)
    sql `shouldSatisfy` T.isInfixOf "count(DISTINCT event_id)"
    let ratio = CustomRatio (RatioMetric "conversion_rate" Nothing base base)
    validateCustom defaultRegistry ratio `shouldBe` Right ()
    customRequest ratio request {Q.timeGrain = Just Day} `shouldSatisfy` isLeft
    Q.buildSQL defaultRegistry (customBuiltin ratio) request `shouldSatisfy` isRight
  it "roundtrips simple and ratio wire shapes without constructor tags" $ do
    let simple = CustomSimple base
        ratio = CustomRatio (RatioMetric "rate" Nothing base base)
    mapM_ (\def -> A.eitherDecode (A.encode def) `shouldBe` Right def) [simple, ratio]
  where
    adhoc events aggregation property = adHocDefinition (Just events) (Just aggregation) property Nothing Nothing Nothing >>= \def -> def <$ validateCustom defaultRegistry def

base :: MetricDefinition
base = MetricDefinition "payments" Nothing ["payment_completed"] Count Nothing Nothing [] [] Nothing

request :: Q.QueryRequest
request = Q.QueryRequest (AccountId "custom") (fromGregorian 2026 7 1) (fromGregorian 2026 7 2) Nothing Nothing [] [] False False False
