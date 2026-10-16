-- | Semantic metric definitions shared by the metrics registry and query compiler.
module Kansoku.Metrics.Definition
  ( Aggregation (..),
    MetricDefinition (..),
    RatioMetric (..),
    CustomDefinition (..),
    SavedMetric (..),
    parseAggregationText,
    customName,
  )
where

import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Text qualified as Text
import Data.UUID (UUID)
import Kansoku.Metrics.Api (TimeGrain)
import Kansoku.Prelude

data Aggregation = Count | UniqueCount | Sum | Average | Ratio
  deriving stock (Generic, Eq, Ord, Show)

aggregationText :: Aggregation -> Text
aggregationText = \case
  Count -> "count"
  UniqueCount -> "unique_count"
  Sum -> "sum"
  Average -> "average"
  Ratio -> "ratio"

parseAggregationText :: Text -> Maybe Aggregation
parseAggregationText = \case
  "count" -> Just Count
  "unique_count" -> Just UniqueCount
  "sum" -> Just Sum
  "average" -> Just Average
  "ratio" -> Just Ratio
  _ -> Nothing

instance ToJSON Aggregation where
  toJSON = Aeson.String . aggregationText

instance FromJSON Aggregation where
  parseJSON =
    Aeson.withText "Aggregation" $ \value ->
      maybe (fail ("unknown aggregation: " <> Text.unpack value)) pure (parseAggregationText value)

data MetricDefinition = MetricDefinition
  { name :: !Text,
    description :: !(Maybe Text),
    eventNames :: ![Text],
    aggregation :: !Aggregation,
    aggregationProperty :: !(Maybe Text),
    filters :: ![Text],
    groupBy :: ![Text],
    timeGrain :: !(Maybe TimeGrain)
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data RatioMetric = RatioMetric
  { name :: !Text,
    description :: !(Maybe Text),
    numerator :: !MetricDefinition,
    denominator :: !MetricDefinition
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | Untagged wire union: a simple definition, or numerator/denominator definitions.
data CustomDefinition = CustomSimple !MetricDefinition | CustomRatio !RatioMetric
  deriving stock (Generic, Eq, Show)

instance ToJSON CustomDefinition where
  toJSON (CustomSimple x) = toJSON x
  toJSON (CustomRatio x) = toJSON x

instance FromJSON CustomDefinition where
  parseJSON value =
    Aeson.withObject
      "metric definition"
      ( \o -> do
          let ratio = KeyMap.member "numerator" o || KeyMap.member "denominator" o
              allowed = if ratio then ["name", "description", "numerator", "denominator"] else ["name", "description", "eventNames", "aggregation", "aggregationProperty", "filters", "groupBy", "timeGrain"]
          unless (all (`elem` allowed) (KeyMap.keys o)) (fail "unexpected or mixed metric definition fields")
          if ratio then CustomRatio <$> Aeson.parseJSON value else CustomSimple <$> Aeson.parseJSON value
      )
      value

customName :: CustomDefinition -> Text
customName (CustomSimple MetricDefinition {name}) = name
customName (CustomRatio RatioMetric {name}) = name

data SavedMetric = SavedMetric {id :: !UUID, definition :: !CustomDefinition, createdAt :: !UTCTime, updatedAt :: !UTCTime}
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)
