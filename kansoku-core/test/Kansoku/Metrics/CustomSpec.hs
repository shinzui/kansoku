module Kansoku.Metrics.CustomSpec (spec) where

import Data.Aeson qualified as A
import Data.Either (isLeft, isRight)
import Data.Text qualified as T
import Data.Time (fromGregorian)
import Kansoku.Event (AccountId (..), defaultRegistry)
import Kansoku.Metrics.Api (TimeGrain (Day))
import Kansoku.Metrics.Custom
import Kansoku.Metrics.Definition
import Kansoku.Metrics.Filter qualified as F
import Kansoku.Metrics.Query qualified as Q
import Kansoku.Prelude
import Test.Hspec

spec :: Spec
spec = describe "Custom metrics" $ do
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
    adhoc events aggregation property = adHocDefinition (Just events) (Just aggregation) property Nothing Nothing >>= \def -> def <$ validateCustom defaultRegistry def

base :: MetricDefinition
base = MetricDefinition "payments" Nothing ["payment_completed"] Count Nothing [] [] Nothing

request :: Q.QueryRequest
request = Q.QueryRequest (AccountId "custom") (fromGregorian 2026 7 1) (fromGregorian 2026 7 2) Nothing Nothing [] [] False False False
