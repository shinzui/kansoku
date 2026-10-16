{-# LANGUAGE TypeApplications #-}

-- | Query compiler and executor for semantic metrics.
module Kansoku.Metrics.Query
  ( GroupDimension (..),
    QueryCompileError (..),
    QueryExecutionError (..),
    QueryRequest (..),
    buildExperimentConversionSQL,
    buildExperimentExposuresSQL,
    buildExperimentFunnelSQL,
    PathOptions (..),
    validatePathOptions,
    runPaths,
    buildPathsSQL,
    buildFunnelSQL,
    buildRetentionSQL,
    buildRetentionMetricSQL,
    buildUsersSQL,
    buildStickinessSQL,
    buildLifecycleSQL,
    buildSQL,
    buildAcquisitionSQL,
    activityPredicate,
    buildSessionsSQL,
    buildSessionMetricSQL,
    experimentConversionPoint,
    experimentExposuresPoint,
    experimentFunnelPoint,
    queryCompileErrorCode,
    queryCompileErrorMessage,
    resolvedSource,
    run,
    runExperimentConversion,
    runExperimentExposures,
    runExperimentFunnel,
    runFunnel,
    FunnelOptions (..),
    defaultFunnelOptions,
    runFunnelMetric,
    buildFunnelMetricSQL,
    runExperimentDiagnostics,
    runRetention,
    runRetentionMetric,
    runUsers,
    runStickiness,
    runLifecycle,
    runSessions,
    runSessionMetric,
    runAcquisition,
  )
where

import ClickHaskell
  ( ChString,
    ClickHaskell,
    ClientError (..),
    Column,
    Float64,
    Select,
    ToChType (toChType),
    addParameter,
    passParameters,
    select,
    unsafeMkSelect,
  )
import ClickHaskell.Protocol qualified as Protocol
import Control.Exception (fromException)
import Data.Aeson qualified as Aeson
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString qualified
import Data.Foldable (traverse_)
import Data.Generics.Labels ()
import Data.List qualified as List
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time (Day, addDays, dayOfWeek, diffDays, fromGregorian, toGregorian, utctDay)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Effectful (Eff, IOE, type (:>))
import Kansoku.ClickHouse (QueryPool, queryDeadlineMicros, withIdentityQueryConnection, withMetricsQueryConnection)
import Kansoku.Cohort.Query qualified as Cohort
import Kansoku.Event
  ( AccountId (..),
    EventName (..),
    EventRegistry,
    defaultRegistry,
  )
import Kansoku.Exception (trySynchronous)
import Kansoku.Metrics.Api (AcquisitionMeasure (..), CohortMode (..), FunnelAttribution (..), FunnelCounting (..), FunnelMeasure (..), FunnelMode (..), MetricPoint (..), MetricResult (..), PathBy (..), RetentionMode (..), SessionMeasure (..), TimeGrain (..), UserWindow (..))
import Kansoku.Metrics.Definition (Aggregation (..), MetricDefinition (..), RatioMetric (..))
import Kansoku.Metrics.Filter (MetricFilter)
import Kansoku.Metrics.Filter qualified as WireFilter
import Kansoku.Metrics.Limits (maxMetricPoints, maxPathEvents, maxPathSteps, maxPathTop, maxPathWindowSeconds, maxQueryDays)
import Kansoku.Metrics.Query.Dimension
import Kansoku.Metrics.Query.Filter qualified as Filters
import Kansoku.Metrics.Query.Funnel qualified as Funnel
import Kansoku.Metrics.Query.Property
  ( PropertyError (..),
    PropertyName,
    ScalarType (..),
    propertyFloatExpr,
    resolveNumericProperty,
    resolveOptionalProperty,
    resolveProperty,
  )
import Kansoku.Metrics.Query.Session (materializedSessionProjection, sessionProjection)
import Kansoku.Metrics.Query.Traits qualified as Traits
import Kansoku.Metrics.Query.Validate (QueryLimitError (..), SqlName, mkSqlName, renderSqlName, validateDateRange, validateObservationCutoff, validateOffsets, validateSteps)
import Kansoku.Metrics.Registry (BuiltinMetric (..), activeUsers)
import Kansoku.Prelude
import System.Timeout (timeout)

data QueryRequest = QueryRequest
  { accountId :: !AccountId,
    from :: !Day,
    to :: !Day,
    groupBy :: !(Maybe [Text]),
    timeGrain :: !(Maybe TimeGrain),
    filters :: ![MetricFilter],
    cohorts :: ![(Text, Cohort.Membership)],
    includeBots :: !Bool
  }
  deriving stock (Generic, Eq, Show)

data QueryCompileError
  = QueryCompilePropertyError !PropertyError
  | QueryCompileInvalidGroupBy !Text
  | QueryCompileMultipleGroupBy ![Text]
  | QueryCompileMissingAggregationProperty !Text
  | QueryCompileUnsupportedPropertyGrouping !Text
  | QueryCompileFilterError !Text
  deriving stock (Generic, Eq, Show)

data CompiledMetric = CompiledMetric
  { sql :: !Text,
    groupLabels :: ![Text],
    filterParameters :: ![QueryParameter],
    ordering :: !ResultOrder
  }
  deriving stock (Generic)

type AggColumns =
  '[ Column "bucket" ChString,
     Column "group_key" ChString,
     Column "value" Float64
   ]

data AggRow = AggRow
  { bucket :: !ByteString,
    group_key :: !ByteString,
    value :: !Double
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ClickHaskell AggColumns)

-- | The execution boundary distinguishes permanent faults from dependency outages.
data QueryExecutionError
  = QueryCohortNotFound
  | QueryCompileFailure !QueryCompileError
  | QueryLimitFailure !QueryLimitError
  | MetricResultTooLarge
  | QueryStorageFailure !Text
  | QueryResourceLimit
  deriving stock (Generic, Eq, Show)

-- No caller-supplied SQL may select a result ordering.
data ResultOrder = PathsOrder | ExperimentUserOrder | FunnelDimensionsOrder | DiagnosticOrder | BucketDimensions | BucketDimensionsMeasure | RetentionDimensionsOrder | BucketGroup | ExperimentExposureOrder | ExperimentConversionOrder | RetentionOrder | FunnelOrder | ExperimentFunnelOrder
  deriving stock (Generic)

buildSQL :: EventRegistry -> BuiltinMetric -> QueryRequest -> Either QueryCompileError Text
buildSQL registry metric req = do
  compiled <- compileMetric registry metric req
  pure (boundedSQL (compiled ^. #ordering) (compiled ^. #sql))

run :: (IOE :> es) => EventRegistry -> QueryPool -> BuiltinMetric -> QueryRequest -> Eff es (Either QueryExecutionError MetricResult)
run registry pool metric req =
  case first QueryLimitFailure (validateDateRange (req ^. #from) (req ^. #to))
    >> first QueryCompileFailure (compileMetric registry metric req) of
    Left err -> pure (Left err)
    Right compiled ->
      liftIO $
        runSQL
          pool
          (metricName metric)
          (compiled ^. #groupLabels)
          (accountParameter req <> metricParameters metric req <> compiled ^. #filterParameters)
          (boundedSQL (compiled ^. #ordering) (compiled ^. #sql))

-- Session date predicates apply to the retained session's start, never its input rows.
-- Only the users measure needs the exact identity snapshot over those retained rows.
runAcquisition :: (IOE :> es) => EventRegistry -> QueryPool -> AcquisitionMeasure -> QueryRequest -> Eff es (Either QueryExecutionError MetricResult)
runAcquisition registry pool measure req =
  case first QueryLimitFailure (validateDateRange (req ^. #from) (req ^. #to))
    >> first QueryCompileFailure (compileAcquisition registry measure req) of
    Left failure -> pure (Left failure)
    Right compiled ->
      liftIO $
        runSQL
          pool
          "acquisition"
          (compiled ^. #groupLabels)
          (accountParameter (retainedScope req) <> compiled ^. #filterParameters)
          (boundedSQL BucketDimensions (compiled ^. #sql))

buildAcquisitionSQL :: EventRegistry -> AcquisitionMeasure -> QueryRequest -> Either QueryCompileError Text
buildAcquisitionSQL registry measure req = boundedSQL BucketDimensions . view #sql <$> compileAcquisition registry measure req

retainedScope :: QueryRequest -> QueryRequest
retainedScope req = req {from = fromGregorian 1970 1 1, to = fromGregorian 2100 1 1}

compileAcquisition :: EventRegistry -> AcquisitionMeasure -> QueryRequest -> Either QueryCompileError CompiledMetric
compileAcquisition registry measure req = do
  let scope = Filters.filteredEventScope [] (req ^. #filters)
  grouping <- requestedGroupingWith (cohortDimension req "primary_subject" (resolveSessionDimension registry scope)) (req ^. #groupBy) ["channel"]
  filters <- first QueryCompileFilterError (Filters.compileFiltersWith "metric_filter" (cohortDimension req "primary_subject" (resolveSessionDimension registry scope)) (normalizeCohortFilters (req ^. #filters)))
  let resolved = measure == AcquisitionUsers || hasUserTraits req
      source = if resolved then rawResolvedSource (retainedScope req) else "analytics.events_canonical"
      aggregate = if measure == AcquisitionUsers then "uniqExactIf(primary_subject,primary_subject!='')" else "count()"
      predicates = [timestampPredicate req] <> ["NOT is_bot" | not (req ^. #includeBots)] <> Filters.predicates filters
      sessions = if resolved || any isPropertyDimension grouping || any (Text.isPrefixOf "prop:" . WireFilter.dimension) (req ^. #filters) then sessionProjection source resolved else materializedSessionProjection
      sql =
        Text.unlines
          [ "SELECT " <> bucketExpr (req ^. #timeGrain) <> " AS bucket," <> groupProjection grouping <> ",toFloat64(" <> aggregate <> ") AS value",
            "FROM (" <> Traits.sessionSource (queryTraits req) sessions <> ")",
            "WHERE " <> accountPredicate <> " AND " <> Text.intercalate " AND " predicates,
            "GROUP BY bucket,sort_group_1,sort_group_2"
          ]
  pure CompiledMetric {sql, groupLabels = map dimensionLabel grouping, filterParameters = Filters.parameters filters, ordering = BucketDimensions}

runSessions :: (IOE :> es) => QueryPool -> QueryRequest -> Eff es (Either QueryExecutionError MetricResult)
runSessions pool = runSessionMetric pool SessionCount

runSessionMetric :: (IOE :> es) => QueryPool -> SessionMeasure -> QueryRequest -> Eff es (Either QueryExecutionError MetricResult)
runSessionMetric pool measure req =
  case first QueryLimitFailure (validateDateRange (req ^. #from) (req ^. #to))
    >> first QueryCompileFailure (compileSessions measure req) of
    Left failure -> pure (Left failure)
    Right compiled ->
      liftIO $
        runSQL
          pool
          "sessions"
          (compiled ^. #groupLabels)
          (accountParameter (if hasUserTraits req then retainedScope req else req) <> compiled ^. #filterParameters)
          (boundedSQL BucketDimensions (compiled ^. #sql))

runRetention :: (IOE :> es) => QueryPool -> QueryRequest -> [Int] -> Eff es (Either QueryExecutionError MetricResult)
runRetention pool = runRetentionMetric defaultRegistry pool RetentionOn WindowCohort

runRetentionMetric :: (IOE :> es) => EventRegistry -> QueryPool -> RetentionMode -> CohortMode -> QueryRequest -> [Int] -> Eff es (Either QueryExecutionError MetricResult)
runRetentionMetric registry pool mode cohort req offsets =
  case validateOffsets offsets of
    Left failure -> pure (Left (QueryLimitFailure failure))
    Right normalized -> runObserved pool "retention" req (if cohort == LifetimeCohort then historicalScope req else req) (dailyGrain req) (compileRetention registry mode cohort req normalized)

runUsers :: (IOE :> es) => EventRegistry -> QueryPool -> UserWindow -> QueryRequest -> Eff es (Either QueryExecutionError MetricResult)
runUsers registry pool window req =
  runObserved
    pool
    "active_users"
    req
    (rollingScope window req)
    (if window == CalendarWindow then Right () else dailyGrain req)
    (compileUsers registry window req)

runStickiness :: (IOE :> es) => EventRegistry -> QueryPool -> QueryRequest -> Eff es (Either QueryExecutionError MetricResult)
runStickiness registry pool req = runObserved pool "stickiness" req (rollingScope Rolling30 req) (dailyGrain req) (compileRolling registry 30 True req)

runLifecycle :: (IOE :> es) => EventRegistry -> QueryPool -> QueryRequest -> Eff es (Either QueryExecutionError MetricResult)
runLifecycle registry pool req = runObserved pool "lifecycle" req (historicalScope req) (dailyGrain req) (compileLifecycle registry req)

runObserved :: (IOE :> es) => QueryPool -> Text -> QueryRequest -> QueryRequest -> Either QueryLimitError () -> Either QueryCompileError CompiledMetric -> Eff es (Either QueryExecutionError MetricResult)
runObserved pool name req scope checks compiled = do
  today <- liftIO (utctDay <$> getCurrentTime)
  case first QueryLimitFailure (validateDateRange (req ^. #from) (req ^. #to) >> validateObservationCutoff today (req ^. #to) >> checks)
    >> first QueryCompileFailure compiled of
    Left failure -> pure (Left failure)
    Right result ->
      liftIO $
        runSQL
          pool
          name
          (result ^. #groupLabels)
          (accountParameter scope <> result ^. #filterParameters)
          (boundedSQL (result ^. #ordering) (result ^. #sql))

dailyGrain :: QueryRequest -> Either QueryLimitError ()
dailyGrain req = unless (req ^. #timeGrain `elem` [Nothing, Just Day]) (Left (QueryLimitError "invalid_time_grain" "this activity mode requires day grain"))

historicalScope :: QueryRequest -> QueryRequest
historicalScope req = req {from = min (fromGregorian 1970 1 1) (req ^. #from)}

rollingScope :: UserWindow -> QueryRequest -> QueryRequest
rollingScope window req = req {from = addDays (negate (windowDays window - 1)) (req ^. #from)}

windowDays :: UserWindow -> Integer
windowDays CalendarWindow = 1
windowDays Rolling7 = 7
windowDays Rolling30 = 30

-- | One sequence per canonical subject; end anchoring reverses traversal.
data PathOptions = PathOptions
  { pathBy :: !PathBy,
    pathStart :: !(Maybe Text),
    pathEnd :: !(Maybe Text),
    pathSteps :: !Int,
    pathTop :: !Int,
    pathWindow :: !Int,
    pathEvents :: ![Text],
    pathExclude :: ![Text]
  }
  deriving stock (Generic, Eq, Show)

validatePathOptions :: PathOptions -> Either QueryLimitError ()
validatePathOptions options = do
  check (not (isJust (pathStart options) && isJust (pathEnd options))) "start and end are mutually exclusive"
  check (pathBy options == PathRoute || isJust (pathStart options) || isJust (pathEnd options)) "event paths require start or end"
  check (pathSteps options >= 1 && pathSteps options <= maxPathSteps) "steps must be in 1..10"
  check (pathTop options >= 1 && pathTop options <= maxPathTop) "top must be in 1..20"
  check (pathWindow options >= 1 && pathWindow options <= maxPathWindowSeconds) "window must be in 1..7776000 seconds"
  traverse_ (\xs -> check (length xs <= maxPathEvents && all validName xs) "events and exclude accept at most 100 valid event names each") [pathEvents options, pathExclude options]
  traverse_ (\anchor -> check (if pathBy options == PathEvent then validName anchor else Text.isPrefixOf "/" anchor && byteLength anchor <= 1024) "anchor must be an event name or a route beginning with / (at most 1024 UTF-8 bytes)") (catMaybes [pathStart options, pathEnd options])
  where
    check condition message = unless condition (Left (QueryLimitError "invalid_path_options" message))
    validName = either (const False) (const True) . mkSqlName
    byteLength = Data.ByteString.length . Text.encodeUtf8

runPaths :: (IOE :> es) => EventRegistry -> QueryPool -> QueryRequest -> PathOptions -> Eff es (Either QueryExecutionError MetricResult)
runPaths registry pool req options =
  case first QueryLimitFailure (validateDateRange (req ^. #from) (req ^. #to) >> validatePathOptions options)
    >> first QueryCompileFailure (compilePaths registry req options) of
    Left failure -> pure (Left failure)
    Right compiled ->
      liftIO $
        runSQL
          pool
          "paths"
          ["step", "from", "to"]
          (accountParameter req <> pathParameters options <> compiled ^. #filterParameters)
          (boundedSQL PathsOrder (compiled ^. #sql))

buildPathsSQL :: EventRegistry -> QueryRequest -> PathOptions -> Either QueryExecutionError Text
buildPathsSQL registry req options = do
  first QueryLimitFailure (validateDateRange (req ^. #from) (req ^. #to) >> validatePathOptions options)
  compiled <- first QueryCompileFailure (compilePaths registry req options)
  pure (boundedSQL PathsOrder (compiled ^. #sql))

pathParameters :: PathOptions -> [QueryParameter]
pathParameters options =
  [("path_anchor", anchor) | anchor <- take 1 (catMaybes [pathStart options, pathEnd options])]
    <> zipWith (\i name -> ("path_event_" <> show i, name)) [1 :: Int ..] (pathEvents options)
    <> zipWith (\i name -> ("path_exclude_" <> show i, name)) [1 :: Int ..] (pathExclude options)

compilePaths :: EventRegistry -> QueryRequest -> PathOptions -> Either QueryCompileError CompiledMetric
compilePaths registry req options = do
  unless (isNothing (req ^. #groupBy) && isNothing (req ^. #timeGrain)) (Left (QueryCompileFilterError "paths do not support groupBy or timeGrain"))
  let declared = if pathBy options == PathRoute then [EventName "page_view"] else map EventName (pathEvents options)
      scope = filter (\(EventName name) -> name `notElem` pathExclude options) (Filters.filteredEventScope declared (req ^. #filters))
  filters <- first QueryCompileFilterError (requestFilters req "metric_filter" registry scope (req ^. #filters))
  pure CompiledMetric {sql = buildPathsSQLAggregate req options (Filters.predicates filters), groupLabels = ["step", "from", "to"], filterParameters = Filters.parameters filters, ordering = PathsOrder}

-- Filtering happens before anchor selection. Collapse only the windowed route
-- suffix, preserving the first/last physical anchor's timestamp in its direction.
buildPathsSQLAggregate :: QueryRequest -> PathOptions -> [Text] -> Text
buildPathsSQLAggregate req options predicates =
  let route = pathBy options == PathRoute
      reverseWalk = isJust (pathEnd options)
      label = if route then "path(url)" else "toString(event_name)"
      timeline = Funnel.sortedTimelineSQL "groupArray(tuple(toInt64(toUnixTimestamp64Milli(occurred_at)),event_id,path_label))"
      ordered = if reverseWalk then "arrayReverse(" <> timeline <> ")" else timeline
      anchor = if isNothing (pathStart options) && isNothing (pathEnd options) then "1" else "arrayFirstIndex(e->e.3={path_anchor:String},timeline)"
      elapsed = if reverseWalk then "timeline[anchor_index].1-e.1" else "e.1-timeline[anchor_index].1"
      number :: (Show a) => a -> Text
      number = Text.pack . show
      steps = number (pathSteps options)
      top = number (pathTop options)
      window = number (toInteger (pathWindow options) * 1000)
      namePredicate prefix names negated = if null names then [] else ["event_name " <> (if negated then "NOT IN" else "IN") <> " (" <> Text.intercalate "," [parameterPlaceholder prefix i | i <- [1 .. length names]] <> ")"]
      conditions =
        [accountPredicate, "canonical_user!=''", timestampPredicate req]
          <> (if route then ["event_name='page_view'", "NOT is_bot", "path(url)!=''"] else [])
          <> namePredicate "path_event" (pathEvents options) False
          <> namePredicate "path_exclude" (pathExclude options) True
          <> predicates
      collapse = if route then "arrayFilter((e,i)->i=1 OR e.3!=windowed[i-1].3,windowed,arrayEnumerate(windowed))" else "windowed"
   in Text.unlines
        [ "WITH selected AS (SELECT canonical_user,occurred_at,event_id," <> label <> " AS path_label FROM " <> resolvedSource req <> " WHERE " <> Text.intercalate " AND " conditions <> "),",
          "timelines AS (SELECT canonical_user," <> ordered <> " AS timeline FROM selected GROUP BY canonical_user),",
          "anchored AS (SELECT *," <> anchor <> " AS anchor_index FROM timelines),",
          "windows AS (SELECT canonical_user,arrayFilter(e->" <> elapsed <> "<=" <> window <> ",arraySlice(timeline,anchor_index)) AS windowed FROM anchored WHERE anchor_index>0),",
          "collapsed AS (SELECT canonical_user,arrayMap(e->e.3," <> collapse <> ") AS labels FROM windows),",
          "sequences AS (SELECT canonical_user,if(length(labels)<=" <> steps <> ",arrayPushBack(labels,'(end)'),arraySlice(labels,1," <> steps <> "+1)) AS nodes FROM collapsed),",
          "edges AS (SELECT canonical_user,edge.1 AS step,edge.2 AS origin,edge.3 AS target FROM sequences ARRAY JOIN arrayZip(arrayEnumerate(arrayPopBack(nodes)),arrayPopBack(nodes),arrayPopFront(nodes)) AS edge),",
          "counts AS (SELECT step,origin,target,uniqExact(canonical_user) AS users FROM edges GROUP BY step,origin,target),",
          "ranked AS (SELECT *,row_number() OVER (PARTITION BY step ORDER BY users DESC,origin,target) AS rank FROM counts),",
          "folded AS (SELECT step,if(rank<=" <> top <> ",origin,'(other)') AS folded_origin,if(rank<=" <> top <> ",target,'(other)') AS folded_target,sum(users) AS users FROM ranked GROUP BY step,folded_origin,folded_target)",
          "SELECT '' AS bucket,toJSONString([toString(step),folded_origin,folded_target]) AS group_key,toFloat64(users) AS value,step AS sort_step,folded_origin AS sort_from,folded_target AS sort_to FROM folded"
        ]

data FunnelOptions = FunnelOptions
  { mode :: !FunnelMode,
    measure :: !FunnelMeasure,
    exclusions :: ![SqlName],
    counting :: !FunnelCounting,
    attribution :: !FunnelAttribution
  }
  deriving stock (Generic, Eq, Show)

defaultFunnelOptions :: FunnelOptions
defaultFunnelOptions = FunnelOptions FunnelSequential FunnelCount [] FunnelUniques FunnelFirstTouch

runFunnel :: (IOE :> es) => QueryPool -> QueryRequest -> Int -> [SqlName] -> Eff es (Either QueryExecutionError MetricResult)
runFunnel pool req = runFunnelMetric defaultRegistry pool req Nothing defaultFunnelOptions

runFunnelMetric :: (IOE :> es) => EventRegistry -> QueryPool -> QueryRequest -> Maybe SqlName -> FunnelOptions -> Int -> [SqlName] -> Eff es (Either QueryExecutionError MetricResult)
runFunnelMetric registry pool req experiment requestedOptions window steps =
  let options = requestedOptions {exclusions = List.nub (requestedOptions ^. #exclusions)}
   in case first QueryLimitFailure (validateDateRange (req ^. #from) (req ^. #to) >> funnelLimits window steps >> exclusionLimits steps (options ^. #exclusions) >> attributionLimits steps (options ^. #attribution))
        >> first QueryCompileFailure (compileFunnel registry req experiment options window steps) of
        Left failure -> pure (Left failure)
        Right compiled ->
          liftIO $
            runSQL
              pool
              (if isNothing experiment then "funnel" else "experiment_funnel")
              (compiled ^. #groupLabels)
              (accountParameter req <> maybe [] (pure . experimentParameter) experiment <> namedParameters (funnelPrefix experiment) steps <> namedParameters "funnel_exclude" (options ^. #exclusions) <> compiled ^. #filterParameters)
              (boundedSQL FunnelDimensionsOrder (compiled ^. #sql))

exclusionLimits :: [SqlName] -> [SqlName] -> Either QueryLimitError ()
exclusionLimits steps excluded = do
  unless (length (List.nub excluded) <= 20) (Left (QueryLimitError "too_many_funnel_exclusions" "at most 20 distinct exclusions are supported"))
  unless (null [name | name <- excluded, name `elem` steps]) (Left (QueryLimitError "invalid_funnel_exclusion" "a step cannot also be excluded"))

attributionLimits :: [SqlName] -> FunnelAttribution -> Either QueryLimitError ()
attributionLimits steps (FunnelStep n) = unless (n >= 1 && n <= length steps) (Left (QueryLimitError "invalid_funnel_attribution" "attribution step must be within the requested steps"))
attributionLimits _ _ = Right ()

-- Experiment controls deliberately accept only current user dimensions. Event
-- filtering would change exposure/assignment denominators and is not implied.
experimentSelection :: QueryRequest -> Either QueryCompileError ([GroupDimension], Filters.CompiledFilters)
experimentSelection req = do
  unless
    (all (\d -> Text.isPrefixOf "user:" d || d == "cohort" || Text.isPrefixOf "cohort:" d) (fromMaybe [] (req ^. #groupBy) <> map WireFilter.dimension (req ^. #filters)))
    (Left (QueryCompileFilterError "experiment selection supports only governed user: dimensions"))
  grouping <- requestGrouping req defaultRegistry [] (req ^. #groupBy) []
  predicates <- first QueryCompileFilterError (requestFilters req "metric_filter" defaultRegistry [] (req ^. #filters))
  pure (grouping, predicates)

hasExperimentSelection :: QueryRequest -> Bool
hasExperimentSelection req = isJust (req ^. #groupBy) || not (null (req ^. #filters))

runSelectedExperiment :: (IOE :> es) => QueryPool -> Text -> QueryRequest -> [QueryParameter] -> Either QueryCompileError CompiledMetric -> Eff es (Either QueryExecutionError MetricResult)
runSelectedExperiment pool name req parameters compiled =
  case first QueryLimitFailure (validateDateRange (req ^. #from) (req ^. #to) >> unless (req ^. #timeGrain /= Just Hour) (Left (QueryLimitError "invalid_experiment_time_grain" "hour is unsupported for experiments")))
    >> first QueryCompileFailure compiled of
    Left failure -> pure (Left failure)
    Right result ->
      liftIO $
        runSQL
          pool
          name
          (result ^. #groupLabels)
          (accountParameter req <> parameters <> result ^. #filterParameters)
          (boundedSQL ExperimentUserOrder (result ^. #sql))

runExperimentDiagnostics :: (IOE :> es) => QueryPool -> QueryRequest -> Maybe SqlName -> Eff es (Either QueryExecutionError MetricResult)
runExperimentDiagnostics pool req experiment = runSelectedExperiment pool "experiment_diagnostics" req (maybe [] (pure . experimentParameter) experiment) $ do
  (grouping, predicates) <- experimentSelection req
  pure
    CompiledMetric
      { sql = experimentDiagnosticsSQL req experiment grouping (Filters.predicates predicates),
        groupLabels = map dimensionLabel grouping <> ["experiment", "measure", "variant"],
        filterParameters = Filters.parameters predicates,
        ordering = ExperimentUserOrder
      }

experimentDiagnosticsSQL :: QueryRequest -> Maybe SqlName -> [GroupDimension] -> [Text] -> Text
experimentDiagnosticsSQL req experiment grouping predicates =
  let bucket = maybe "''" (bucketExpr . Just) (req ^. #timeGrain)
      calendar = if isNothing (req ^. #timeGrain) then "SELECT '' AS bucket" else sessionCalendar req
      experiments = case experiment of
        Just _ -> "SELECT CAST({experiment:String},'Nullable(String)') AS experiment"
        Nothing -> "SELECT DISTINCT experiment FROM assignments UNION ALL SELECT CAST(NULL,'Nullable(String)') AS experiment WHERE NOT EXISTS(SELECT 1 FROM assignments)"
      fields = "group_key,sort_group_1,sort_group_2"
      qualified prefix = Text.intercalate "," [prefix <> "." <> field <> " AS " <> field | field <- ["group_key", "sort_group_1", "sort_group_2"]]
      filled =
        if not (null grouping)
          then "SELECT * FROM totals"
          else
            "SELECT calendar.bucket AS bucket,experiments.experiment AS experiment,'[]' AS group_key,CAST(NULL,'Nullable(String)') AS sort_group_1,CAST(NULL,'Nullable(String)') AS sort_group_2,ifNull(totals.exposed_users,0.) AS exposed_users,ifNull(totals.multiple_exposure,0.) AS multiple_exposure FROM (" <> calendar <> ") AS calendar CROSS JOIN (" <> experiments <> ") AS experiments LEFT JOIN totals ON calendar.bucket=totals.bucket AND isNotDistinctFrom(experiments.experiment,totals.experiment)"
   in Text.unlines
        [ "WITH exposures AS (SELECT canonical_user,event_id,occurred_at," <> bucket <> " AS bucket," <> groupProjection grouping <> ",CAST(toString(getSubcolumn(properties_json,'experiment')),'Nullable(String)') AS experiment,CAST(toString(getSubcolumn(properties_json,'variant')),'String') AS variant FROM " <> resolvedSource req <> " WHERE " <> accountPredicate <> " AND canonical_user!='' AND " <> timestampPredicate req <> " AND " <> validExposurePredicate <> experimentFilterClause experiment <> propertyFilterClause predicates <> "),",
          "assignments AS (SELECT bucket,experiment," <> fields <> ",canonical_user,argMin(variant,tuple(occurred_at,event_id)) AS assigned,groupUniqArray(variant) AS variants FROM exposures GROUP BY bucket,experiment," <> fields <> ",canonical_user),",
          "totals AS (SELECT bucket,experiment," <> fields <> ",toFloat64(count()) AS exposed_users,toFloat64(countIf(length(variants)>1)) AS multiple_exposure FROM assignments GROUP BY bucket,experiment," <> fields <> "),",
          "observed_variants AS (SELECT DISTINCT bucket,experiment," <> fields <> ",arrayJoin(variants) AS variant FROM assignments),",
          "assigned_counts AS (SELECT bucket,experiment," <> fields <> ",assigned AS variant,toFloat64(count()) AS assigned_users FROM assignments GROUP BY bucket,experiment," <> fields <> ",assigned),",
          "variant_totals AS (SELECT observed.bucket AS bucket,observed.experiment AS experiment," <> qualified "observed" <> ",observed.variant AS variant,ifNull(assigned.assigned_users,0.) AS assigned_users,totals.exposed_users AS exposed_users FROM observed_variants AS observed LEFT JOIN assigned_counts AS assigned ON observed.bucket=assigned.bucket AND observed.experiment=assigned.experiment AND observed.group_key=assigned.group_key AND observed.variant=assigned.variant INNER JOIN totals ON observed.bucket=totals.bucket AND observed.experiment=totals.experiment AND observed.group_key=totals.group_key),",
          "filled AS (" <> filled <> "),",
          "answers AS (SELECT bucket,experiment," <> fields <> ",CAST(NULL,'Nullable(String)') AS variant,m.1 AS measure,m.2 AS value FROM filled ARRAY JOIN [('exposed_users',exposed_users),('multiple_exposure',multiple_exposure)] AS m UNION ALL SELECT bucket,experiment," <> fields <> ",CAST(variant,'Nullable(String)') AS variant,m.1 AS measure,m.2 AS value FROM variant_totals ARRAY JOIN [('assigned_users',assigned_users),('variant_share',if(exposed_users=0,0.,assigned_users/exposed_users))] AS m)",
          "SELECT bucket," <> extendGroups ["experiment", "measure", "variant"] <> " AS group_key,sort_group_1,sort_group_2,experiment AS sort_experiment,measure AS sort_measure,variant AS sort_variant,value FROM answers"
        ]

compileTraitExposures :: QueryRequest -> Maybe SqlName -> Either QueryCompileError CompiledMetric
compileTraitExposures req experiment = do
  (grouping, predicates) <- experimentSelection req
  let bucket = maybe "''" (bucketExpr . Just) (req ^. #timeGrain)
      sql =
        Text.unlines
          [ "SELECT bucket," <> extendGroups ["experiment", "variant"] <> " AS group_key,sort_group_1,sort_group_2,experiment AS sort_experiment,variant AS sort_variant,'' AS sort_measure,toFloat64(uniqExact(canonical_user)) AS value",
            "FROM (SELECT canonical_user," <> bucket <> " AS bucket," <> groupProjection grouping <> ",CAST(toString(getSubcolumn(properties_json,'experiment')),'String') AS experiment,CAST(toString(getSubcolumn(properties_json,'variant')),'String') AS variant FROM " <> resolvedSource req <> " WHERE " <> accountPredicate <> " AND canonical_user!='' AND " <> timestampPredicate req <> " AND " <> validExposurePredicate <> experimentFilterClause experiment <> propertyFilterClause (Filters.predicates predicates) <> ") GROUP BY bucket,group_key,sort_group_1,sort_group_2,experiment,variant"
          ]
  pure CompiledMetric {sql, groupLabels = map dimensionLabel grouping <> ["experiment", "variant"], filterParameters = Filters.parameters predicates, ordering = ExperimentUserOrder}

compileTraitExperimentConversion :: QueryRequest -> Either QueryCompileError CompiledMetric
compileTraitExperimentConversion req = do
  (grouping, predicates) <- experimentSelection req
  let sql =
        Text.unlines
          [ "WITH base AS (SELECT * FROM " <> resolvedSource req <> " WHERE " <> accountPredicate <> " AND canonical_user!='' AND " <> timestampPredicate req <> propertyFilterClause (Filters.predicates predicates) <> "),",
            "exposures AS (SELECT canonical_user,CAST(toString(getSubcolumn(properties_json,'variant')),'String') AS variant,min(occurred_at) AS first_exposure," <> groupProjection grouping <> " FROM base WHERE " <> validExposurePredicate <> " AND CAST(toString(getSubcolumn(properties_json,'experiment')),'String')={experiment:String} GROUP BY canonical_user,variant,sort_group_1,sort_group_2),",
            "conversions AS (SELECT canonical_user,max(occurred_at) AS last_conversion FROM base WHERE event_name={conversion_event:String} GROUP BY canonical_user),",
            "totals AS (SELECT e.variant AS variant,e.group_key AS group_key,e.sort_group_1 AS sort_group_1,e.sort_group_2 AS sort_group_2,toFloat64(uniqExact(e.canonical_user)) AS exposed,toFloat64(uniqExactIf(e.canonical_user,c.last_conversion>=e.first_exposure)) AS converted FROM exposures AS e LEFT JOIN conversions AS c ON e.canonical_user=c.canonical_user GROUP BY e.variant,e.group_key,e.sort_group_1,e.sort_group_2)",
            "SELECT '' AS bucket," <> extendGroups ["m.1", "variant", "{experiment:String}"] <> " AS group_key,sort_group_1,sort_group_2,{experiment:String} AS sort_experiment,variant AS sort_variant,m.1 AS sort_measure,m.2 AS value FROM totals ARRAY JOIN [('exposed',exposed),('converted',converted),('conversion_rate',if(exposed=0,0.,converted/exposed))] AS m"
          ]
  pure CompiledMetric {sql, groupLabels = map dimensionLabel grouping <> ["measure", "variant", "experiment"], filterParameters = Filters.parameters predicates, ordering = ExperimentUserOrder}

runExperimentExposures :: (IOE :> es) => QueryPool -> QueryRequest -> Maybe SqlName -> Eff es (Either QueryExecutionError MetricResult)
runExperimentExposures pool req experiment
  | hasExperimentSelection req = runSelectedExperiment pool "experiment_exposures" req (maybe [] (pure . experimentParameter) experiment) (compileTraitExposures req experiment)
  | otherwise =
      checked req (Right ()) $
        runSQLWith
          pool
          "experiment_exposures"
          experimentExposuresAggPoint
          (accountParameter req <> maybe [] (pure . experimentParameter) experiment)
          (buildExperimentExposuresSQL req experiment)

runExperimentConversion :: (IOE :> es) => QueryPool -> QueryRequest -> SqlName -> SqlName -> Eff es (Either QueryExecutionError MetricResult)
runExperimentConversion pool req experiment conversionEvent
  | hasExperimentSelection req = runSelectedExperiment pool "experiment_conversion" req [experimentParameter experiment, conversionEventParameter conversionEvent] (compileTraitExperimentConversion req)
  | otherwise =
      checked req (Right ()) $
        runSQLWith
          pool
          "experiment_conversion"
          (experimentConversionAggPoint experiment)
          (accountParameter req <> [experimentParameter experiment, conversionEventParameter conversionEvent])
          (buildExperimentConversionSQL req experiment conversionEvent)

runExperimentFunnel :: (IOE :> es) => QueryPool -> QueryRequest -> SqlName -> Int -> [SqlName] -> Eff es (Either QueryExecutionError MetricResult)
runExperimentFunnel pool req experiment = runFunnelMetric defaultRegistry pool req (Just experiment) defaultFunnelOptions

checked :: (IOE :> es) => QueryRequest -> Either QueryLimitError () -> IO (Either QueryExecutionError MetricResult) -> Eff es (Either QueryExecutionError MetricResult)
checked req additional action =
  case validateDateRange (req ^. #from) (req ^. #to) >> specializedParameters req >> additional of
    Left err -> pure (Left (QueryLimitFailure err))
    Right () -> liftIO action

specializedParameters :: QueryRequest -> Either QueryLimitError ()
specializedParameters req = do
  unless (null (req ^. #filters)) (Left (QueryLimitError "unsupported_query_parameter" "event filters are unsupported for this route"))
  unless (isNothing (req ^. #groupBy)) (Left (QueryLimitError "unsupported_query_parameter" "groupBy is unsupported for this route"))

funnelLimits :: Int -> [SqlName] -> Either QueryLimitError ()
funnelLimits window steps = do
  validateSteps steps
  if window >= 1 && window <= 7776000
    then Right ()
    else Left (QueryLimitError "invalid_funnel_window" "expected 1..7776000 seconds")

-- The extra row witnesses overflow; it never becomes a partial success.
-- Sort columns belong to the aggregate subquery and stay out of the wire projection.
boundedSQL :: ResultOrder -> Text -> Text
boundedSQL order sql =
  Text.unlines
    [ "SELECT CAST(bucket, 'String') AS bucket, CAST(group_key, 'String') AS group_key, CAST(value, 'Float64') AS value",
      "FROM (",
      sql,
      ")",
      "ORDER BY " <> case order of
        PathsOrder -> "sort_step, value DESC, sort_from, sort_to"
        ExperimentUserOrder -> "bucket, sort_experiment NULLS FIRST, sort_group_1 NULLS FIRST, sort_group_2 NULLS FIRST, sort_measure, sort_variant NULLS FIRST"
        FunnelDimensionsOrder -> "sort_variant NULLS FIRST, sort_group_1 NULLS FIRST, sort_group_2 NULLS FIRST, sort_step, sort_measure"
        DiagnosticOrder -> "bucket, sort_experiment NULLS FIRST, sort_measure, sort_variant NULLS FIRST"
        BucketDimensions -> "bucket, sort_group_1 NULLS FIRST, sort_group_2 NULLS FIRST"
        BucketDimensionsMeasure -> "bucket, sort_group_1 NULLS FIRST, sort_group_2 NULLS FIRST, sort_measure"
        RetentionDimensionsOrder -> "sort_cohort, sort_group_1 NULLS FIRST, sort_group_2 NULLS FIRST, sort_offset"
        BucketGroup -> "bucket, group_key"
        ExperimentExposureOrder -> "bucket, sort_experiment, sort_variant"
        ExperimentConversionOrder -> "sort_measure, sort_variant"
        RetentionOrder -> "sort_cohort, sort_offset"
        FunnelOrder -> "sort_step"
        ExperimentFunnelOrder -> "sort_variant, sort_step",
      "LIMIT " <> Text.pack (show (maxMetricPoints + 1))
    ]

type QueryParameter = (String, Text)

runSQL :: QueryPool -> Text -> [Text] -> [QueryParameter] -> Text -> IO (Either QueryExecutionError MetricResult)
runSQL pool name groupName =
  runSQLWith pool name (defaultPoint groupName)

runSQLWith :: QueryPool -> Text -> (AggRow -> Either Text MetricPoint) -> [QueryParameter] -> Text -> IO (Either QueryExecutionError MetricResult)
runSQLWith pool metric toPoint parameters sql = do
  outcome <- trySynchronous $
    timeout (queryDeadlineMicros pool) $
      (if "analytics.events_resolved_http(" `Text.isInfixOf` sql then withIdentityQueryConnection pool (required "account_id") (required "identity_from") (required "identity_to") else withMetricsQueryConnection pool) $
        -- ClickHaskell prepends each completed block; restore arrival order
        -- without sorting or reversing any rows within a repaired block.
        \conn -> concat . reverse <$> select (aggSelect parameters sql) conn (pure . repairAggRows)
  pure $ case outcome of
    Left err -> case fromException err :: Maybe ClientError of
      Just (DatabaseException packet) | Protocol.code packet `elem` [159, 160, 241] -> Left QueryResourceLimit
      _ -> Left (QueryStorageFailure (Text.pack (show err)))
    Right Nothing -> Left QueryResourceLimit
    Right (Just rows)
      | length rows > maxMetricPoints -> Left MetricResultTooLarge
      | otherwise -> case traverse toPoint rows of
          Left message -> Left (QueryStorageFailure ("invalid metric projection: " <> message))
          Right points -> Right MetricResult {metric, points}
  where
    required key = fromMaybe (error "resolved query requires compiler scope parameter") (lookup key parameters)

-- ClickHaskell 1.1.0 reverses the first field of a three-field generic record
-- relative to the other fields. Repair each result block before it escapes the
-- typed decoder so bucket/value associations remain honest.
repairAggRows :: [AggRow] -> [AggRow]
repairAggRows rows =
  zipWith repair rows (reverse (fmap (^. #bucket) rows))
  where
    repair row bucketValue = row & #bucket .~ bucketValue

aggSelect :: [QueryParameter] -> Text -> Select AggColumns AggRow
aggSelect parameters sql =
  passParameters (foldr addOne id parameters) $
    unsafeMkSelect $
      const $
        Text.encodeUtf8Builder $
          sql <> "\nSETTINGS enable_analyzer=1,short_circuit_function_evaluation='force_enable', compile_expressions = 0, compile_aggregate_expressions = 0, compile_sort_description = 0"
  where
    addOne (name, value) rest =
      addParameter name (toChType (Text.encodeUtf8 value) :: ChString) . rest

defaultPoint :: [Text] -> AggRow -> Either Text MetricPoint
defaultPoint labels AggRow {bucket, group_key, value} = do
  bucketText <- decodeUtf8 bucket
  key <- decodeUtf8 group_key
  group <- decodeGroups labels key
  pure MetricPoint {bucket = nonEmpty bucketText, group, value}

experimentExposuresAggPoint :: AggRow -> Either Text MetricPoint
experimentExposuresAggPoint = defaultPoint ["experiment", "variant"]

experimentConversionAggPoint :: SqlName -> AggRow -> Either Text MetricPoint
experimentConversionAggPoint experiment row = do
  point <- defaultPoint ["measure", "variant"] row
  pure (point & #group %~ Map.insert "experiment" (Just (renderSqlName experiment)))

experimentExposuresPoint :: Maybe Text -> Text -> Double -> Either Text MetricPoint
experimentExposuresPoint bucketValue key amount = do
  group <- decodeGroups ["experiment", "variant"] key
  pure MetricPoint {bucket = bucketValue, group, value = amount}

experimentConversionPoint :: SqlName -> Text -> Double -> Either Text MetricPoint
experimentConversionPoint experiment key amount = do
  group <- Map.insert "experiment" (Just (renderSqlName experiment)) <$> decodeGroups ["measure", "variant"] key
  pure MetricPoint {bucket = Nothing, group, value = amount}

experimentFunnelPoint :: SqlName -> Text -> Double -> Either Text MetricPoint
experimentFunnelPoint experiment key amount = do
  group <- Map.insert "experiment" (Just (renderSqlName experiment)) <$> decodeGroups ["index", "step", "variant"] key
  pure MetricPoint {bucket = Nothing, group, value = amount}

decodeGroups :: [Text] -> Text -> Either Text (Map.Map Text (Maybe Text))
decodeGroups labels key = do
  values <- first Text.pack (Aeson.eitherDecodeStrict' (Text.encodeUtf8 key) :: Either String [Maybe Text])
  unless (length labels == length values) (Left "group projection has the wrong arity")
  pure (Map.fromList (zip labels values))

nonEmpty :: Text -> Maybe Text
nonEmpty value
  | Text.null value = Nothing
  | otherwise = Just value

decodeUtf8 :: ByteString -> Either Text Text
decodeUtf8 = first (Text.pack . show) . Text.decodeUtf8'

compileMetric :: EventRegistry -> BuiltinMetric -> QueryRequest -> Either QueryCompileError CompiledMetric
compileMetric registry metric req = case metric of
  Simple def | def ^. #name == "sessions" -> compileSessions SessionCount req
  Simple def -> compileSimpleMetric registry def req
  Ratioed ratio | ratio ^. #name == "conversion_rate" -> compileOrderedConversion registry req
  Ratioed ratio -> do
    let scope = Filters.filteredEventScope (definitionEvents (ratio ^. #numerator) <> definitionEvents (ratio ^. #denominator)) (req ^. #filters)
    when (any (Text.isPrefixOf "prop:") (fromMaybe [] (req ^. #groupBy))) (Left (QueryCompileUnsupportedPropertyGrouping (ratio ^. #name)))
    grouping <- requestGrouping req registry scope (req ^. #groupBy) []
    when (any isPropertyDimension grouping) (Left (QueryCompileUnsupportedPropertyGrouping (ratio ^. #name)))
    common <- first QueryCompileFilterError (requestFilters req "metric_filter" registry scope (req ^. #filters))
    numeratorInputs <- definitionFilters (ratio ^. #numerator)
    denominatorInputs <- definitionFilters (ratio ^. #denominator)
    numeratorFilters <- first QueryCompileFilterError (Filters.compileMetricFiltersWithPrefix "numerator_filter" registry (definitionEvents (ratio ^. #numerator)) numeratorInputs)
    denominatorFilters <- first QueryCompileFilterError (Filters.compileMetricFiltersWithPrefix "denominator_filter" registry (definitionEvents (ratio ^. #denominator)) denominatorInputs)
    pure CompiledMetric {sql = buildRatioSQL ratio grouping (Filters.predicates common) (Filters.predicates numeratorFilters) (Filters.predicates denominatorFilters) req, groupLabels = map dimensionLabel grouping, filterParameters = Filters.parameters common <> Filters.parameters numeratorFilters <> Filters.parameters denominatorFilters, ordering = BucketDimensions}

-- Two-step conversion shares the selected-chain count contract. Group ownership
-- is fixed at the earliest eligible signup_started, even when a later attempt wins.
compileOrderedConversion :: EventRegistry -> QueryRequest -> Either QueryCompileError CompiledMetric
compileOrderedConversion registry req = do
  unless (isNothing (req ^. #timeGrain)) (Left (QueryCompileFilterError "timeGrain is unsupported for ordered conversion"))
  when (any (Text.isPrefixOf "prop:") (fromMaybe [] (req ^. #groupBy))) (Left (QueryCompileUnsupportedPropertyGrouping "conversion_rate"))
  steps <- first QueryCompileFilterError (traverse mkSqlName ["signup_started", "signup_completed"])
  compiled <- compileFunnel registry req Nothing defaultFunnelOptions (fromInteger (min 7776000 (max 1 (diffDays (req ^. #to) (req ^. #from) * 86400)))) steps
  let sql = "SELECT '' AS bucket,dimensions AS group_key,sort_group_1,sort_group_2,if(maxIf(value,sort_step=1)=0,0.,maxIf(value,sort_step=2)/maxIf(value,sort_step=1)) AS value FROM (SELECT *,toJSONString(arraySlice(JSONExtract(group_key,'Array(Nullable(String))'),1,length(JSONExtract(group_key,'Array(Nullable(String))'))-2)) AS dimensions FROM (" <> compiled ^. #sql <> ")) GROUP BY sort_group_1,sort_group_2,dimensions"
  pure compiled {sql, groupLabels = take (length (compiled ^. #groupLabels) - 2) (compiled ^. #groupLabels), filterParameters = namedParameters "funnel_step" steps <> compiled ^. #filterParameters, ordering = BucketDimensions}

compileSimpleMetric :: EventRegistry -> MetricDefinition -> QueryRequest -> Either QueryCompileError CompiledMetric
compileSimpleMetric registry def req = do
  defaults <- definitionFilters def
  let inputs = defaults <> req ^. #filters
      scope = Filters.filteredEventScope (definitionEvents def) (req ^. #filters)
  grouping <- requestGrouping req registry scope (req ^. #groupBy) (map ("prop:" <>) (def ^. #groupBy))
  compiled <- first QueryCompileFilterError (requestFilters req "metric_filter" registry scope inputs)
  compiledSQL <- buildSimpleSQL registry grouping (Filters.predicates compiled) def req
  pure CompiledMetric {sql = compiledSQL, groupLabels = map dimensionLabel grouping, filterParameters = Filters.parameters compiled, ordering = BucketDimensions}

definitionFilters :: MetricDefinition -> Either QueryCompileError [MetricFilter]
definitionFilters def = first QueryCompileFilterError (traverse (\(name, operand) -> WireFilter.mkMetricFilter ("prop:" <> name) WireFilter.FilterEq (Just operand)) (Map.toList (def ^. #filters)))

buildSimpleSQL :: EventRegistry -> [GroupDimension] -> [Text] -> MetricDefinition -> QueryRequest -> Either QueryCompileError Text
buildSimpleSQL registry grouping predicates def req
  | aggregation def == UniqueCount = Right (uniqueUsersSQL grouping predicates def req)
  | aggregation def == Sum = aggregate "sum"
  | aggregation def == Average = aggregate "avg"
  | otherwise = Right (countEventsSQL grouping predicates def req)
  where
    aggregate functionName = do
      name <- maybe (Left (QueryCompileMissingAggregationProperty (def ^. #name))) Right (def ^. #aggregationProperty)
      property <- first QueryCompilePropertyError (resolveNumericProperty registry (definitionEvents def) name)
      pure (propertyAggregateSQL functionName property grouping predicates def req)

-- Canonical rows deduplicate queue replay before every query-time aggregate
-- or identity join. Day/week raw-identity sketches remain approximate; exact
-- page-view states union event IDs across arbitrary insert boundaries.

-- | The private relation bounds canonical candidate facts before expansion;
-- evidence remains available across all retained history for this account.
queryTraits :: QueryRequest -> [Text]
queryTraits req = Traits.referencedTraits (fromMaybe [] (req ^. #groupBy) <> map WireFilter.dimension (req ^. #filters))

hasUserTraits :: QueryRequest -> Bool
hasUserTraits req = not (null (queryTraits req)) || not (null (cohorts req))

resolvedSource :: QueryRequest -> Text
resolvedSource req = Traits.eventSource (queryTraits req) (rawResolvedSource req)

rawResolvedSource :: QueryRequest -> Text
rawResolvedSource req =
  "analytics.events_resolved_http(scope_all_accounts=0, scope_account={account_id:String}, scope_from=toDateTime64("
    <> sqlString (renderDay (req ^. #from) <> " 00:00:00")
    <> ",3,'UTC'), scope_to=toDateTime64("
    <> sqlString (renderDay (req ^. #to) <> " 00:00:00")
    <> ",3,'UTC'))"

buildRatioSQL :: RatioMetric -> [GroupDimension] -> [Text] -> [Text] -> [Text] -> QueryRequest -> Text
buildRatioSQL RatioMetric {numerator, denominator} grouping predicates numeratorFilters denominatorFilters req =
  let numeratorPredicate = eventNamePredicate "numerator_event_name" (validatedEventNames numerator)
      denominatorPredicate = eventNamePredicate "denominator_event_name" (validatedEventNames denominator)
      conditional base extra = Text.intercalate " AND " (base : extra)
      bucket = maybe "''" (bucketExpr . Just) (req ^. #timeGrain)
   in Text.unlines
        [ "SELECT bucket,group_key,sort_group_1,sort_group_2,if(denominator = 0, 0, numerator / denominator) AS value",
          "FROM ( SELECT " <> bucket <> " AS bucket, " <> groupProjection grouping <> ",",
          "      toFloat64(uniqExactIf(canonical_user, " <> conditional numeratorPredicate numeratorFilters <> ")) AS numerator,",
          "      toFloat64(uniqExactIf(canonical_user, " <> conditional denominatorPredicate denominatorFilters <> ")) AS denominator",
          "    FROM " <> resolvedSource req,
          "    WHERE " <> accountPredicate,
          "      AND canonical_user != ''",
          "      AND (" <> numeratorPredicate <> " OR " <> denominatorPredicate <> ")",
          "      AND " <> timestampPredicate req <> propertyFilterClause predicates,
          if null grouping && isNothing (req ^. #timeGrain) then "" else "GROUP BY bucket,sort_group_1,sort_group_2",
          ")"
        ]

countEventsSQL :: [GroupDimension] -> [Text] -> MetricDefinition -> QueryRequest -> Text
countEventsSQL grouping predicates def req =
  simpleAggregateSQL "toFloat64(count(DISTINCT event_id))" "analytics.events_canonical" grouping (predicates <> ["NOT is_bot" | def ^. #name == "page_views" && not (req ^. #includeBots)]) def req

uniqueUsersSQL :: [GroupDimension] -> [Text] -> MetricDefinition -> QueryRequest -> Text
uniqueUsersSQL grouping predicates def req =
  simpleAggregateSQL
    "toFloat64(uniqExact(canonical_user))"
    (resolvedSource req)
    grouping
    (["canonical_user != ''"] <> ["NOT is_bot" | def ^. #name `elem` ["active_users", "returning_users"], not (req ^. #includeBots)] <> [activityPredicate | def ^. #name `elem` ["active_users", "returning_users"]] <> predicates)
    def
    req

propertyAggregateSQL :: Text -> PropertyName -> [GroupDimension] -> [Text] -> MetricDefinition -> QueryRequest -> Text
propertyAggregateSQL functionName property grouping predicates def req =
  simpleAggregateSQL
    ("toFloat64(" <> functionName <> "(" <> propertyFloatExpr property <> "))")
    "analytics.events_canonical"
    grouping
    (["isNotNull(" <> propertyFloatExpr property <> ")"] <> predicates)
    def
    req

simpleAggregateSQL :: Text -> Text -> [GroupDimension] -> [Text] -> MetricDefinition -> QueryRequest -> Text
simpleAggregateSQL aggregationSQL source grouping predicates def req =
  Text.unlines
    [ "SELECT " <> bucketExpr (effectiveGrain def req) <> " AS bucket, " <> groupProjection grouping <> ",",
      "       " <> aggregationSQL <> " AS value",
      "FROM " <> (if hasUserTraits req && source == "analytics.events_canonical" then resolvedSource req else source),
      "WHERE " <> accountPredicate,
      "  AND " <> timestampPredicate req <> eventNameClause "event_name" (validatedEventNames def) <> propertyFilterClause predicates,
      "GROUP BY bucket,sort_group_1,sort_group_2"
    ]

activityPredicate :: Text
activityPredicate = "event_name NOT IN ('identify','identify_once','alias','group')"

buildSessionsSQL :: QueryRequest -> Either QueryCompileError Text
buildSessionsSQL = buildSessionMetricSQL SessionCount

buildSessionMetricSQL :: SessionMeasure -> QueryRequest -> Either QueryCompileError Text
buildSessionMetricSQL measure req = boundedSQL BucketDimensions . view #sql <$> compileSessions measure req

compileSessions :: SessionMeasure -> QueryRequest -> Either QueryCompileError CompiledMetric
compileSessions measure req = do
  let days = diffDays (req ^. #to) (req ^. #from)
  unless (days > 0 && days <= maxQueryDays) (Left (QueryCompileFilterError "session calendar requires a positive range of at most 366 days"))
  when
    (any (Text.isPrefixOf "prop:" . WireFilter.dimension) (req ^. #filters))
    (Left (QueryCompileFilterError "arbitrary property filters are unsupported on sessions; select session attributes"))
  when
    (any (Text.isPrefixOf "prop:") (fromMaybe [] (req ^. #groupBy)))
    (Left (QueryCompileInvalidGroupBy "arbitrary property grouping is unsupported on sessions"))
  grouping <- requestedGroupingWith (cohortDimension req "primary_subject" (resolveSessionDimension defaultRegistry [])) (req ^. #groupBy) []
  predicates <- first QueryCompileFilterError (Filters.compileFiltersWith "session_filter" (cohortDimension req "primary_subject" (resolveSessionDimension defaultRegistry [])) (normalizeCohortFilters (req ^. #filters)))
  let sessions = if hasUserTraits req then sessionProjection (rawResolvedSource (retainedScope req)) True else materializedSessionProjection
      selected =
        "SELECT * FROM ("
          <> Traits.sessionSource (queryTraits req) sessions
          <> ") WHERE "
          <> accountPredicate
          <> " AND "
          <> Text.intercalate " AND " ([timestampPredicate req] <> ["NOT is_bot" | not (req ^. #includeBots)] <> Filters.predicates predicates)
      aggregate = case measure of
        SessionCount -> "toFloat64(count())"
        SessionBounceRate -> "toFloat64(countIf(page_view_count=1 AND engagement_count=0))/count()"
        SessionAverageDuration -> "avg(dateDiff('millisecond',occurred_at,session_end_at)/1000.0)"
      grouped = "SELECT " <> bucketExpr (req ^. #timeGrain) <> " AS bucket," <> groupProjection grouping <> "," <> aggregate <> " AS value FROM (" <> selected <> ") GROUP BY bucket,sort_group_1,sort_group_2"
      -- Generate bounded UTC labels in Haskell: native DateTime calendars
      -- silently clamp dates outside their narrower epoch range.
      calendar = sessionCalendar req
      sql =
        if null grouping
          then "SELECT calendar.bucket AS bucket,'[]' AS group_key,CAST(NULL,'Nullable(String)') AS sort_group_1,CAST(NULL,'Nullable(String)') AS sort_group_2,ifNull(answer.value,0) AS value FROM (" <> calendar <> ") AS calendar LEFT JOIN (" <> grouped <> ") AS answer USING(bucket)"
          else grouped
  pure CompiledMetric {sql, groupLabels = map dimensionLabel grouping, filterParameters = Filters.parameters predicates, ordering = BucketDimensions}

sessionCalendar :: QueryRequest -> Text
sessionCalendar req = "SELECT arrayJoin([" <> Text.intercalate "," (map (\label -> "'" <> label <> "'") labels) <> "]) AS bucket"
  where
    days = [addDays offset (req ^. #from) | offset <- [0 .. diffDays (req ^. #to) (req ^. #from) - 1]]
    labels = case req ^. #timeGrain of
      Just Hour -> [date day <> " " <> (if hour < 10 then "0" else "") <> Text.pack (show hour) <> ":00:00" | day <- days, hour <- [0 .. 23 :: Int]]
      Just Week -> map date (List.nub [addDays (1 - fromIntegral (fromEnum (dayOfWeek day))) day | day <- days])
      Just Month -> map date (List.nub [fromGregorian year month 1 | day <- days, let (year, month, _) = toGregorian day])
      _ -> map date days
    date = Text.pack . formatTime defaultTimeLocale "%Y-%m-%d"

-- Closed-day activity builders share exact subjects, filters and group populations.
buildUsersSQL :: EventRegistry -> UserWindow -> QueryRequest -> Either QueryCompileError Text
buildUsersSQL registry window req = boundedCompiled (compileUsers registry window req)

buildStickinessSQL :: EventRegistry -> QueryRequest -> Either QueryCompileError Text
buildStickinessSQL registry req = boundedCompiled (compileRolling registry 30 True req)

buildLifecycleSQL :: EventRegistry -> QueryRequest -> Either QueryCompileError Text
buildLifecycleSQL registry req = boundedCompiled (compileLifecycle registry req)

boundedCompiled :: Either QueryCompileError CompiledMetric -> Either QueryCompileError Text
boundedCompiled result = do
  compiled <- result
  pure (boundedSQL (compiled ^. #ordering) (compiled ^. #sql))

compileUsers :: EventRegistry -> UserWindow -> QueryRequest -> Either QueryCompileError CompiledMetric
compileUsers registry CalendarWindow req = compileMetric registry (Simple activeUsers) req
compileUsers registry window req = compileRolling registry (windowDays window) False req

activityPopulation :: EventRegistry -> QueryRequest -> QueryRequest -> Either QueryCompileError ([GroupDimension], Filters.CompiledFilters, Text)
activityPopulation registry req scope = do
  let events = Filters.filteredEventScope [] (req ^. #filters)
  grouping <- requestGrouping req registry events (req ^. #groupBy) []
  filters <- first QueryCompileFilterError (requestFilters req "metric_filter" registry events (req ^. #filters))
  let population =
        Text.unlines
          [ "SELECT DISTINCT canonical_user,toDate(occurred_at) AS active_day," <> groupProjection grouping,
            "FROM " <> resolvedSource scope,
            "WHERE " <> accountPredicate <> " AND canonical_user!='' AND " <> activityPredicate,
            "AND " <> timestampPredicate scope <> propertyFilterClause (["NOT is_bot" | not (req ^. #includeBots)] <> Filters.predicates filters)
          ]
  pure (grouping, filters, population)

-- Missing ungrouped UTC buckets are zeros; absent dimension groups stay absent.
fillActivity :: QueryRequest -> [GroupDimension] -> [Text] -> Text -> Text
fillActivity req grouping fields aggregate
  | not (null grouping) = aggregate
  | otherwise =
      "SELECT calendar.bucket AS bucket,'[]' AS group_key,CAST(NULL,'Nullable(String)') AS sort_group_1,CAST(NULL,'Nullable(String)') AS sort_group_2,"
        <> Text.intercalate "," ["ifNull(answer." <> field <> ",0) AS " <> field | field <- fields]
        <> " FROM ("
        <> sessionCalendar req
        <> ") AS calendar LEFT JOIN ("
        <> aggregate
        <> ") AS answer USING(bucket)"

extendGroups :: [Text] -> Text
extendGroups fields = "toJSONString(arrayConcat(JSONExtract(group_key,'Array(Nullable(String))'),[" <> Text.intercalate "," fields <> "]))"

compileRolling :: EventRegistry -> Integer -> Bool -> QueryRequest -> Either QueryCompileError CompiledMetric
compileRolling registry width stickiness req = do
  first (QueryCompileFilterError . Text.pack . show) (dailyGrain req)
  let scope = req {from = addDays (negate (width - 1)) (req ^. #from)}
  (grouping, filters, population) <- activityPopulation registry req scope
  let aggregate =
        Text.unlines
          [ "WITH population AS (" <> population <> "),expanded AS (SELECT *,addDays(active_day,arrayJoin(range(" <> Text.pack (show width) <> "))) AS series_day FROM population)",
            "SELECT toString(series_day) AS bucket,group_key,sort_group_1,sort_group_2,uniqExact(canonical_user) AS rolling_active,uniqExactIf(canonical_user,active_day=series_day) AS daily_active",
            "FROM expanded WHERE series_day>=toDate(" <> sqlString (renderDay (req ^. #from)) <> ") AND series_day<toDate(" <> sqlString (renderDay (req ^. #to)) <> ")",
            "GROUP BY series_day,group_key,sort_group_1,sort_group_2"
          ]
      series = fillActivity req grouping ["rolling_active", "daily_active"] aggregate
      sql
        | stickiness = "SELECT bucket," <> extendGroups ["measure.2"] <> " AS group_key,sort_group_1,sort_group_2,measure.1 AS sort_measure,toFloat64(measure.3) AS value FROM (" <> series <> ") ARRAY JOIN [(1,'daily_active',toFloat64(daily_active)),(2,'rolling30_active',toFloat64(rolling_active)),(3,'ratio',if(rolling_active=0,0,daily_active/rolling_active))] AS measure"
        | otherwise = "SELECT bucket,group_key,sort_group_1,sort_group_2,toFloat64(rolling_active) AS value FROM (" <> series <> ")"
  pure CompiledMetric {sql, groupLabels = map dimensionLabel grouping <> ["measure" | stickiness], filterParameters = Filters.parameters filters, ordering = if stickiness then BucketDimensionsMeasure else BucketDimensions}

compileLifecycle :: EventRegistry -> QueryRequest -> Either QueryCompileError CompiledMetric
compileLifecycle registry req = do
  first (QueryCompileFilterError . Text.pack . show) (dailyGrain req)
  (grouping, filters, population) <- activityPopulation registry req (historicalScope req)
  let earliest = sqlString (renderDay (addDays (-1) (req ^. #from)))
      latest = sqlString (renderDay (req ^. #to))
      aggregate =
        Text.unlines
          [ "WITH population AS (" <> population <> "), histories AS (SELECT canonical_user,group_key,sort_group_1,sort_group_2,min(active_day) AS first_seen,groupUniqArray(active_day) AS days FROM population GROUP BY canonical_user,group_key,sort_group_1,sort_group_2),",
            "candidates AS (SELECT *,arrayFilter(day->day>=toDate(" <> earliest <> ") AND day<toDate(" <> latest <> "),days) AS recent FROM histories),",
            "expanded AS (SELECT *,arrayJoin(arrayDistinct(arrayConcat(recent,arrayMap(day->addDays(day,1),recent)))) AS series_day FROM candidates)",
            "SELECT toString(series_day) AS bucket,group_key,sort_group_1,sort_group_2,",
            "uniqExactIf(canonical_user,has(days,series_day) AND first_seen=series_day) AS new_count,",
            "uniqExactIf(canonical_user,has(days,series_day) AND has(days,addDays(series_day,-1))) AS returning_count,",
            "uniqExactIf(canonical_user,has(days,series_day) AND NOT has(days,addDays(series_day,-1)) AND first_seen<series_day) AS resurrecting_count,",
            "uniqExactIf(canonical_user,NOT has(days,series_day) AND has(days,addDays(series_day,-1))) AS dormant_count",
            "FROM expanded WHERE series_day>=toDate(" <> sqlString (renderDay (req ^. #from)) <> ") AND series_day<toDate(" <> latest <> ") GROUP BY series_day,group_key,sort_group_1,sort_group_2"
          ]
      series = fillActivity req grouping ["new_count", "returning_count", "resurrecting_count", "dormant_count"] aggregate
      sql = "SELECT bucket," <> extendGroups ["measure.2"] <> " AS group_key,sort_group_1,sort_group_2,measure.1 AS sort_measure,toFloat64(measure.3) AS value FROM (" <> series <> ") ARRAY JOIN [(1,'new',new_count),(2,'returning',returning_count),(3,'resurrecting',resurrecting_count),(4,'dormant',dormant_count)] AS measure"
  pure CompiledMetric {sql, groupLabels = map dimensionLabel grouping <> ["status"], filterParameters = Filters.parameters filters, ordering = BucketDimensionsMeasure}

buildRetentionSQL :: QueryRequest -> [Int] -> Either QueryCompileError Text
buildRetentionSQL = buildRetentionMetricSQL defaultRegistry RetentionOn WindowCohort

buildRetentionMetricSQL :: EventRegistry -> RetentionMode -> CohortMode -> QueryRequest -> [Int] -> Either QueryCompileError Text
buildRetentionMetricSQL registry mode cohort req offsets = boundedCompiled (compileRetention registry mode cohort req offsets)

compileRetention :: EventRegistry -> RetentionMode -> CohortMode -> QueryRequest -> [Int] -> Either QueryCompileError CompiledMetric
compileRetention registry mode cohort req offsets = do
  first (QueryCompileFilterError . Text.pack . show) (dailyGrain req)
  void (first (QueryCompileFilterError . Text.pack . show) (validateOffsets offsets))
  let scope = if cohort == LifetimeCohort then historicalScope req else req
  (grouping, filters, population) <- activityPopulation registry req scope
  let normalized = normalizeOffsets offsets
      horizon = maximum normalized
      maturity = case mode of
        RetentionOn -> "addDays(f.cohort_day,f.offset+1)<=toDate(" <> sqlString (renderDay (req ^. #to)) <> ")"
        RetentionOnOrAfter -> "addDays(f.cohort_day," <> Text.pack (show (horizon + 1)) <> ")<=toDate(" <> sqlString (renderDay (req ^. #to)) <> ")"
      returned = case mode of
        RetentionOn -> "a.active_day=addDays(f.cohort_day,f.offset)"
        RetentionOnOrAfter -> "a.active_day>=addDays(f.cohort_day,f.offset) AND a.active_day<=addDays(f.cohort_day," <> Text.pack (show horizon) <> ")"
      sql =
        Text.unlines
          [ "WITH population AS (" <> population <> "),first_seen AS (",
            "SELECT canonical_user,group_key,sort_group_1,sort_group_2,min(active_day) AS cohort_day FROM population GROUP BY canonical_user,group_key,sort_group_1,sort_group_2",
            "HAVING cohort_day>=toDate(" <> sqlString (renderDay (req ^. #from)) <> ") AND cohort_day<toDate(" <> sqlString (renderDay (req ^. #to)) <> ")),",
            "cohort_offsets AS (SELECT *,arrayJoin([" <> Text.intercalate "," (map (Text.pack . show) normalized) <> "]) AS offset FROM first_seen),",
            "activity AS (SELECT canonical_user,group_key,active_day FROM population WHERE active_day>=toDate(" <> sqlString (renderDay (req ^. #from)) <> "))",
            "SELECT f.cohort_day AS sort_cohort,f.offset AS sort_offset,f.sort_group_1 AS sort_group_1,f.sort_group_2 AS sort_group_2,'' AS bucket,",
            "toJSONString(arrayConcat(JSONExtract(f.group_key,'Array(Nullable(String))'),[toString(f.cohort_day),toString(f.offset)])) AS group_key,",
            "toFloat64(uniqExactIf(f.canonical_user,f.offset=0 OR (a.canonical_user!='' AND " <> returned <> "))) AS value",
            "FROM cohort_offsets AS f LEFT JOIN activity AS a ON a.canonical_user=f.canonical_user AND a.group_key=f.group_key",
            "WHERE f.offset=0 OR " <> maturity,
            "GROUP BY f.cohort_day,f.offset,f.group_key,f.sort_group_1,f.sort_group_2"
          ]
  pure CompiledMetric {sql, groupLabels = map dimensionLabel grouping <> ["cohort", "offset"], filterParameters = Filters.parameters filters, ordering = RetentionDimensionsOrder}

-- | Both public routes use the same millisecond/id-ordered selected chain.
buildFunnelSQL :: QueryRequest -> Int -> [SqlName] -> Text
buildFunnelSQL req window steps = boundedSQL FunnelDimensionsOrder (funnelAggregate req Nothing defaultFunnelOptions window steps [] [])

buildFunnelMetricSQL :: EventRegistry -> QueryRequest -> Maybe SqlName -> FunnelOptions -> Int -> [SqlName] -> Either QueryCompileError Text
buildFunnelMetricSQL registry req experiment options window steps = boundedSQL FunnelDimensionsOrder . view #sql <$> compileFunnel registry req experiment options {exclusions = List.nub (options ^. #exclusions)} window steps

funnelPrefix :: Maybe SqlName -> Text
funnelPrefix Nothing = "funnel_step"
funnelPrefix Just {} = "experiment_funnel_step"

compileFunnel :: EventRegistry -> QueryRequest -> Maybe SqlName -> FunnelOptions -> Int -> [SqlName] -> Either QueryCompileError CompiledMetric
compileFunnel registry req experiment options window steps = do
  unless (isNothing (req ^. #timeGrain)) (Left (QueryCompileFilterError "timeGrain is unsupported for funnels"))
  when (options ^. #mode == FunnelStrict && any (\f -> not (Text.isPrefixOf "user:" (WireFilter.dimension f) || WireFilter.dimension f == "cohort")) (req ^. #filters)) (Left (QueryCompileFilterError "strict funnels do not support event filters; interruptions must remain visible"))
  case attributionLimits steps (options ^. #attribution) of
    Left (QueryLimitError _ detail) -> Left (QueryCompileFilterError detail)
    Right () -> pure ()
  let scope = map (EventName . renderSqlName) steps
      firstScope = take 1 scope
      property name = case options ^. #attribution of
        FunnelStep n -> resolveProperty registry (take 1 (drop (n - 1) scope)) name
        FunnelLastTouch -> resolveOptionalProperty registry scope name
        FunnelFirstTouch | options ^. #mode == FunnelAnyOrder -> resolveOptionalProperty registry scope name
        FunnelFirstTouch -> case resolveProperty registry firstScope name of
          Left PropertyErrorUndeclared {} -> resolveOptionalProperty registry scope name
          result -> result
      resolve name = case Text.stripPrefix "prop:" name of
        Just key -> first InvalidDimensionProperty (GroupByProperty <$> property key)
        Nothing -> cohortDimension req "canonical_user" (resolveDimension registry firstScope) name
  grouping <- requestedGroupingWith resolve (req ^. #groupBy) []
  filters <- first QueryCompileFilterError (requestFilters req "metric_filter" registry (map (EventName . renderSqlName) steps) (req ^. #filters))
  pure
    CompiledMetric
      { sql = funnelAggregate req experiment options window steps grouping (Filters.predicates filters),
        groupLabels = map dimensionLabel grouping <> ["index", "step"] <> (if isJust experiment then ["variant", "experiment"] else []) <> ["measure" | options ^. #measure == FunnelTimeToConvert || options ^. #counting == FunnelTotals],
        filterParameters = Filters.parameters filters,
        ordering = FunnelDimensionsOrder
      }

funnelAggregate :: QueryRequest -> Maybe SqlName -> FunnelOptions -> Int -> [SqlName] -> [GroupDimension] -> [Text] -> Text
funnelAggregate req experiment options window steps grouping predicates =
  let prefix = funnelPrefix experiment
      stepArray = "[" <> Text.intercalate "," [parameterPlaceholder prefix i | i <- [1 .. length steps]] <> "]"
      excludeArray = if null (options ^. #exclusions) then "CAST([], 'Array(String)')" else "[" <> Text.intercalate "," [parameterPlaceholder "funnel_exclude" i | i <- [1 .. length (options ^. #exclusions)]] <> "]"
      stepTuples = "[" <> Text.intercalate "," ["(" <> Text.pack (show i) <> "," <> parameterPlaceholder prefix i <> ")" | i <- [1 .. length steps]] <> "]"
      eligible = if null predicates then "1" else "(" <> Text.intercalate " AND " predicates <> ")"
      selection = if options ^. #mode == FunnelStrict then eligible else "(has(steps,event_name) AND " <> eligible <> ") OR has(excluded,event_name)"
      source = "SELECT *," <> groupProjection grouping <> " FROM " <> resolvedSource req <> " WHERE " <> accountPredicate <> " AND canonical_user!='' AND " <> timestampPredicate req
      exposure = "exposures AS (SELECT canonical_user,CAST(toString(getSubcolumn(properties_json,'variant')),'String') AS variant,min(occurred_at) AS first_exposure FROM base WHERE " <> validExposurePredicate <> " AND CAST(toString(getSubcolumn(properties_json,'experiment')),'String')={experiment:String} GROUP BY canonical_user,variant),"
      timelineSource = case experiment of
        Nothing -> "SELECT *,CAST(NULL,'Nullable(String)') AS variant FROM base WHERE " <> selection
        Just _ -> "SELECT b.*,e.variant AS variant FROM base AS b INNER JOIN exposures AS e ON b.canonical_user=e.canonical_user WHERE b.occurred_at>=e.first_exposure AND (" <> selection <> ")"
      timeline = "timelines AS (SELECT canonical_user,variant," <> Funnel.sortedTimelineSQL "groupArray(tuple(toInt64(toUnixTimestamp64Milli(occurred_at)),event_id,toString(event_name),sort_group_1,sort_group_2,group_key))" <> " AS timeline FROM (" <> timelineSource <> ") GROUP BY canonical_user,variant),"
      extended = options ^. #mode == FunnelAnyOrder || options ^. #counting == FunnelTotals
      firstIndex = if options ^. #mode == FunnelAnyOrder then "arrayFirstIndex(event->has(steps,event.3),timeline)" else "arrayFirstIndex(event->event.3=steps[1],timeline)"
      selected =
        if extended
          then "arrayJoin(" <> Funnel.entryChainsSQL "timeline" "steps" "excluded" (Text.pack (show (toInteger window * 1000))) (options ^. #mode == FunnelStrict) (options ^. #mode == FunnelAnyOrder) (options ^. #counting == FunnelTotals) <> ")"
          else Funnel.selectedChainSQL "timeline" "steps" "excluded" (Text.pack (show (toInteger window * 1000))) (if options ^. #mode == FunnelStrict then "1" else "0")
      owner = if options ^. #counting == FunnelTotals then "selected[1]" else firstIndex
      touch = case options ^. #attribution of
        FunnelFirstTouch -> owner
        FunnelLastTouch -> "arrayElement(selected,-1)"
        FunnelStep n
          | options ^. #mode == FunnelAnyOrder ->
              -- Assign each occurrence of a repeated name to its next unused position.
              let pos = Text.pack (show n)
               in "arrayElement(arrayFilter(i->timeline[i].3=steps[" <> pos <> "],selected),arrayCount(p->steps[p]=steps[" <> pos <> "],arraySlice(arrayEnumerate(steps),1," <> pos <> ")))"
        FunnelStep n -> "selected[" <> Text.pack (show n) <> "]"
      groupField i dimension =
        let eventIndex = if isPropertyDimension dimension then touch else owner
            field = "timeline[" <> eventIndex <> "]." <> Text.pack (show (i + 3 :: Int))
         in if isPropertyDimension dimension && dimensionType dimension == ScalarString then "coalesce(" <> field <> ",'other')" else field
      fields = [groupField i dimension | (i, dimension) <- zip [1 ..] grouping]
      label i dimension =
        let value = "toString(sort_group_" <> Text.pack (show (i :: Int)) <> ")"
         in if isPropertyDimension dimension then "coalesce(" <> value <> ",'other')" else value
      projection =
        "toJSONString(["
          <> Text.intercalate "," [label i dimension | (i, dimension) <- zip [1 ..] grouping]
          <> "]) AS group_key,"
          <> Text.intercalate "," [(if i <= length fields then fields !! (i - 1) else "CAST(NULL,'Nullable(String)')") <> " AS sort_group_" <> Text.pack (show i) | i <- [1, 2 :: Int]]
      selectedCTE = "matched AS (SELECT *," <> selected <> " AS selected FROM timelines WHERE " <> firstIndex <> ">0),chosen AS (SELECT *," <> projection <> " FROM matched)"
      withClause = "WITH " <> stepArray <> " AS steps," <> excludeArray <> " AS excluded,base AS (" <> source <> ")," <> (if isJust experiment then exposure else "") <> timeline <> selectedCTE
      variantFields = if isJust experiment then ["sort_variant", "{experiment:String}"] else []
      metadata extra = extendGroups (["toString(step.1)", "step.2"] <> variantFields <> extra)
      grouped = not (null grouping) || isJust experiment
      groupCols = "group_key,sort_group_1,sort_group_2,variant"
      countAggregate = "SELECT " <> (if grouped then groupCols <> "," else "'[]' AS group_key,CAST(NULL,'Nullable(String)') AS sort_group_1,CAST(NULL,'Nullable(String)') AS sort_group_2,CAST(NULL,'Nullable(String)') AS variant,") <> "groupArray(length(selected)) AS levels FROM chosen" <> (if grouped then " GROUP BY " <> groupCols else "")
      countSQL = "SELECT '' AS bucket," <> metadata ["'count'" | options ^. #counting == FunnelTotals] <> " AS group_key,sort_group_1,sort_group_2,variant AS sort_variant,step.1 AS sort_step,'' AS sort_measure,toFloat64(arrayCount(level->level>=step.1,levels)) AS value FROM (" <> countAggregate <> ") ARRAY JOIN " <> stepTuples <> " AS step"
      durations = "SELECT " <> groupCols <> ",step,arraySort(groupArrayIf(toFloat64(timeline[selected[step.1]].1-timeline[selected[1]].1)/1000,length(selected)>=step.1)) AS durations FROM chosen ARRAY JOIN " <> stepTuples <> " AS step WHERE step.1>=2 GROUP BY " <> groupCols <> ",step HAVING notEmpty(durations)"
      timeSQL = "SELECT '' AS bucket," <> metadata ["quantile.1"] <> " AS group_key,sort_group_1,sort_group_2,variant AS sort_variant,step.1 AS sort_step,quantile.1 AS sort_measure,durations[toUInt64(ceil(quantile.2*length(durations)))] AS value FROM (" <> durations <> ") ARRAY JOIN [('p50_seconds',0.5),('p90_seconds',0.9)] AS quantile"
      entryVariant = if isJust experiment then "variant" else "CAST(NULL,'Nullable(String)')"
      entryGroups = replicate (length grouping + 2) "CAST(NULL,'Nullable(String)')" <> (if isJust experiment then ["variant", "{experiment:String}"] else []) <> ["'entries'"]
      entriesSQL = "SELECT '' AS bucket,toJSONString([" <> Text.intercalate "," entryGroups <> "]) AS group_key,NULL AS sort_group_1,NULL AS sort_group_2," <> entryVariant <> " AS sort_variant,toUInt64(0) AS sort_step,'entries' AS sort_measure,toFloat64(count()) AS value FROM chosen" <> (if isJust experiment then " GROUP BY variant" else "")
   in withClause <> " " <> (if options ^. #measure == FunnelCount then countSQL else timeSQL) <> (if options ^. #counting == FunnelTotals then " UNION ALL " <> entriesSQL else "")

validExposurePredicate :: Text
validExposurePredicate = "event_name='experiment_viewed' AND match(CAST(toString(getSubcolumn(properties_json,'experiment')),'String'),'^[a-z0-9_.:-]{1,128}$') AND match(CAST(toString(getSubcolumn(properties_json,'variant')),'String'),'^[a-z0-9_.:-]{1,128}$')"

-- | Exposure sketches are daily, but merging them across days computes a set
-- union. With no grain, a user exposed on several days therefore still counts
-- once for the whole requested range.
buildExperimentExposuresSQL :: QueryRequest -> Maybe SqlName -> Text
buildExperimentExposuresSQL req experiment = boundedSQL ExperimentExposureOrder (buildExperimentExposuresSQLAggregate req experiment)

buildExperimentExposuresSQLAggregate :: QueryRequest -> Maybe SqlName -> Text
buildExperimentExposuresSQLAggregate req experiment =
  Text.unlines
    [ "SELECT",
      "    " <> experimentBucketExpr (req ^. #timeGrain) <> " AS bucket,",
      "    toJSONString([experiment, variant]) AS group_key,",
      "    experiment AS sort_experiment, variant AS sort_variant,",
      "    toFloat64(uniqCombinedMerge(users)) AS value",
      "FROM analytics.experiment_exposures",
      "WHERE " <> accountPredicate,
      "  AND day >= " <> sqlString (renderDay (req ^. #from)) <> " AND day < " <> sqlString (renderDay (req ^. #to)),
      "  AND match(experiment, '^[a-z0-9_.:-]{1,128}$')",
      "  AND match(variant, '^[a-z0-9_.:-]{1,128}$')" <> experimentFilterClause experiment,
      experimentGroupBy (req ^. #timeGrain),
      "ORDER BY bucket, group_key"
    ]

-- | Exact identity-stitched conversion by variant. A conversion counts only
-- when the user's latest conversion is at or after their first exposure for
-- that variant. With ClickHouse's default join_use_nulls = 0, a LEFT JOIN miss
-- supplies the zero DateTime64, which correctly fails that comparison.
buildExperimentConversionSQL :: QueryRequest -> SqlName -> SqlName -> Text
buildExperimentConversionSQL req experiment conversionEvent = boundedSQL ExperimentConversionOrder (buildExperimentConversionSQLAggregate req experiment conversionEvent)

buildExperimentConversionSQLAggregate :: QueryRequest -> SqlName -> SqlName -> Text
buildExperimentConversionSQLAggregate req _experiment _conversionEvent =
  Text.unlines
    [ "WITH exposures AS",
      "(",
      "    SELECT",
      "        canonical_user,",
      "        CAST(toString(getSubcolumn(properties_json, 'variant')), 'String') AS variant,",
      "        min(occurred_at) AS first_exposure",
      "    FROM " <> resolvedSource req,
      "    WHERE canonical_user != ''",
      "      AND " <> accountPredicate,
      "      AND event_name = 'experiment_viewed'",
      "      AND CAST(toString(getSubcolumn(properties_json, 'experiment')), 'String') = {experiment:String}",
      "      AND match(CAST(toString(getSubcolumn(properties_json, 'experiment')), 'String'), '^[a-z0-9_.:-]{1,128}$')",
      "      AND match(CAST(toString(getSubcolumn(properties_json, 'variant')), 'String'), '^[a-z0-9_.:-]{1,128}$')",
      "      AND " <> timestampPredicate req,
      "    GROUP BY canonical_user, variant",
      "),",
      "conversions AS",
      "(",
      "    SELECT",
      "        canonical_user,",
      "        max(occurred_at) AS last_conversion",
      "    FROM " <> resolvedSource req,
      "    WHERE canonical_user != ''",
      "      AND " <> accountPredicate,
      "      AND event_name = {conversion_event:String}",
      "      AND " <> timestampPredicate req,
      "    GROUP BY canonical_user",
      ")",
      "SELECT",
      "    '' AS bucket,",
      "    toJSONString([m.1, variant]) AS group_key,",
      "    m.1 AS sort_measure, variant AS sort_variant,",
      "    m.2 AS value",
      "FROM",
      "(",
      "    SELECT",
      "        e.variant AS variant,",
      "        toFloat64(uniqExact(e.canonical_user)) AS exposed,",
      "        toFloat64(uniqExactIf(e.canonical_user, c.last_conversion >= e.first_exposure)) AS converted",
      "    FROM exposures AS e",
      "    LEFT JOIN conversions AS c ON c.canonical_user = e.canonical_user",
      "    GROUP BY variant",
      ")",
      "ARRAY JOIN",
      "    [('exposed', exposed),",
      "     ('converted', converted),",
      "     ('conversion_rate', if(exposed = 0, 0., converted / exposed))] AS m",
      "ORDER BY group_key"
    ]

experimentBucketExpr :: Maybe TimeGrain -> Text
experimentBucketExpr = \case
  Nothing -> "''"
  Just Day -> "toString(day)"
  Just Week -> "toString(toMonday(day))"
  Just Month -> "toString(toStartOfMonth(day))"
  -- The HTTP handler rejects Hour because the rollup has daily resolution.
  Just Hour -> "toString(day)"

experimentGroupBy :: Maybe TimeGrain -> Text
experimentGroupBy = \case
  Nothing -> "GROUP BY experiment, variant"
  Just Day -> "GROUP BY day, experiment, variant"
  Just Week -> "GROUP BY toMonday(day), experiment, variant"
  Just Month -> "GROUP BY toStartOfMonth(day), experiment, variant"
  Just Hour -> "GROUP BY day, experiment, variant"

experimentFilterClause :: Maybe SqlName -> Text
experimentFilterClause = \case
  Nothing -> ""
  Just _ -> "\n  AND experiment = {experiment:String}"

-- | Exposure gating precedes the shared chain evaluation.
buildExperimentFunnelSQL :: QueryRequest -> SqlName -> Int -> [SqlName] -> Text
buildExperimentFunnelSQL req experiment window steps = boundedSQL FunnelDimensionsOrder (funnelAggregate req (Just experiment) defaultFunnelOptions window steps [] [])

effectiveGrain :: MetricDefinition -> QueryRequest -> Maybe TimeGrain
effectiveGrain MetricDefinition {timeGrain = defaultGrain} QueryRequest {timeGrain = requestedGrain} =
  requestedGrain <|> defaultGrain <|> Just Day

bucketExpr :: Maybe TimeGrain -> Text
bucketExpr = \case
  Just Hour -> "toString(toStartOfHour(occurred_at))"
  Just Week -> "toString(toMonday(occurred_at))"
  Just Month -> "toString(toStartOfMonth(occurred_at))"
  _ -> "toString(toDate(occurred_at))"

requestedGroupingWith :: (Text -> Either DimensionError GroupDimension) -> Maybe [Text] -> [Text] -> Either QueryCompileError [GroupDimension]
requestedGroupingWith resolve requested defaults = do
  let names = fromMaybe defaults requested
  when (length names > 2 || length (List.nub names) /= length names || any Text.null names || requested == Just []) (Left (QueryCompileMultipleGroupBy names))
  traverse (first dimensionFailure . resolve) names
  where
    dimensionFailure (UnknownDimension name) = QueryCompileInvalidGroupBy name
    dimensionFailure (InvalidDimensionProperty failure) = QueryCompilePropertyError failure

isPropertyDimension :: GroupDimension -> Bool
isPropertyDimension GroupByProperty {} = True
isPropertyDimension _ = False

definitionEvents :: MetricDefinition -> [EventName]
definitionEvents def = EventName <$> def ^. #eventNames

propertyFilterClause :: [Text] -> Text
propertyFilterClause = foldMap ("\n  AND " <>)

queryCompileErrorCode :: QueryCompileError -> Text
queryCompileErrorCode = \case
  QueryCompilePropertyError PropertyErrorUndeclared {} -> "unknown_property"
  QueryCompilePropertyError {} -> "invalid_property"
  QueryCompileInvalidGroupBy {} -> "invalid_group_by"
  QueryCompileMultipleGroupBy {} -> "invalid_group_by"
  QueryCompileMissingAggregationProperty {} -> "invalid_metric_definition"
  QueryCompileUnsupportedPropertyGrouping {} -> "invalid_group_by"
  QueryCompileFilterError {} -> "invalid_filter"

queryCompileErrorMessage :: QueryCompileError -> Text
queryCompileErrorMessage = \case
  QueryCompilePropertyError (PropertyErrorBadName property) ->
    "invalid property name: " <> property
  QueryCompilePropertyError (PropertyErrorUnscopedMetric property) ->
    "property requires a metric with declared event names: " <> property
  QueryCompilePropertyError (PropertyErrorUndeclared property event) ->
    "unknown property " <> property <> " for event " <> unEventName event
  QueryCompilePropertyError (PropertyErrorNotNumeric property event) ->
    "property is not numeric: " <> unEventName event <> "." <> property
  QueryCompilePropertyError (PropertyErrorNotScalar property event) ->
    "property requires a declared scalar type: " <> unEventName event <> "." <> property
  QueryCompilePropertyError (PropertyErrorIncompatibleTypes property) ->
    "property declarations have incompatible scalar types: " <> property
  QueryCompileInvalidGroupBy value ->
    "invalid groupBy value: " <> value
  QueryCompileMultipleGroupBy values ->
    "groupBy requires one or two distinct nonempty dimensions; received: " <> Text.intercalate "," values
  QueryCompileMissingAggregationProperty metric ->
    "metric is missing aggregationProperty: " <> metric
  QueryCompileUnsupportedPropertyGrouping metric ->
    "property grouping is not supported for ratio metric: " <> metric
  QueryCompileFilterError message -> message

timestampPredicate :: QueryRequest -> Text
timestampPredicate req =
  "occurred_at >= "
    <> sqlString (renderDay (req ^. #from) <> " 00:00:00")
    <> " AND occurred_at < "
    <> sqlString (renderDay (req ^. #to) <> " 00:00:00")

eventNameClause :: Text -> [SqlName] -> Text
eventNameClause _prefix [] = ""
eventNameClause prefix names = "\n  AND " <> eventNamePredicate prefix names

eventNamePredicate :: Text -> [SqlName] -> Text
eventNamePredicate _prefix [] = "1 = 1"
eventNamePredicate prefix names =
  "event_name IN ("
    <> Text.intercalate ", " (parameterPlaceholder prefix <$> [1 .. length names])
    <> ")"

parameterPlaceholder :: Text -> Int -> Text
parameterPlaceholder prefix position =
  "{" <> parameterName prefix position <> ":String}"

parameterName :: Text -> Int -> Text
parameterName prefix position = prefix <> "_" <> Text.pack (show position)

namedParameters :: Text -> [SqlName] -> [QueryParameter]
namedParameters prefix =
  zipWith (\position value -> (Text.unpack (parameterName prefix position), renderSqlName value)) [1 :: Int ..]

accountParameter :: QueryRequest -> [QueryParameter]
accountParameter req = [("account_id", unAccountId (req ^. #accountId)), ("identity_from", renderDay (minimum (req ^. #from : map (Cohort.since . snd) (cohorts req)))), ("identity_to", renderDay (req ^. #to))] <> concatMap (Cohort.parameters . snd) (cohorts req)

experimentParameter :: SqlName -> QueryParameter
experimentParameter experiment = ("experiment", renderSqlName experiment)

conversionEventParameter :: SqlName -> QueryParameter
conversionEventParameter conversionEvent = ("conversion_event", renderSqlName conversionEvent)

accountPredicate :: Text
accountPredicate = "account_id = {account_id:String}"

metricParameters :: BuiltinMetric -> QueryRequest -> [QueryParameter]
metricParameters metric req =
  case metric of
    Simple def -> simpleMetricParameters def req
    Ratioed RatioMetric {numerator, denominator} ->
      namedParameters "numerator_event_name" (validatedEventNames numerator)
        <> namedParameters "denominator_event_name" (validatedEventNames denominator)

simpleMetricParameters :: MetricDefinition -> QueryRequest -> [QueryParameter]
simpleMetricParameters def _req = namedParameters "event_name" (validatedEventNames def)

validatedEventNames :: MetricDefinition -> [SqlName]
validatedEventNames MetricDefinition {name, eventNames} =
  case traverse mkSqlName eventNames of
    Right names -> names
    Left invalid ->
      error
        ( "invalid built-in event name for metric "
            <> Text.unpack name
            <> ": "
            <> Text.unpack invalid
        )

sqlString :: Text -> Text
sqlString value =
  "'" <> Text.replace "\\" "\\\\" (Text.replace "'" "\\'" value) <> "'"

renderDay :: Day -> Text
renderDay = Text.pack . formatTime defaultTimeLocale "%F"

-- | Always include offset 0 so every cohort has its denominator row, discard
-- negative offsets, and avoid duplicate result groups.
normalizeOffsets :: [Int] -> [Int]
normalizeOffsets offsets =
  0 : List.sort (List.nub offsets)

metricName :: BuiltinMetric -> Text
metricName = \case
  Simple MetricDefinition {name} -> name
  Ratioed RatioMetric {name} -> name

-- Cohort definitions are loaded by the authenticated handler, then compiled
-- once with the original to bound before history/session scopes are widened.
cohortDimension :: QueryRequest -> Text -> (Text -> Either DimensionError GroupDimension) -> Text -> Either DimensionError GroupDimension
cohortDimension req subject fallback label = case Text.stripPrefix "cohort:" label of
  Nothing -> fallback label
  Just ident -> case lookup ident (cohorts req) of
    Nothing -> Left (UnknownDimension label)
    Just membership -> Right (GroupByCohort ident (if subject == "canonical_user" then Cohort.predicate membership else replaceSubject (Cohort.predicate membership)))
  where
    -- Only outer references change. Membership subqueries keep their own
    -- canonical_user columns and are shared by event and session metrics.
    replaceSubject = Text.replace "startsWith(canonical_user,'user:')" "startsWith(primary_subject,'user:')" . Text.replace "canonical_user IN (SELECT" "primary_subject IN (SELECT" . Text.replace "canonical_user NOT IN (SELECT" "primary_subject NOT IN (SELECT"

requestGrouping :: QueryRequest -> EventRegistry -> [EventName] -> Maybe [Text] -> [Text] -> Either QueryCompileError [GroupDimension]
requestGrouping req registry scope = requestedGroupingWith (cohortDimension req "canonical_user" (resolveDimension registry scope))

requestFilters :: QueryRequest -> String -> EventRegistry -> [EventName] -> [MetricFilter] -> Either Text Filters.CompiledFilters
requestFilters req prefix registry scope = Filters.compileFiltersWith prefix (cohortDimension req "canonical_user" (resolveDimension registry scope)) . normalizeCohortFilters

normalizeCohortFilters :: [MetricFilter] -> [MetricFilter]
normalizeCohortFilters = map normalize
  where
    normalize input
      | WireFilter.dimension input == "cohort",
        Just (Aeson.String ident) <- WireFilter.value input,
        WireFilter.op input `elem` [WireFilter.FilterEq, WireFilter.FilterNeq] =
          either (const input) id (WireFilter.mkMetricFilter ("cohort:" <> ident) (WireFilter.op input) (Just (Aeson.String "in")))
    normalize input = input
