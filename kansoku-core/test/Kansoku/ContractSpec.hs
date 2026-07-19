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
          actualVersions = [version | EventSchema {schemaVersion = version} <- schemas]
      actualVersions `shouldBe` [1 .. length schemas]
      forM_ schemas $ \EventSchema {schemaEventName, schemaNote, schemaProperties} -> do
        schemaEventName `shouldBe` eventName
        schemaNote `shouldSatisfy` (not . Text.null)
        let propertyNames = [propName | PropertySpec {propName} <- schemaProperties]
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
