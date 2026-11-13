-- | Opaque, account-owned client documents. Kansoku never executes these values.
module Kansoku.Analysis.Types where

import Data.Aeson qualified as A
import Data.Int (Int64)
import Data.Text qualified as Text
import Data.UUID (UUID)
import Kansoku.Prelude
import Servant.API (FromHttpApiData (..), ToHttpApiData (..))
import Text.Read (readMaybe)

data AnalysisKind = Trends | Funnel | Retention
  deriving stock (Generic, Eq, Show)

kindText :: AnalysisKind -> Text
kindText = \case Trends -> "trends"; Funnel -> "funnel"; Retention -> "retention"

instance FromHttpApiData AnalysisKind where
  parseUrlPiece = \case
    "trends" -> Right Trends
    "funnel" -> Right Funnel
    "retention" -> Right Retention
    _ -> Left "kind: expected trends, funnel, or retention"

instance ToHttpApiData AnalysisKind where toUrlPiece = kindText

instance ToJSON AnalysisKind where toJSON = A.String . kindText

instance FromJSON AnalysisKind where
  parseJSON = A.withText "kind" (either (fail . Text.unpack) pure . parseUrlPiece)

-- | PostgreSQL bigint, always positive. Increment is checked by the store.
newtype Revision = Revision {unRevision :: Int64}
  deriving stock (Generic, Eq, Show)
  deriving newtype (ToJSON)

instance FromJSON Revision where
  parseJSON value = do
    n <- parseJSON value
    if n > 0 then pure (Revision n) else fail "revision: expected a positive bigint"

instance FromHttpApiData Revision where
  parseUrlPiece raw = case readMaybe (Text.unpack raw) of
    Just n | n > 0 -> Right (Revision n)
    _ -> Left "revision: expected a positive bigint"

instance ToHttpApiData Revision where toUrlPiece = Text.pack . show . unRevision

data AnalysisInput = AnalysisInput
  { name :: !Text,
    description :: !(Maybe Text),
    kind :: !AnalysisKind,
    documentVersion :: !Integer,
    document :: !A.Value
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data AnalysisReplace = AnalysisReplace
  { name :: !Text,
    description :: !(Maybe Text),
    kind :: !AnalysisKind,
    documentVersion :: !Integer,
    document :: !A.Value,
    revision :: !Revision
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

replacementInput :: AnalysisReplace -> AnalysisInput
replacementInput AnalysisReplace {name, description, kind, documentVersion, document} = AnalysisInput {name, description, kind, documentVersion, document}

data SavedAnalysis = SavedAnalysis
  { id :: !UUID,
    name :: !Text,
    description :: !(Maybe Text),
    kind :: !AnalysisKind,
    documentVersion :: !Integer,
    document :: !A.Value,
    revision :: !Revision,
    createdAt :: !UTCTime,
    updatedAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)
