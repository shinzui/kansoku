-- | Public servant API and DTOs for semantic metric queries.
module Kansoku.Metrics.Api
  ( MetricPoint (..),
    MetricQuery,
    AcquisitionMeasure (..),
    SessionMeasure (..),
    UserWindow (..),
    RetentionMode (..),
    CohortMode (..),
    PathBy (..),
    FunnelMode (..),
    FunnelMeasure (..),
    FunnelCounting (..),
    FunnelAttribution (..),
    ExperimentMeasure (..),
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

data UserWindow = CalendarWindow | Rolling7 | Rolling30
  deriving stock (Generic, Eq, Show)

instance FromHttpApiData UserWindow where
  parseUrlPiece "calendar" = Right CalendarWindow
  parseUrlPiece "rolling7" = Right Rolling7
  parseUrlPiece "rolling30" = Right Rolling30
  parseUrlPiece _ = Left "window must be calendar, rolling7 or rolling30"

instance ToHttpApiData UserWindow where
  toUrlPiece CalendarWindow = "calendar"
  toUrlPiece Rolling7 = "rolling7"
  toUrlPiece Rolling30 = "rolling30"

data RetentionMode = RetentionOn | RetentionOnOrAfter
  deriving stock (Generic, Eq, Show)

instance FromHttpApiData RetentionMode where
  parseUrlPiece "on" = Right RetentionOn
  parseUrlPiece "on_or_after" = Right RetentionOnOrAfter
  parseUrlPiece _ = Left "mode must be on or on_or_after"

instance ToHttpApiData RetentionMode where
  toUrlPiece RetentionOn = "on"
  toUrlPiece RetentionOnOrAfter = "on_or_after"

data CohortMode = WindowCohort | LifetimeCohort
  deriving stock (Generic, Eq, Show)

instance FromHttpApiData CohortMode where
  parseUrlPiece "window" = Right WindowCohort
  parseUrlPiece "lifetime" = Right LifetimeCohort
  parseUrlPiece _ = Left "cohort must be window or lifetime"

instance ToHttpApiData CohortMode where
  toUrlPiece WindowCohort = "window"
  toUrlPiece LifetimeCohort = "lifetime"

data PathBy = PathEvent | PathRoute
  deriving stock (Generic, Eq, Show)

instance FromHttpApiData PathBy where
  parseUrlPiece "event" = Right PathEvent
  parseUrlPiece "route" = Right PathRoute
  parseUrlPiece _ = Left "by must be event or route"

instance ToHttpApiData PathBy where
  toUrlPiece PathEvent = "event"
  toUrlPiece PathRoute = "route"

data FunnelMode = FunnelSequential | FunnelStrict | FunnelAnyOrder
  deriving stock (Generic, Eq, Show)

instance FromHttpApiData FunnelMode where
  parseUrlPiece "sequential" = Right FunnelSequential
  parseUrlPiece "strict" = Right FunnelStrict
  parseUrlPiece "any_order" = Right FunnelAnyOrder
  parseUrlPiece _ = Left "mode must be sequential, strict or any_order"

instance ToHttpApiData FunnelMode where
  toUrlPiece FunnelSequential = "sequential"
  toUrlPiece FunnelStrict = "strict"
  toUrlPiece FunnelAnyOrder = "any_order"

data FunnelCounting = FunnelUniques | FunnelTotals
  deriving stock (Generic, Eq, Show)

instance FromHttpApiData FunnelCounting where
  parseUrlPiece "uniques" = Right FunnelUniques
  parseUrlPiece "totals" = Right FunnelTotals
  parseUrlPiece _ = Left "counting must be uniques or totals"

instance ToHttpApiData FunnelCounting where
  toUrlPiece FunnelUniques = "uniques"
  toUrlPiece FunnelTotals = "totals"

data FunnelAttribution = FunnelFirstTouch | FunnelLastTouch | FunnelStep !Int
  deriving stock (Generic, Eq, Show)

instance FromHttpApiData FunnelAttribution where
  parseUrlPiece "first_touch" = Right FunnelFirstTouch
  parseUrlPiece "last_touch" = Right FunnelLastTouch
  parseUrlPiece value = case Text.stripPrefix "step:" value of
    Just number
      | not (Text.null number),
        Text.all (\c -> c >= '0' && c <= '9') number ->
          case reads (Text.unpack number) :: [(Integer, String)] of
            [(n, "")] | n >= 1 && n <= 20 -> Right (FunnelStep (fromInteger n))
            _ -> Left "attribution step must be 1..20 and within the requested steps"
    _ -> Left "attribution must be first_touch, last_touch or step:<n>"

instance ToHttpApiData FunnelAttribution where
  toUrlPiece FunnelFirstTouch = "first_touch"
  toUrlPiece FunnelLastTouch = "last_touch"
  toUrlPiece (FunnelStep n) = "step:" <> Text.pack (show n)

data FunnelMeasure = FunnelCount | FunnelTimeToConvert
  deriving stock (Generic, Eq, Show)

instance FromHttpApiData FunnelMeasure where
  parseUrlPiece "count" = Right FunnelCount
  parseUrlPiece "time_to_convert" = Right FunnelTimeToConvert
  parseUrlPiece _ = Left "measure must be count or time_to_convert"

instance ToHttpApiData FunnelMeasure where
  toUrlPiece FunnelCount = "count"
  toUrlPiece FunnelTimeToConvert = "time_to_convert"

data ExperimentMeasure = ExperimentExposures | ExperimentDiagnostics
  deriving stock (Generic, Eq, Show)

instance FromHttpApiData ExperimentMeasure where
  parseUrlPiece "exposures" = Right ExperimentExposures
  parseUrlPiece "diagnostics" = Right ExperimentDiagnostics
  parseUrlPiece _ = Left "measure must be exposures or diagnostics"

instance ToHttpApiData ExperimentMeasure where
  toUrlPiece ExperimentExposures = "exposures"
  toUrlPiece ExperimentDiagnostics = "diagnostics"

type MetricParameters result =
  Description "Every metric requires a positive half-open from/to range of at most 366 days and returns at most 10000 complete points. groupBy accepts one or two distinct dimensions: event_name, source, source_service, host, route, enrichment/acquisition fields prop:<declared scalar property>, or current user:<governed trait>. Repeated filter parameters are AND-combined JSON objects with dimension/op/value (omit value for set/unset): at most 8 filters, 100 in values, 1024 UTF-8 bytes per string and 16384 decoded bytes combined. Missing/null values are unset; comparisons including neq do not match unset values. Group keys keep full dimension names and null differs from an empty string. Unsupported parameters are errors. See the documented route matrix."
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

type UserQuery =
  Description "Exact canonical active subjects; identity/profile-only events are excluded. window=calendar (default), rolling7 or rolling30. Rolling windows require day grain and count [d-(N-1),d+1) UTC for each returned day d. Filters/grouping apply to the same activity population; up to two dimensions and eight bounded repeated JSON filters. Bot rows are excluded unless includeBots=true. Positive half-open range at most 366 days, to no later than the current UTC day (only closed days), at most 10000 complete points."
    :> MetricArguments (QueryParam "window" UserWindow :> QueryParam "includeBots" Bool :> MetricResponse)

type DailyActivityQuery =
  Description "Exact canonical daily activity with retained-history lookback; identity/profile-only events are excluded throughout. Day grain only. Filters and one/two group dimensions define the same population throughout lookback; each group is a separate population. Bot rows are excluded unless includeBots=true. Positive half-open range at most 366 days; to no later than the current UTC day; at most 10000 complete points. Stickiness emits daily_active, rolling30_active and ratio (0..1) in group.measure. Lifecycle emits nonnegative new, returning, resurrecting and dormant in group.status; first means first retained matching activity. Empty ungrouped days return zero measures."
    :> MetricArguments (QueryParam "includeBots" Bool :> MetricResponse)

type AcquisitionQuery = MetricParameters (QueryParam "measure" AcquisitionMeasure :> QueryParam "includeBots" Bool :> MetricResponse)

-- | Metric routes keyed by field name. Six fields deliberately share
-- 'MetricQuery'; their runtime path-to-handler guard lives in RoutingSpec.
-- Record field order is not load-bearing for servant routing.
data MetricsRoutes mode = MetricsRoutes
  { events :: mode :- MetricsAuth :> "metrics" :> "events" :> MetricQuery,
    pageViews :: mode :- MetricsAuth :> "metrics" :> "page-views" :> WebMetricQuery,
    sessions :: mode :- MetricsAuth :> "metrics" :> "sessions" :> SessionQuery,
    paths ::
      mode
        :- MetricsAuth
          :> "metrics"
          :> "paths"
          :> Description "Exact canonical-user paths ordered by millisecond time then event ID. by=event (default) requires start or end; by=route selects nonbot page_view rows, collapses consecutive identical routes, and permits entry mode with neither anchor. start uses the first occurrence; end uses the last and walks backwards. Anchors are mutually exclusive. steps=1..10 (default 5) counts transitions; top=1..20 (default 10) retains K transitions per step and sums the remainder into one (other) to (other) transition. window=1..7776000 seconds (default range capped at 90 days) is inclusive from the anchor. events/exclude are comma-separated event names, at most 100 each; exclude wins. Filters select rows before anchoring. Exhausted sequences emit (end), including in reverse mode. group={step,from,to}, value=users, bucket=null; order step ascending, value descending, from then to. Positive half-open range at most 366 days; complete responses, native work budgets and global 10000-point cap."
          :> QueryParam' '[Required] "from" Day
          :> QueryParam' '[Required] "to" Day
          :> QueryParam "start" Text
          :> QueryParam "end" Text
          :> QueryParam "steps" Int
          :> QueryParam "top" Int
          :> QueryParam "window" Int
          :> QueryParam "events" Text
          :> QueryParam "exclude" Text
          :> QueryParam "by" PathBy
          :> QueryParams "filter" MetricFilter
          :> MetricResponse,
    funnel ::
      mode
        :- MetricsAuth
          :> "metrics"
          :> "funnel"
          :> Description "Canonical user timelines ordered by millisecond occurred_at then event_id, with immutable duplicates removed. At most 20 steps; one event cannot satisfy repeated steps. mode=any_order opens one window at the earliest matching step and counts distinct step positions; mode=sequential (default) allows intervening events; strict requires adjacency including automatic events, accepts current-user filters over complete participant timelines, and rejects event filters. counting=uniques (default) selects maximum reach, earliest completion, earliest start, then event IDs for sequential/strict. counting=totals counts nonoverlapping entries, restarting after completion, expiry or interruption; any-order entries start at any step, others at step one. Totals add an ungrouped measure=entries point per variant and label reach rows measure=count. There is no exclusion grace period. window is inclusive seconds from first step, default range capped at 7776000. Repeat exclude up to 20 distinct validated names; exclusions between matched steps stop a chain, and cannot overlap steps. measure=count (default) emits cumulative reach. time_to_convert emits exact nearest-rank p50_seconds/p90_seconds for reached steps >=2, from the same selected chain. One/two group dimensions use the earliest eligible start (per attempt for totals). prop attribution=first_touch (default), last_touch or step:<n> uses the start, last matched event or named step; absent/unreached values are other. Validate declarations in that step, or compatible declared properties across steps when touch varies; user dimensions use participant current traits. Sequential event filters select step rows and cannot hide exclusions. Positive half-open range at most 366 days; native execution/memory limits; at most 10000 complete points or HTTP 400."
          :> QueryParam' '[Required] "from" Day
          :> QueryParam' '[Required] "to" Day
          :> QueryParam' '[Required] "steps" Text
          :> QueryParam "window" Int
          :> QueryParam "mode" FunnelMode
          :> QueryParam "measure" FunnelMeasure
          :> QueryParam "counting" FunnelCounting
          :> QueryParam "attribution" FunnelAttribution
          :> QueryParams "exclude" Text
          :> QueryParam "groupBy" Text
          :> QueryParams "filter" MetricFilter
          :> MultiVerb 'Servant.GET '[JSON, ProblemJSON] (OkResponses "Metric result" MetricResult) (KansokuResult MetricResult),
    retention ::
      mode
        :- MetricsAuth
          :> "metrics"
          :> "retention"
          :> Description "Exact canonical retention over closed UTC days. mode=on (default) counts the exact offset day; on_or_after counts any day from offset through the largest requested offset, including unrequested intermediate days. cohort=window (default) means first matching activity in range; lifetime means first matching activity in retained history, not first ever. Date bounds select the observed activity interval and cohort dates. Offset 0 always emits cohort size. Omit immature on offsets; on_or_after omits nonzero offsets unless the full maximum horizon is closed by to. to cannot exceed the current UTC day. Day grain only; filters/grouping define identical populations throughout lookback. Bot rows are excluded unless includeBots=true. Up to two dimensions, eight bounded JSON filters, 32 distinct offsets 1..365, range at most 366 days and 10000 complete points."
          :> MetricArguments (QueryParam "days" Text :> QueryParam "mode" RetentionMode :> QueryParam "cohort" CohortMode :> QueryParam "includeBots" Bool :> MetricResponse),
    acquisition :: mode :- MetricsAuth :> "metrics" :> "acquisition" :> AcquisitionQuery,
    featureAdoption :: mode :- MetricsAuth :> "metrics" :> "feature-adoption" :> MetricQuery,
    conversion :: mode :- MetricsAuth :> "metrics" :> "conversion" :> Description "Exact ordered signup conversion: starters are the denominator; only starters with a later signup_completed in the millisecond/event-ID timeline within range (window capped at 90 days) convert. Zero denominator returns zero; ratio stays 0..1. Group ownership is the earliest eligible start. timeGrain and prop grouping are rejected." :> MetricQuery,
    users :: mode :- MetricsAuth :> "metrics" :> "users" :> UserQuery,
    stickiness :: mode :- MetricsAuth :> "metrics" :> "stickiness" :> DailyActivityQuery,
    lifecycle :: mode :- MetricsAuth :> "metrics" :> "lifecycle" :> DailyActivityQuery,
    revenue :: mode :- MetricsAuth :> "metrics" :> "revenue" :> MetricQuery,
    organizations :: mode :- MetricsAuth :> "metrics" :> "organizations" :> MetricQuery,
    custom :: mode :- MetricsAuth :> "metrics" :> "custom" :> MetricQuery,
    experiments ::
      mode
        :- MetricsAuth
          :> "metrics"
          :> "experiments"
          :> Description "Current user: filters/grouping select exact canonical populations; segmented exposures bypass the raw sketch. measure=exposures (default without segmentation) returns daily-rollup uniqCombined raw-identity exposure counts (~0.8% sketch error at scale); it differs from exact stitched users. measure=diagnostics uses exact canonical subjects and valid experiment/variant exposures, assigning each user once per experiment/requested bucket to earliest occurred_at,event_id. group.measure emits exposed_users, multiple_exposure (>1 observed variant), assigned_users and variant_share; per-variant shares sum to one when nonempty. Repeated exposures do not increase assignment. Zero users emit zero totals and no variant rows; missing/invalid names are excluded. All observed variants remain visible, including zero assignments. Day/week/month or whole range; hour rejected. First observed exposure is not an authoritative randomization log; contamination invalidates naive sample-ratio interpretation. Positive half-open range at most 366 days; at most 10000 complete points and bounded native work."
          :> QueryParam' '[Required] "from" Day
          :> QueryParam' '[Required] "to" Day
          :> QueryParam "experiment" Text
          :> QueryParam "timeGrain" TimeGrain
          :> QueryParam "measure" ExperimentMeasure
          :> QueryParam "groupBy" Text
          :> QueryParams "filter" MetricFilter
          :> MultiVerb 'Servant.GET '[JSON, ProblemJSON] (OkResponses "Metric result" MetricResult) (KansokuResult MetricResult),
    experimentConversion ::
      mode
        :- MetricsAuth
          :> "metrics"
          :> "experiments"
          :> "conversion"
          :> Description "Every implemented metric requires a positive half-open from/to range of at most 366 days and returns a complete answer of at most 10000 points, or a permanent HTTP 400 problem asking the caller to narrow the query. Current user: filters/grouping are supported; event selection is rejected. Per-variant conversion for one experiment: exposed unique users, users with a conversion event at or after their first exposure (earlier conversions do not count), and the rate. Users exposed to multiple variants count in each. Counts and rates only; no significance testing."
          :> QueryParam' '[Required] "experiment" Text
          :> QueryParam' '[Required] "event" Text
          :> QueryParam' '[Required] "from" Day
          :> QueryParam' '[Required] "to" Day
          :> QueryParam "groupBy" Text
          :> QueryParams "filter" MetricFilter
          :> MultiVerb 'Servant.GET '[JSON, ProblemJSON] (OkResponses "Metric result" MetricResult) (KansokuResult MetricResult),
    experimentFunnel ::
      mode
        :- MetricsAuth
          :> "metrics"
          :> "experiments"
          :> "funnel"
          :> Description "Canonical user timelines ordered by millisecond occurred_at then event_id, with immutable duplicates removed. At most 20 steps; one event cannot satisfy repeated steps. mode=any_order opens one window at the earliest matching step and counts distinct step positions; mode=sequential (default) allows intervening events; strict requires adjacency including automatic events, accepts current-user filters over complete participant timelines, and rejects event filters. counting=uniques (default) selects maximum reach, earliest completion, earliest start, then event IDs for sequential/strict. counting=totals counts nonoverlapping entries, restarting after completion, expiry or interruption; any-order entries start at any step, others at step one. Totals add an ungrouped measure=entries point per variant and label reach rows measure=count. There is no exclusion grace period. window is inclusive seconds from first step, default range capped at 7776000. Repeat exclude up to 20 distinct validated names; exclusions between matched steps stop a chain, and cannot overlap steps. measure=count (default) emits cumulative reach. time_to_convert emits exact nearest-rank p50_seconds/p90_seconds for reached steps >=2, from the same selected chain. One/two group dimensions use the earliest eligible start (per attempt for totals). prop attribution=first_touch (default), last_touch or step:<n> uses the start, last matched event or named step; absent/unreached values are other. Validate declarations in that step, or compatible declared properties across steps when touch varies; user dimensions use participant current traits. Sequential event filters select step rows and cannot hide exclusions. Positive half-open range at most 366 days; native execution/memory limits; at most 10000 complete points or HTTP 400. Per-variant timelines include only events at or after that user/variant first exposure inside the range. Multi-variant users remain in each variant."
          :> QueryParam' '[Required] "experiment" Text
          :> QueryParam' '[Required] "steps" Text
          :> QueryParam' '[Required] "from" Day
          :> QueryParam' '[Required] "to" Day
          :> QueryParam "window" Int
          :> QueryParam "mode" FunnelMode
          :> QueryParam "measure" FunnelMeasure
          :> QueryParam "counting" FunnelCounting
          :> QueryParam "attribution" FunnelAttribution
          :> QueryParams "exclude" Text
          :> QueryParam "groupBy" Text
          :> QueryParams "filter" MetricFilter
          :> MultiVerb 'Servant.GET '[JSON, ProblemJSON] (OkResponses "Metric result" MetricResult) (KansokuResult MetricResult)
  }
  deriving stock (Generic)
