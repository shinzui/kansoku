-- | Public servant API and DTOs for semantic metric queries.
module Kansoku.Api.Metrics
  ( MetricPoint (..),
    MetricQuery,
    MetricResult (..),
    MetricsAPI,
    TimeGrain (..),
    timeGrainText,
  )
where

import Data.Aeson qualified as Aeson
import Data.Map.Strict (Map)
import Data.Text qualified as Text
import Data.Time (Day)
import Kansoku.Prelude
import Servant.API
  ( Get,
    JSON,
    QueryParam,
    QueryParam',
    Required,
    type (:<|>),
    type (:>),
  )
import Web.HttpApiData (FromHttpApiData (..))

data TimeGrain = Hour | Day | Week | Month
  deriving stock (Generic, Eq, Ord, Show)

timeGrainText :: TimeGrain -> Text
timeGrainText = \case
  Hour -> "hour"
  Day -> "day"
  Week -> "week"
  Month -> "month"

parseTimeGrainText :: Text -> Maybe TimeGrain
parseTimeGrainText = \case
  "hour" -> Just Hour
  "day" -> Just Day
  "week" -> Just Week
  "month" -> Just Month
  _ -> Nothing

instance ToJSON TimeGrain where
  toJSON = Aeson.String . timeGrainText

instance FromJSON TimeGrain where
  parseJSON =
    Aeson.withText "TimeGrain" $ \value ->
      maybe (fail ("unknown time grain: " <> Text.unpack value)) pure (parseTimeGrainText value)

instance FromHttpApiData TimeGrain where
  parseUrlPiece value =
    maybe (Left ("unknown time grain: " <> value)) Right (parseTimeGrainText value)

data MetricPoint = MetricPoint
  { bucket :: !(Maybe Text),
    group :: !(Map Text Text),
    value :: !Double
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data MetricResult = MetricResult
  { metric :: !Text,
    points :: ![MetricPoint]
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

type MetricQuery =
  QueryParam' '[Required] "from" Day
    :> QueryParam' '[Required] "to" Day
    :> QueryParam "groupBy" Text
    :> QueryParam "timeGrain" TimeGrain
    :> Get '[JSON] MetricResult

type MetricsAPI =
  "metrics" :> "events" :> MetricQuery
    :<|> "metrics" :> "page-views" :> MetricQuery
    :<|> "metrics" :> "sessions" :> MetricQuery
    :<|> "metrics"
      :> "funnel"
      :> QueryParam' '[Required] "from" Day
      :> QueryParam' '[Required] "to" Day
      :> QueryParam' '[Required] "steps" Text
      :> Get '[JSON] MetricResult
    :<|> "metrics"
      :> "retention"
      :> QueryParam' '[Required] "from" Day
      :> QueryParam' '[Required] "to" Day
      :> QueryParam "days" Text
      :> Get '[JSON] MetricResult
    :<|> "metrics" :> "acquisition" :> MetricQuery
    :<|> "metrics" :> "feature-adoption" :> MetricQuery
    :<|> "metrics" :> "conversion" :> MetricQuery
    :<|> "metrics" :> "users" :> MetricQuery
    :<|> "metrics" :> "organizations" :> MetricQuery
    :<|> "metrics" :> "custom" :> MetricQuery
