module Kansoku.Query.ValidateSpec (spec) where

import Data.Either (isRight)
import Data.Foldable (toList, traverse_)
import Data.Text qualified as Text
import Kansoku.Metrics.Definition (MetricDefinition (..), RatioMetric (..))
import Kansoku.Metrics.Query.Validate
import Kansoku.Metrics.Registry (BuiltinMetric (..), builtinMetrics)
import Kansoku.Prelude
import Test.Hspec

spec :: Spec
spec = describe "Kansoku.Metrics.Query.Validate" $ do
  it "bounds raw contained-event lists, trims, deduplicates and accepts undeclared names" $ do
    validateSessionContainsEvents Nothing `shouldBe` Right []
    validateSessionContainsEvents (Just [" client_error ", "client_error", "not_declared"]) `shouldBe` Right (map expectSqlName ["client_error", "not_declared"])
    validateSessionContainsEvents (Just (replicate 20 "a")) `shouldBe` Right [expectSqlName "a"]
    validateSessionContainsEvents (Just [Text.replicate 128 "a"]) `shouldSatisfy` isRight
    traverse_
      (\names -> validateSessionContainsEvents (Just names) `shouldSatisfy` either ((== "invalid_contains_event") . limitCode) (const False))
      [[], [""], [" "], ["a", ""], ["", "a"], ["a", "", "b"], ["A"], ["é"], ["a١"], ["bad'name"], [Text.replicate 129 "a"], replicate 21 "a"]

  it "accepts the metric SQL name charset through the 128-character boundary" $
    traverse_
      (\value -> mkSqlName value `shouldBe` Right (expectSqlName value))
      [ "page_view",
        "signup_completed",
        "a",
        "x.y:z-1",
        Text.replicate 128 "a"
      ]

  it "rejects empty, overlong, uppercase, whitespace, escapes, and SQL syntax" $
    traverse_
      (\value -> mkSqlName value `shouldBe` Left value)
      [ "",
        Text.replicate 129 "a",
        "Robert'); DROP TABLE analytics.events_raw;--",
        "page view",
        "PageView",
        "page_view\\",
        "page\nview"
      ]

  it "accepts every event name in the built-in metric registry" $
    traverse_ (\value -> mkSqlName value `shouldSatisfy` isRight) registryEventNames

expectSqlName :: Text -> SqlName
expectSqlName value =
  case mkSqlName value of
    Right name -> name
    Left invalid -> error ("test fixture should be a valid SQL name: " <> Text.unpack invalid)

registryEventNames :: [Text]
registryEventNames = concatMap metricEventNames (toList builtinMetrics)

metricEventNames :: BuiltinMetric -> [Text]
metricEventNames = \case
  Simple MetricDefinition {eventNames} -> eventNames
  Ratioed
    RatioMetric
      { numerator = MetricDefinition {eventNames = numeratorNames},
        denominator = MetricDefinition {eventNames = denominatorNames}
      } ->
      numeratorNames <> denominatorNames
