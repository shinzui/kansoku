module Kansoku.Metrics.FilterSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as LBS
import Data.Either (isLeft, isRight)
import Data.Foldable (traverse_)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time (fromGregorian)
import Effectful (runEff)
import Kansoku.Event (AccountId (..), EventName (..), EventSchema (..), PropertySpec (..), PropertyType (..), defaultRegistry, registerSchema)
import Kansoku.Metrics.Filter qualified as Filter
import Kansoku.Metrics.Query qualified as Query
import Kansoku.Metrics.Query.Filter qualified as Compile
import Kansoku.Metrics.Registry (BuiltinMetric (..), events)
import Kansoku.Metrics.RequestValidation (validateMetricRequest)
import Kansoku.Prelude
import Network.Wai (defaultRequest, pathInfo, queryString, rawPathInfo)
import Test.Hspec
import Web.HttpApiData (toUrlPiece)

spec :: Spec
spec = describe "Kansoku.Metrics filters" $ do
  it "roundtrips every operator and arbitrary scalar text through URL JSON" $ do
    let inputs =
          [ "{\"dimension\":\"source\",\"op\":\"eq\",\"value\":\"web\"}",
            "{\"dimension\":\"source\",\"op\":\"neq\",\"value\":\"\"}",
            "{\"dimension\":\"source\",\"op\":\"in\",\"value\":[\"web\",\"app\"]}",
            "{\"dimension\":\"prop:plan\",\"op\":\"contains\",\"value\":\"é:|,\\\"\\\\\"}",
            "{\"dimension\":\"prop:amount\",\"op\":\"gt\",\"value\":2.5}",
            "{\"dimension\":\"prop:amount\",\"op\":\"lt\",\"value\":0}",
            "{\"dimension\":\"prop:plan\",\"op\":\"set\"}",
            "{\"dimension\":\"prop:plan\",\"op\":\"unset\"}"
          ]
    traverse_
      ( \raw -> do
          input <- validFilter raw
          Filter.parseMetricFilter (toUrlPiece input) `shouldBe` Right input
      )
      inputs

  it "rejects unknown keys, null operands, malformed arrays and incompatible operators" $
    traverse_
      (\raw -> Filter.parseMetricFilter raw `shouldSatisfy` isLeft)
      [ "{}",
        "null",
        "[]",
        "{\"dimension\":\"source\",\"op\":\"eq\",\"value\":null}",
        "{\"dimension\":\"source\",\"op\":\"eq\",\"value\":\"web\",\"extra\":true}",
        "{\"dimension\":\"source\",\"op\":\"set\",\"value\":null}",
        "{\"dimension\":\"source\",\"op\":\"in\",\"value\":[]}",
        "{\"dimension\":\"source\",\"op\":\"in\",\"value\":[1,\"1\"]}",
        "{\"dimension\":\"source\",\"op\":\"in\",\"value\":[null]}",
        "{\"dimension\":\"source\",\"op\":\"contains\",\"value\":1}",
        "{\"dimension\":\"source\",\"op\":\"gt\",\"value\":\"1\"}",
        "{\"dimension\":\"prop:amount\",\"op\":\"gt\",\"value\":1e9999}",
        "{\"dimension\":\"source\",\"op\":\"whatever\",\"value\":true}"
      ]

  it "enforces UTF-8 string, array, count and original decoded-byte boundaries" $ do
    let stringInput size = jsonFilter "source" "eq" (Aeson.String (Text.replicate size "é"))
        arrayInput size = jsonFilter "source" "in" (Aeson.toJSON (replicate size ("web" :: Text)))
        base = "{\"dimension\":\"source\",\"op\":\"eq\",\"value\":\"web\"}"
        padded bytes = Text.replicate (bytes - Text.length base) " " <> base
    Filter.parseMetricFilter (stringInput 512) `shouldSatisfy` isRight
    Filter.parseMetricFilter (stringInput 513) `shouldSatisfy` isLeft
    Filter.parseMetricFilter (arrayInput 100) `shouldSatisfy` isRight
    Filter.parseMetricFilter (arrayInput 101) `shouldSatisfy` isLeft
    input <- validFilter base
    Filter.validateMetricFilters (replicate 9 input) `shouldSatisfy` isLeft
    exact <- traverse validFilter (replicate 8 (padded 2048))
    Filter.validateMetricFilters exact `shouldSatisfy` isRight
    above <- traverse validFilter (padded 2049 : replicate 7 (padded 2048))
    Filter.validateMetricFilters above `shouldSatisfy` isLeft

  it "binds punctuation and Unicode operands instead of placing them in SQL" $ do
    let operand = "unique' OR 1=1 --\\|,é"
    input <- validFilter (jsonFilter "prop:plan" "eq" (Aeson.String operand))
    compiled <- either (fail . Text.unpack) pure (Compile.compileMetricFilters defaultRegistry [EventName "payment_completed"] [input])
    Compile.parameters compiled `shouldBe` [("metric_filter_1_1", operand)]
    Text.unlines (Compile.predicates compiled) `shouldSatisfy` (not . Text.isInfixOf operand)

  it "requires a positive finite event scope and rejects invalid filters before pool checkout" $ do
    property <- validFilter (jsonFilter "prop:plan" "eq" (Aeson.String "pro"))
    scope <- validFilter (jsonFilter "event_name" "in" (Aeson.toJSON (["payment_completed"] :: [Text])))
    invalid <- runEff (Query.run defaultRegistry (error "invalid filters borrowed the pool") (Simple events) request {Query.filters = [property]})
    case invalid of
      Left (Query.QueryCompileFailure failure) -> Query.queryCompileErrorCode failure `shouldBe` "invalid_filter"
      other -> expectationFailure (show other)
    Query.buildSQL defaultRegistry (Simple events) request {Query.filters = [scope, property]} `shouldSatisfy` isRight

  it "checks scalar declarations across versions and does not treat PTAny as numeric" $ do
    numeric <- validFilter (jsonFilter "prop:amount" "gt" (Aeson.Number 1))
    let schema version kind = EventSchema (EventName "versioned_probe") version "type fixture" [PropertySpec "amount" kind False Nothing Nothing]
        registry firstKind = registerSchema (schema 2 PTNumber) (registerSchema (schema 1 firstKind) defaultRegistry)
        compile firstKind = Compile.compileMetricFilters (registry firstKind) [EventName "versioned_probe"] [numeric]
    compile PTString `shouldSatisfy` isLeft
    compile PTAny `shouldSatisfy` isLeft
    compile PTNumber `shouldSatisfy` isRight

  it "rejects parameters that a route cannot apply and permits repeated canonical filters" $ do
    input <- validFilter (jsonFilter "source" "eq" (Aeson.String "web"))
    let req endpoint query = defaultRequest {pathInfo = [], rawPathInfo = Text.encodeUtf8 ("/metrics/" <> endpoint), queryString = query}
        encoded = Just (Text.encodeUtf8 (toUrlPiece input))
    validateMetricRequest (req "events" [("filter", encoded), ("filter", encoded)]) `shouldBe` Right ()
    validateMetricRequest (req "funnel" [("groupBy", Just "source"), ("exclude", Just "a"), ("exclude", Just "a")]) `shouldBe` Right ()
    traverse_
      (\candidate -> validateMetricRequest candidate `shouldSatisfy` isLeft)
      [ req "events" [("typo", Just "value")],
        req "events" [("groupBy", Just "source"), ("groupBy", Just "route")],
        req "events" [("filter[]", encoded)],
        req "events" [("filter", Nothing)],
        req "events" [("groupBy", Nothing)],
        req "sessions" [("attribution", Just "event")],
        req "funnel" [("timeGrain", Just "day")]
      ]
  where
    request = Query.QueryRequest (AccountId "filters-unit") (fromGregorian 2026 7 1) (fromGregorian 2026 7 2) Nothing Nothing [] [] False

validFilter :: Text -> IO Filter.MetricFilter
validFilter = either (fail . Text.unpack) pure . Filter.parseMetricFilter

jsonFilter :: Text -> Text -> Aeson.Value -> Text
jsonFilter dimension operator operand =
  Text.decodeUtf8 . LBS.toStrict . Aeson.encode $
    Aeson.object ["dimension" Aeson..= dimension, "op" Aeson..= operator, "value" Aeson..= operand]
