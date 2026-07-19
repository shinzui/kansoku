-- | Public servant API and DTOs for semantic metric queries.
module Kansoku.Metrics.Api
  ( MetricPoint (..),
    MetricQuery,
    MetricResult (..),
    MetricsRoutes (..),
    TimeGrain (..),
    timeGrainText,
  )
where

import Data.Aeson qualified as Aeson
import Data.Map.Strict (Map)
import Data.Text qualified as Text
import Data.Time (Day)
import Kansoku.Api.Response (KansokuResult, OkResponses)
import Kansoku.Prelude
import Servant.API
  ( Description,
    JSON,
    QueryParam,
    QueryParam',
    Required,
    type (:>),
  )
import Servant.API.Generic (type (:-))
import Servant.API.MultiVerb (MultiVerb)
import Servant.API.Verbs qualified as Servant
import Web.HttpApiData (FromHttpApiData (..), ToHttpApiData (..))

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

instance ToHttpApiData TimeGrain where
  toUrlPiece = timeGrainText

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
  Description "The optional groupBy parameter accepts exactly one dimension: event_name, source, route, or prop:<name>. Property names must be declared in the event registry for every event queried by the metric. Unknown, undeclared, or multiple dimensions return HTTP 400 naming the invalid value."
    :> QueryParam' '[Required] "from" Day
    :> QueryParam' '[Required] "to" Day
    :> QueryParam "groupBy" Text
    :> QueryParam "timeGrain" TimeGrain
    :> MultiVerb 'Servant.GET '[JSON] (OkResponses "Metric result" MetricResult) (KansokuResult MetricResult)

-- | Metric routes keyed by field name. Ten fields deliberately share
-- 'MetricQuery'; their runtime path-to-handler guard lives in RoutingSpec.
-- Record field order is not load-bearing for servant routing.
data MetricsRoutes mode = MetricsRoutes
  { events :: mode :- "metrics" :> "events" :> MetricQuery,
    pageViews :: mode :- "metrics" :> "page-views" :> MetricQuery,
    sessions :: mode :- "metrics" :> "sessions" :> MetricQuery,
    funnel ::
      mode
        :- "metrics"
          :> "funnel"
          :> Description "Users counted at step N performed steps 1..N in order within `window` seconds of the chain's first step. Default window: the full from/to range, capped at 90 days (7776000 s)."
          :> QueryParam' '[Required] "from" Day
          :> QueryParam' '[Required] "to" Day
          :> QueryParam' '[Required] "steps" Text
          :> QueryParam "window" Int
          :> MultiVerb 'Servant.GET '[JSON] (OkResponses "Metric result" MetricResult) (KansokuResult MetricResult),
    retention ::
      mode
        :- "metrics"
          :> "retention"
          :> Description "Retention over new-in-window cohorts: a user's cohort day is their first activity within the requested from/to window (users active before the window re-appear as new). Offset 0 (the cohort day itself) is always included."
          :> QueryParam' '[Required] "from" Day
          :> QueryParam' '[Required] "to" Day
          :> QueryParam "days" Text
          :> MultiVerb 'Servant.GET '[JSON] (OkResponses "Metric result" MetricResult) (KansokuResult MetricResult),
    acquisition :: mode :- "metrics" :> "acquisition" :> MetricQuery,
    featureAdoption :: mode :- "metrics" :> "feature-adoption" :> MetricQuery,
    conversion :: mode :- "metrics" :> "conversion" :> MetricQuery,
    users :: mode :- "metrics" :> "users" :> MetricQuery,
    revenue :: mode :- "metrics" :> "revenue" :> MetricQuery,
    organizations :: mode :- "metrics" :> "organizations" :> MetricQuery,
    custom :: mode :- "metrics" :> "custom" :> MetricQuery,
    experiments ::
      mode
        :- "metrics"
          :> "experiments"
          :> Description "Unique users exposed per experiment and variant, from the experiment_exposures rollup. Counts raw identities (user_id, else anonymous_id) with a uniqCombined sketch (~0.8% error at scale; exact for small sets); identity-stitched exact numbers are served by the conversion and funnel endpoints. timeGrain: day, week, or month (hour is rejected; the rollup is daily); omitted = one bucket for the whole range. Re-exposures never double-count."
          :> QueryParam' '[Required] "from" Day
          :> QueryParam' '[Required] "to" Day
          :> QueryParam "experiment" Text
          :> QueryParam "timeGrain" TimeGrain
          :> MultiVerb 'Servant.GET '[JSON] (OkResponses "Metric result" MetricResult) (KansokuResult MetricResult),
    experimentConversion ::
      mode
        :- "metrics"
          :> "experiments"
          :> "conversion"
          :> Description "Per-variant conversion for one experiment: exposed unique users, users with a conversion event at or after their first exposure (earlier conversions do not count), and the rate. Users exposed to multiple variants count in each. Counts and rates only; no significance testing."
          :> QueryParam' '[Required] "experiment" Text
          :> QueryParam' '[Required] "event" Text
          :> QueryParam' '[Required] "from" Day
          :> QueryParam' '[Required] "to" Day
          :> MultiVerb 'Servant.GET '[JSON] (OkResponses "Metric result" MetricResult) (KansokuResult MetricResult)
  }
  deriving stock (Generic)
