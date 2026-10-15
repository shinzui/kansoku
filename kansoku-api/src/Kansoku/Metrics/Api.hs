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
import Kansoku.Api.Response (KansokuResult, OkResponses, ProblemJSON)
import Kansoku.Auth.Api (MetricsAuth)
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
  Description "Every implemented metric requires a positive half-open from/to range of at most 366 days and returns a complete answer of at most 10000 points, or a permanent HTTP 400 problem asking the caller to narrow the query. The optional groupBy parameter accepts exactly one dimension: event_name, source, route, or prop:<name>. Property names must be declared in the event registry for every event queried by the metric. Unknown, undeclared, or multiple dimensions return HTTP 400 naming the invalid value."
    :> QueryParam' '[Required] "from" Day
    :> QueryParam' '[Required] "to" Day
    :> QueryParam "groupBy" Text
    :> QueryParam "timeGrain" TimeGrain
    :> MultiVerb 'Servant.GET '[JSON, ProblemJSON] (OkResponses "Metric result" MetricResult) (KansokuResult MetricResult)

-- | Metric routes keyed by field name. Ten fields deliberately share
-- 'MetricQuery'; their runtime path-to-handler guard lives in RoutingSpec.
-- Record field order is not load-bearing for servant routing.
data MetricsRoutes mode = MetricsRoutes
  { events :: mode :- MetricsAuth :> "metrics" :> "events" :> MetricQuery,
    pageViews :: mode :- MetricsAuth :> "metrics" :> "page-views" :> MetricQuery,
    sessions :: mode :- MetricsAuth :> "metrics" :> "sessions" :> MetricQuery,
    funnel ::
      mode
        :- MetricsAuth
          :> "metrics"
          :> "funnel"
          :> Description "Every implemented metric requires a positive half-open from/to range of at most 366 days and returns a complete answer of at most 10000 points, or a permanent HTTP 400 problem asking the caller to narrow the query. At most 20 non-empty ordered steps are supported, including repeated names. Users counted at step N performed steps 1..N in order within `window` seconds of the chain's first step. Default window: the full from/to range, capped at 90 days (7776000 s)."
          :> QueryParam' '[Required] "from" Day
          :> QueryParam' '[Required] "to" Day
          :> QueryParam' '[Required] "steps" Text
          :> QueryParam "window" Int
          :> MultiVerb 'Servant.GET '[JSON, ProblemJSON] (OkResponses "Metric result" MetricResult) (KansokuResult MetricResult),
    retention ::
      mode
        :- MetricsAuth
          :> "metrics"
          :> "retention"
          :> Description "Every implemented metric requires a positive half-open from/to range of at most 366 days and returns a complete answer of at most 10000 points, or a permanent HTTP 400 problem asking the caller to narrow the query. At most 32 distinct retention offsets in 1..365 are supported; duplicates normalize to ascending unique offsets. Retention over new-in-window cohorts: a user's cohort day is their first activity within the requested from/to window (users active before the window re-appear as new). Offset 0 (the cohort day itself) is always included."
          :> QueryParam' '[Required] "from" Day
          :> QueryParam' '[Required] "to" Day
          :> QueryParam "days" Text
          :> MultiVerb 'Servant.GET '[JSON, ProblemJSON] (OkResponses "Metric result" MetricResult) (KansokuResult MetricResult),
    acquisition :: mode :- MetricsAuth :> "metrics" :> "acquisition" :> MetricQuery,
    featureAdoption :: mode :- MetricsAuth :> "metrics" :> "feature-adoption" :> MetricQuery,
    conversion :: mode :- MetricsAuth :> "metrics" :> "conversion" :> MetricQuery,
    users :: mode :- MetricsAuth :> "metrics" :> "users" :> MetricQuery,
    revenue :: mode :- MetricsAuth :> "metrics" :> "revenue" :> MetricQuery,
    organizations :: mode :- MetricsAuth :> "metrics" :> "organizations" :> MetricQuery,
    custom :: mode :- MetricsAuth :> "metrics" :> "custom" :> MetricQuery,
    experiments ::
      mode
        :- MetricsAuth
          :> "metrics"
          :> "experiments"
          :> Description "Every implemented metric requires a positive half-open from/to range of at most 366 days and returns a complete answer of at most 10000 points, or a permanent HTTP 400 problem asking the caller to narrow the query. Unique users exposed per experiment and variant, from the experiment_exposures rollup. Counts raw identities (user_id, else anonymous_id) with a uniqCombined sketch (~0.8% error at scale; exact for small sets); identity-stitched exact numbers are served by the conversion and funnel endpoints. timeGrain: day, week, or month (hour is rejected; the rollup is daily); omitted = one bucket for the whole range. Re-exposures never double-count."
          :> QueryParam' '[Required] "from" Day
          :> QueryParam' '[Required] "to" Day
          :> QueryParam "experiment" Text
          :> QueryParam "timeGrain" TimeGrain
          :> MultiVerb 'Servant.GET '[JSON, ProblemJSON] (OkResponses "Metric result" MetricResult) (KansokuResult MetricResult),
    experimentConversion ::
      mode
        :- MetricsAuth
          :> "metrics"
          :> "experiments"
          :> "conversion"
          :> Description "Every implemented metric requires a positive half-open from/to range of at most 366 days and returns a complete answer of at most 10000 points, or a permanent HTTP 400 problem asking the caller to narrow the query. Per-variant conversion for one experiment: exposed unique users, users with a conversion event at or after their first exposure (earlier conversions do not count), and the rate. Users exposed to multiple variants count in each. Counts and rates only; no significance testing."
          :> QueryParam' '[Required] "experiment" Text
          :> QueryParam' '[Required] "event" Text
          :> QueryParam' '[Required] "from" Day
          :> QueryParam' '[Required] "to" Day
          :> MultiVerb 'Servant.GET '[JSON, ProblemJSON] (OkResponses "Metric result" MetricResult) (KansokuResult MetricResult),
    experimentFunnel ::
      mode
        :- MetricsAuth
          :> "metrics"
          :> "experiments"
          :> "funnel"
          :> Description "Every implemented metric requires a positive half-open from/to range of at most 366 days and returns a complete answer of at most 10000 points, or a permanent HTTP 400 problem asking the caller to narrow the query. Ordered funnel per variant of one experiment. At most 20 non-empty ordered steps are supported, including repeated names. Users counted at step N performed steps 1..N in order, all at or after their first exposure to the experiment, within `window` seconds of the chain's first step (default: the full from/to range, capped at 90 days). Steps before first exposure do not count."
          :> QueryParam' '[Required] "experiment" Text
          :> QueryParam' '[Required] "steps" Text
          :> QueryParam' '[Required] "from" Day
          :> QueryParam' '[Required] "to" Day
          :> QueryParam "window" Int
          :> MultiVerb 'Servant.GET '[JSON, ProblemJSON] (OkResponses "Metric result" MetricResult) (KansokuResult MetricResult)
  }
  deriving stock (Generic)
