-- | Public servant API and DTOs for semantic metric queries.
module Kansoku.Metrics.Api
  ( MetricPoint (..),
    MetricQuery,
    AcquisitionMeasure (..),
    SessionMeasure (..),
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
import Kansoku.Metrics.Filter (MetricFilter)
import Kansoku.Prelude
import Servant.API
  ( Description,
    JSON,
    QueryParam,
    QueryParam',
    QueryParams,
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
    group :: !(Map Text (Maybe Text)),
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

data AcquisitionMeasure = AcquisitionSessions | AcquisitionUsers
  deriving stock (Generic, Eq, Show)

instance FromHttpApiData AcquisitionMeasure where
  parseUrlPiece "sessions" = Right AcquisitionSessions
  parseUrlPiece "users" = Right AcquisitionUsers
  parseUrlPiece _ = Left "measure must be sessions or users"

instance ToHttpApiData AcquisitionMeasure where
  toUrlPiece AcquisitionSessions = "sessions"
  toUrlPiece AcquisitionUsers = "users"

data SessionMeasure = SessionCount | SessionBounceRate | SessionAverageDuration
  deriving stock (Generic, Eq, Show)

instance FromHttpApiData SessionMeasure where
  parseUrlPiece "count" = Right SessionCount
  parseUrlPiece "bounce_rate" = Right SessionBounceRate
  parseUrlPiece "average_duration_seconds" = Right SessionAverageDuration
  parseUrlPiece _ = Left "measure must be count, bounce_rate or average_duration_seconds"

instance ToHttpApiData SessionMeasure where
  toUrlPiece SessionCount = "count"
  toUrlPiece SessionBounceRate = "bounce_rate"
  toUrlPiece SessionAverageDuration = "average_duration_seconds"

type MetricParameters result =
  Description "Every metric requires a positive half-open from/to range of at most 366 days and returns at most 10000 complete points. groupBy accepts one or two distinct dimensions: event_name, source, source_service, host, route, enrichment/acquisition fields or prop:<declared scalar property>. Repeated filter parameters are AND-combined JSON objects with dimension/op/value (omit value for set/unset): at most 8 filters, 100 in values, 1024 UTF-8 bytes per string and 16384 decoded bytes combined. Missing/null values are unset; comparisons including neq do not match unset values. Group keys keep full dimension names and null differs from an empty string. Unsupported parameters are errors. See the documented route matrix."
    :> MetricArguments result

type MetricArguments result =
  QueryParam' '[Required] "from" Day
    :> QueryParam' '[Required] "to" Day
    :> QueryParam "groupBy" Text
    :> QueryParam "timeGrain" TimeGrain
    :> QueryParams "filter" MetricFilter
    :> result

type MetricResponse = MultiVerb 'Servant.GET '[JSON, ProblemJSON] (OkResponses "Metric result" MetricResult) (KansokuResult MetricResult)

type MetricQuery = MetricParameters MetricResponse

type WebMetricQuery = MetricParameters (QueryParam "includeBots" Bool :> MetricResponse)

type SessionQuery =
  Description "Whole retained web sessions keyed by account/source_service/nonempty session_id; assemble before selecting the start date or UTC bucket. Defaults: measure=count, day grain, no grouping, includeBots=false. bounce_rate is exactly one page_view and no engagement divided by all selected sessions; lifecycle/identity/exposure events are not engagement. average_duration_seconds includes every selected session, including zero-duration visits, and measures last minus first observed event including page_leave. Attribute grouping/filters select first page_view, else earliest event; entry_page/exit_page come from page views. Arbitrary prop: filters/grouping are rejected. Any bot event excludes the whole session unless includeBots=true. Empty ungrouped buckets return zero; nonexistent groups are omitted. One/two dimensions, at most 8 AND filters (100 in values, 1024 UTF-8 bytes per string, 16384 decoded bytes), positive half-open range at most 366 days, at most 10000 complete points. Late arrivals and retained-history changes can change start/attribution/duration."
    :> MetricArguments (QueryParam "measure" SessionMeasure :> QueryParam "includeBots" Bool :> MetricResponse)

type AcquisitionQuery = MetricParameters (QueryParam "measure" AcquisitionMeasure :> QueryParam "includeBots" Bool :> MetricResponse)

-- | Metric routes keyed by field name. Six fields deliberately share
-- 'MetricQuery'; their runtime path-to-handler guard lives in RoutingSpec.
-- Record field order is not load-bearing for servant routing.
data MetricsRoutes mode = MetricsRoutes
  { events :: mode :- MetricsAuth :> "metrics" :> "events" :> MetricQuery,
    pageViews :: mode :- MetricsAuth :> "metrics" :> "page-views" :> WebMetricQuery,
    sessions :: mode :- MetricsAuth :> "metrics" :> "sessions" :> SessionQuery,
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
    acquisition :: mode :- MetricsAuth :> "metrics" :> "acquisition" :> AcquisitionQuery,
    featureAdoption :: mode :- MetricsAuth :> "metrics" :> "feature-adoption" :> MetricQuery,
    conversion :: mode :- MetricsAuth :> "metrics" :> "conversion" :> MetricQuery,
    users :: mode :- MetricsAuth :> "metrics" :> "users" :> WebMetricQuery,
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
