module Kansoku.ContractSpec (spec) where

import Data.Aeson qualified as Aeson
import Data.Foldable (forM_)
import Data.List (nub)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Kansoku.Event
import Kansoku.Prelude
import System.Directory (doesFileExist)
import Test.Hspec

spec :: Spec
spec = describe "Kansoku event schema contract" $ do
  it "matches the committed contract artifact" $ do
    path <- contractArtifactPath
    decoded <- Aeson.eitherDecodeFileStrict' path
    committed <-
      case decoded of
        Left err -> expectationFailure ("could not decode " <> path <> ": " <> err) >> fail err
        Right value -> pure (value :: Aeson.Value)
    unless (committed == Aeson.toJSON (schemaCatalog defaultRegistry)) $
      expectationFailure
        "docs/contracts/events.json is stale - run `cabal run kansoku-contracts` from the repo root and commit the result."

  it "keeps registry versions contiguous and schema metadata internally consistent" $ do
    let EventRegistry registry = defaultRegistry
    forM_ (Map.toList registry) $ \(eventName, versions) -> do
      let schemas = NonEmpty.toList versions
          actualVersions = [version | EventSchema {version} <- schemas]
      actualVersions `shouldBe` [1 .. length schemas]
      forM_ schemas $ \EventSchema {eventName, note, properties} -> do
        eventName `shouldBe` eventName
        note `shouldSatisfy` (not . Text.null)
        let propertyNames = [name | PropertySpec {name} <- properties]
        length propertyNames `shouldBe` length (nub propertyNames)

  it "publishes the landed experiment property pattern" $ do
    let SchemaCatalog {events} = schemaCatalog defaultRegistry
        publishedPatterns =
          case Map.lookup "experiment_viewed" events of
            Nothing -> []
            Just (EventVersions versions) ->
              [ value
              | VersionedEventSchema {properties} <- NonEmpty.toList versions,
                ContractProperty {validationPattern = Just value} <- properties
              ]
    publishedPatterns `shouldBe` ["[a-z0-9_.:-]{1,128}", "[a-z0-9_.:-]{1,128}"]

  it "publishes the same closed identifier vocabulary the validator accepts" $ do
    let SchemaCatalog {identifierKinds} = schemaCatalog defaultRegistry
    identifierKinds `shouldBe` allowedIdentifierKindNames
    identifierKinds `shouldContain` ["email_hmac"]

  it "publishes bounded error labels, privacy guidance, vital vocabulary and units" $ do
    let SchemaCatalog {catalogVersion, events} = schemaCatalog defaultRegistry
        schema name = case Map.lookup name events of
          Just (EventVersions (value :| [])) -> pure value
          _ -> expectationFailure "expected exactly version 1" >> fail "missing schema"
    catalogVersion `shouldBe` 5
    VersionedEventSchema {version, note, properties} <- schema "client_error"
    version `shouldBe` 1
    note `shouldSatisfy` Text.isInfixOf "do not send stack traces or personal data"
    [(name, propertyType, required, minLength, maxLength) | ContractProperty {name, propertyType, required, minLength, maxLength} <- properties]
      `shouldBe` [("message", "string", True, Just 1, Just 256), ("type", "string", True, Just 1, Just 128), ("handled", "bool", True, Nothing, Nothing)]
    forM_ properties $ \ContractProperty {description} ->
      description `shouldSatisfy` maybe False (Text.isInfixOf "Do not send stack traces or personal data" . Text.replace "do not" "Do not")
    VersionedEventSchema {properties = vitals} <- schema "web_vital"
    [(name, propertyType, required, validationPattern, minimum, maxLength) | ContractProperty {name, propertyType, required, validationPattern, minimum, maxLength} <- vitals]
      `shouldBe` [("metric", "string", True, Just "^(LCP|INP|CLS|FCP|TTFB)$", Nothing, Nothing), ("value", "number", True, Nothing, Just 0, Nothing)]
    [description | ContractProperty {name = "value", description} <- vitals]
      `shouldSatisfy` all (maybe False (\value -> Text.isInfixOf "milliseconds for LCP, INP, FCP and TTFB" value && Text.isInfixOf "unitless for CLS" value))

  it "decodes legacy catalog properties without maxLength and omits absent bounds" $ do
    let payload = "{\"name\":\"url\",\"type\":\"string\",\"required\":true}"
    case Aeson.eitherDecode payload of
      Left err -> expectationFailure err
      Right property@ContractProperty {maxLength} -> do
        maxLength `shouldBe` Nothing
        Aeson.toJSON property `shouldBe` Aeson.object ["name" Aeson..= ("url" :: Text), "type" Aeson..= ("string" :: Text), "required" Aeson..= True]

  it "round-trips the SDK-facing catalog JSON" $ do
    let catalog = schemaCatalog defaultRegistry
    Aeson.decode (Aeson.encode catalog) `shouldBe` Just catalog

contractArtifactPath :: IO FilePath
contractArtifactPath =
  findExisting
    [ "docs/contracts/events.json",
      "../docs/contracts/events.json",
      "../../docs/contracts/events.json"
    ]
  where
    findExisting [] = expectationFailure "could not locate docs/contracts/events.json" >> fail "missing contract artifact"
    findExisting (candidate : rest) = do
      exists <- doesFileExist candidate
      if exists then pure candidate else findExisting rest
