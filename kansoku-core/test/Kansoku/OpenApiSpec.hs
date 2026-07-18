module Kansoku.OpenApiSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Foldable qualified as Foldable
import Data.Text qualified as Text
import Kansoku.OpenApi (openApiDoc)
import Kansoku.Prelude
import Test.Hspec

spec :: Spec
spec = describe "Kansoku.OpenApi.openApiDoc" $ do
  it "reports OpenAPI 3.1" $
    lookupText ["openapi"] documentValue `shouldSatisfy` maybe False (Text.isPrefixOf "3.1")

  it "includes ingestion and metrics paths" $ do
    let paths = objectAt ["paths"] documentValue
    paths `shouldSatisfy` hasKey "/v1/events"
    paths `shouldSatisfy` hasKey "/v1/batch"
    paths `shouldSatisfy` anyKeyWithPrefix "/metrics"

  it "includes the AnalyticsEvent component schema" $ do
    let schemas = objectAt ["components", "schemas"] documentValue
    schemas `shouldSatisfy` hasKey "AnalyticsEvent"

  it "declares the shared error envelope and 400/404/503 on every operation" $ do
    let schemas = objectAt ["components", "schemas"] documentValue
    schemas `shouldSatisfy` hasKey "ErrorEnvelopeWire"
    operationValues documentValue `shouldSatisfy` (not . null)
    operationValues documentValue
      `shouldSatisfy` all
        (\operation -> all (\status -> hasKey status (objectAt ["responses"] operation)) ["400", "404", "503"])

  it "describes event IDs as strings and event sources as lowercase wire tags" $ do
    lookupText ["components", "schemas", "EventId", "type"] documentValue `shouldBe` Just "string"
    lookupTextArray ["components", "schemas", "EventSource", "enum"] documentValue `shouldSatisfy` maybe False (elem "web")

  it "describes TimeGrain parameters as lowercase wire tags" $
    documentValue `shouldSatisfy` containsEnumValue "hour"

documentValue :: Aeson.Value
documentValue = Aeson.toJSON openApiDoc

lookupText :: [Text] -> Aeson.Value -> Maybe Text
lookupText path value =
  case valueAt path value of
    Just (Aeson.String text) -> Just text
    _ -> Nothing

lookupTextArray :: [Text] -> Aeson.Value -> Maybe [Text]
lookupTextArray path value =
  case valueAt path value of
    Just (Aeson.Array values) -> Just [text | Aeson.String text <- Foldable.toList values]
    _ -> Nothing

objectAt :: [Text] -> Aeson.Value -> Aeson.Object
objectAt path value =
  case valueAt path value of
    Just (Aeson.Object object) -> object
    _ -> mempty

valueAt :: [Text] -> Aeson.Value -> Maybe Aeson.Value
valueAt [] value = Just value
valueAt (key : rest) (Aeson.Object object) =
  KeyMap.lookup (Key.fromText key) object >>= valueAt rest
valueAt _ _ = Nothing

hasKey :: Text -> Aeson.Object -> Bool
hasKey key =
  KeyMap.member (Key.fromText key)

anyKeyWithPrefix :: Text -> Aeson.Object -> Bool
anyKeyWithPrefix prefix =
  any (Text.isPrefixOf prefix . Key.toText) . KeyMap.keys

containsEnumValue :: Text -> Aeson.Value -> Bool
containsEnumValue expected = \case
  Aeson.Object object ->
    enumHasExpected object || any (containsEnumValue expected) object
  Aeson.Array values ->
    any (containsEnumValue expected) values
  _ ->
    False
  where
    enumHasExpected object =
      case KeyMap.lookup "enum" object of
        Just (Aeson.Array values) ->
          expected `elem` [text | Aeson.String text <- Foldable.toList values]
        _ ->
          False

operationValues :: Aeson.Value -> [Aeson.Value]
operationValues value =
  [ operation
  | pathItem <- objectValues (objectAt ["paths"] value),
    (method, operation) <- KeyMap.toList pathItem,
    Key.toText method `elem` (["get", "post", "put", "patch", "delete"] :: [Text])
  ]

objectValues :: Aeson.Object -> [Aeson.Object]
objectValues object =
  [ nested
  | Aeson.Object nested <- KeyMap.elems object
  ]
