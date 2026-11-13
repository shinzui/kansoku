module Kansoku.Analysis.Validation (ValidatedAnalysis (..), validateAnalysis) where

import Data.Aeson qualified as A
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Kansoku.Analysis.Types
import Kansoku.Prelude

data ValidatedAnalysis = ValidatedAnalysis {input :: !AnalysisInput, documentText :: !Text}
  deriving stock (Eq, Show)

validateAnalysis :: AnalysisInput -> Either Text ValidatedAnalysis
validateAnalysis AnalysisInput {name, description, kind, documentVersion, document} = do
  let trimmed = Text.strip name
      encoded = LBS.toStrict (A.encode document)
  unless (Text.length trimmed >= 1 && Text.length trimmed <= 120) (Left "name: expected 1..120 Unicode characters after trimming")
  when (Text.any (== '\0') trimmed) (Left "name: zero characters are not supported")
  case description of
    Just text -> do
      when (Text.length text > 500) (Left "description: maximum 500 Unicode characters")
      when (Text.any (== '\0') text) (Left "description: zero characters are not supported")
    Nothing -> pure ()
  unless (documentVersion > 0) (Left "documentVersion: expected a positive integer")
  case document of A.Object _ -> pure (); _ -> Left "document: expected a JSON object"
  when (BS.length encoded > 32768) (Left "document: compact UTF-8 encoding exceeds 32768 bytes")
  pure (ValidatedAnalysis (AnalysisInput trimmed description kind documentVersion document) (Text.decodeUtf8 encoded))
