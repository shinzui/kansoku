-- | Semantic metric definitions shared by the metrics registry and query compiler.
module Kansoku.Metrics.Definition
  ( Aggregation (..),
    MetricDefinition (..),
    RatioMetric (..),
  )
where

import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.Map.Strict (Map)
import Data.Text qualified as Text
import Kansoku.Api.Metrics (TimeGrain)
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
    filters :: !(Map Text Value),
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
