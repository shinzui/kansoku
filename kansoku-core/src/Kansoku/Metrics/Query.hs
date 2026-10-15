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
    buildFunnelSQL,
    buildRetentionSQL,
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
    runRetention,
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
import Data.Generics.Labels ()
import Data.List qualified as List
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time (Day, addDays, dayOfWeek, diffDays, fromGregorian, toGregorian)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Effectful (Eff, IOE, type (:>))
import Kansoku.ClickHouse (QueryPool, queryDeadlineMicros, withIdentityQueryConnection, withMetricsQueryConnection)
import Kansoku.Event
  ( AccountId (..),
    EventName (..),
    EventRegistry,
    defaultRegistry,
  )
import Kansoku.Exception (trySynchronous)
import Kansoku.Metrics.Api (AcquisitionMeasure (..), MetricPoint (..), MetricResult (..), SessionMeasure (..), TimeGrain (..))
import Kansoku.Metrics.Definition (Aggregation (..), MetricDefinition (..), RatioMetric (..))
import Kansoku.Metrics.Filter (MetricFilter)
import Kansoku.Metrics.Filter qualified as WireFilter
import Kansoku.Metrics.Limits (maxMetricPoints, maxQueryDays)
import Kansoku.Metrics.Query.Dimension
import Kansoku.Metrics.Query.Filter qualified as Filters
import Kansoku.Metrics.Query.Property
  ( PropertyError (..),
    PropertyName,
    propertyFloatExpr,
    resolveNumericProperty,
  )
import Kansoku.Metrics.Query.Session (materializedSessionProjection, sessionProjection)
import Kansoku.Metrics.Query.Validate (QueryLimitError (..), SqlName, mkSqlName, renderSqlName, validateDateRange, validateOffsets, validateSteps)
import Kansoku.Metrics.Registry (BuiltinMetric (..))
import Kansoku.Prelude
import System.Timeout (timeout)

data QueryRequest = QueryRequest
  { accountId :: !AccountId,
    from :: !Day,
    to :: !Day,
    groupBy :: !(Maybe [Text]),
    timeGrain :: !(Maybe TimeGrain),
    filters :: ![MetricFilter],
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
  = QueryCompileFailure !QueryCompileError
  | QueryLimitFailure !QueryLimitError
  | MetricResultTooLarge
  | QueryStorageFailure !Text
  | QueryResourceLimit
  deriving stock (Generic, Eq, Show)

-- No caller-supplied SQL may select a result ordering.
data ResultOrder = BucketDimensions | BucketGroup | ExperimentExposureOrder | ExperimentConversionOrder | RetentionOrder | FunnelOrder | ExperimentFunnelOrder
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
  grouping <- requestedGroupingWith (resolveSessionDimension registry scope) (req ^. #groupBy) ["channel"]
  filters <- first QueryCompileFilterError (Filters.compileFiltersWith "metric_filter" (resolveSessionDimension registry scope) (req ^. #filters))
  let resolved = measure == AcquisitionUsers
      source = if resolved then resolvedSource (retainedScope req) else "analytics.events_canonical"
      aggregate = if resolved then "uniqExactIf(primary_subject,primary_subject!='')" else "count()"
      predicates = [timestampPredicate req] <> ["NOT is_bot" | not (req ^. #includeBots)] <> Filters.predicates filters
      sql =
        Text.unlines
          [ "SELECT " <> bucketExpr (req ^. #timeGrain) <> " AS bucket," <> groupProjection grouping <> ",toFloat64(" <> aggregate <> ") AS value",
            "FROM (" <> (if resolved || any isPropertyDimension grouping || any (Text.isPrefixOf "prop:" . WireFilter.dimension) (req ^. #filters) then sessionProjection source resolved else materializedSessionProjection) <> ")",
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
          (accountParameter req <> compiled ^. #filterParameters)
          (boundedSQL BucketDimensions (compiled ^. #sql))

runRetention :: (IOE :> es) => QueryPool -> QueryRequest -> [Int] -> Eff es (Either QueryExecutionError MetricResult)
runRetention pool req offsets =
  case validateOffsets offsets of
    Left err -> pure (Left (QueryLimitFailure err))
    Right normalized ->
      checked req (Right ()) $
        runSQLWith pool "retention" retentionPoint (accountParameter req) (buildRetentionSQL req normalized)

runFunnel :: (IOE :> es) => QueryPool -> QueryRequest -> Int -> [SqlName] -> Eff es (Either QueryExecutionError MetricResult)
runFunnel pool req window steps =
  checked req (funnelLimits window steps) $
    runSQLWith
      pool
      "funnel"
      funnelPoint
      (accountParameter req <> namedParameters "funnel_step" steps)
      (buildFunnelSQL req window steps)

runExperimentExposures :: (IOE :> es) => QueryPool -> QueryRequest -> Maybe SqlName -> Eff es (Either QueryExecutionError MetricResult)
runExperimentExposures pool req experiment =
  checked req (Right ()) $
    runSQLWith
      pool
      "experiment_exposures"
      experimentExposuresAggPoint
      (accountParameter req <> maybe [] (pure . experimentParameter) experiment)
      (buildExperimentExposuresSQL req experiment)

runExperimentConversion :: (IOE :> es) => QueryPool -> QueryRequest -> SqlName -> SqlName -> Eff es (Either QueryExecutionError MetricResult)
runExperimentConversion pool req experiment conversionEvent =
  checked req (Right ()) $
    runSQLWith
      pool
      "experiment_conversion"
      (experimentConversionAggPoint experiment)
      (accountParameter req <> [experimentParameter experiment, conversionEventParameter conversionEvent])
      (buildExperimentConversionSQL req experiment conversionEvent)

runExperimentFunnel :: (IOE :> es) => QueryPool -> QueryRequest -> SqlName -> Int -> [SqlName] -> Eff es (Either QueryExecutionError MetricResult)
runExperimentFunnel pool req experiment window steps =
  checked req (funnelLimits window steps) $
    runSQLWith
      pool
      "experiment_funnel"
      (experimentFunnelAggPoint experiment)
      (accountParameter req <> [experimentParameter experiment] <> namedParameters "experiment_funnel_step" steps)
      (buildExperimentFunnelSQL req experiment window steps)

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
        BucketDimensions -> "bucket, sort_group_1 NULLS FIRST, sort_group_2 NULLS FIRST"
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

retentionPoint :: AggRow -> Either Text MetricPoint
retentionPoint row@AggRow {bucket} = do
  point <- defaultPoint ["offset"] row
  cohort <- decodeUtf8 bucket
  pure (point & #bucket .~ Nothing & #group %~ Map.insert "cohort" (Just cohort))

funnelPoint :: AggRow -> Either Text MetricPoint
funnelPoint = defaultPoint ["index", "step"]

experimentExposuresAggPoint :: AggRow -> Either Text MetricPoint
experimentExposuresAggPoint = defaultPoint ["experiment", "variant"]

experimentConversionAggPoint :: SqlName -> AggRow -> Either Text MetricPoint
experimentConversionAggPoint experiment row = do
  point <- defaultPoint ["measure", "variant"] row
  pure (point & #group %~ Map.insert "experiment" (Just (renderSqlName experiment)))

experimentFunnelAggPoint :: SqlName -> AggRow -> Either Text MetricPoint
experimentFunnelAggPoint experiment row = do
  point <- defaultPoint ["index", "step", "variant"] row
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
  Ratioed ratio -> do
    let scope = Filters.filteredEventScope (definitionEvents (ratio ^. #numerator) <> definitionEvents (ratio ^. #denominator)) (req ^. #filters)
    when (any (Text.isPrefixOf "prop:") (fromMaybe [] (req ^. #groupBy))) (Left (QueryCompileUnsupportedPropertyGrouping (ratio ^. #name)))
    grouping <- requestedGrouping registry scope (req ^. #groupBy) []
    when (any isPropertyDimension grouping) (Left (QueryCompileUnsupportedPropertyGrouping (ratio ^. #name)))
    common <- first QueryCompileFilterError (Filters.compileMetricFilters registry scope (req ^. #filters))
    numeratorInputs <- definitionFilters (ratio ^. #numerator)
    denominatorInputs <- definitionFilters (ratio ^. #denominator)
    numeratorFilters <- first QueryCompileFilterError (Filters.compileMetricFiltersWithPrefix "numerator_filter" registry (definitionEvents (ratio ^. #numerator)) numeratorInputs)
    denominatorFilters <- first QueryCompileFilterError (Filters.compileMetricFiltersWithPrefix "denominator_filter" registry (definitionEvents (ratio ^. #denominator)) denominatorInputs)
    pure CompiledMetric {sql = buildRatioSQL ratio grouping (Filters.predicates common) (Filters.predicates numeratorFilters) (Filters.predicates denominatorFilters) req, groupLabels = map dimensionLabel grouping, filterParameters = Filters.parameters common <> Filters.parameters numeratorFilters <> Filters.parameters denominatorFilters, ordering = BucketDimensions}

compileSimpleMetric :: EventRegistry -> MetricDefinition -> QueryRequest -> Either QueryCompileError CompiledMetric
compileSimpleMetric registry def req = do
  defaults <- definitionFilters def
  let inputs = defaults <> req ^. #filters
      scope = Filters.filteredEventScope (definitionEvents def) (req ^. #filters)
  grouping <- requestedGrouping registry scope (req ^. #groupBy) (map ("prop:" <>) (def ^. #groupBy))
  compiled <- first QueryCompileFilterError (Filters.compileMetricFilters registry scope inputs)
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
resolvedSource :: QueryRequest -> Text
resolvedSource req =
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
      "FROM " <> source,
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
  grouping <- requestedGroupingWith (resolveSessionDimension defaultRegistry []) (req ^. #groupBy) []
  predicates <- first QueryCompileFilterError (Filters.compileFiltersWith "session_filter" (resolveSessionDimension defaultRegistry []) (req ^. #filters))
  let selected =
        "SELECT * FROM ("
          <> materializedSessionProjection
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

-- | Retention over new-in-window cohorts. first_seen deliberately computes
-- min(day) inside the requested window; lifetime cohorts require a first-seen
-- rollup and are outside the MVP contract.
buildRetentionSQL :: QueryRequest -> [Int] -> Text
buildRetentionSQL req offsets = boundedSQL RetentionOrder (buildRetentionSQLAggregate req offsets)

buildRetentionSQLAggregate :: QueryRequest -> [Int] -> Text
buildRetentionSQLAggregate req offsets =
  Text.unlines
    [ "WITH",
      "  first_seen AS",
      "  (",
      "    SELECT canonical_user, min(toDate(occurred_at)) AS cohort_day",
      "    FROM " <> resolvedSource req,
      "    WHERE " <> accountPredicate,
      "      AND canonical_user != ''",
      "      AND " <> activityPredicate,
      "      AND " <> timestampPredicate req,
      "    GROUP BY canonical_user",
      "  ),",
      "  activity AS",
      "  (",
      "    SELECT DISTINCT canonical_user, toDate(occurred_at) AS active_day",
      "    FROM " <> resolvedSource req,
      "    WHERE " <> accountPredicate,
      "      AND canonical_user != ''",
      "      AND " <> activityPredicate,
      "      AND " <> timestampPredicate req,
      "  )",
      "SELECT",
      "    f.cohort_day AS sort_cohort, dateDiff('day', f.cohort_day, a.active_day) AS sort_offset,",
      "    toString(f.cohort_day) AS bucket,",
      "    toJSONString([toString(dateDiff('day', f.cohort_day, a.active_day))]) AS group_key,",
      "    toFloat64(uniqExact(f.canonical_user)) AS value",
      "FROM first_seen AS f",
      "INNER JOIN activity AS a ON a.canonical_user = f.canonical_user",
      "WHERE dateDiff('day', f.cohort_day, a.active_day) IN (" <> Text.intercalate "," (Text.pack . show <$> normalizeOffsets offsets) <> ")",
      "GROUP BY f.cohort_day, dateDiff('day', f.cohort_day, a.active_day)",
      "ORDER BY f.cohort_day, dateDiff('day', f.cohort_day, a.active_day)"
    ]

-- | One-pass ordered funnel over identity-resolved users. Converting
-- DateTime64 to DateTime is load-bearing: windowFunnel measures its window in
-- timestamp ticks, so the conversion makes the public window unit seconds.
-- Equal timestamps may satisfy consecutive steps; repeated step names mean
-- the user performed that event repeatedly in order.
buildFunnelSQL :: QueryRequest -> Int -> [SqlName] -> Text
buildFunnelSQL req window steps = boundedSQL FunnelOrder (buildFunnelSQLAggregate req window steps)

buildFunnelSQLAggregate :: QueryRequest -> Int -> [SqlName] -> Text
buildFunnelSQLAggregate req window steps =
  """
  SELECT
      '' AS bucket,
      step.1 AS sort_step,
      toJSONString([toString(step.1), step.2]) AS group_key,
      toFloat64(countIf(level >= step.1)) AS value
  FROM
  (
      SELECT
          canonical_user,
          windowFunnel(
  """
    <> Text.pack (show window)
    <> ")(toDateTime(occurred_at), "
    <> conditions
    <> ") AS level\nFROM "
    <> resolvedSource req
    <> "\nWHERE "
    <> accountPredicate
    <> """
       AND canonical_user != ''
       AND event_name IN (
       """
    <> placeholders
    <> ")\n      AND "
    <> timestampPredicate req
    <> """

           GROUP BY canonical_user
       )
       ARRAY JOIN [
       """
    <> stepTuples
    <> """
       ] AS step
       GROUP BY step
       ORDER BY step.1
       """
  where
    indexedSteps = zip [1 :: Int ..] steps
    placeholders =
      Text.intercalate
        ", "
        [parameterPlaceholder "funnel_step" position | (position, _step) <- indexedSteps]
    conditions =
      Text.intercalate
        ", "
        ["event_name = " <> parameterPlaceholder "funnel_step" position | (position, _step) <- indexedSteps]
    stepTuples =
      Text.intercalate
        ", "
        [ "(" <> Text.pack (show position) <> ", " <> parameterPlaceholder "funnel_step" position <> ")"
        | (position, _step) <- indexedSteps
        ]

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

-- | Ordered per-variant funnel restricted to each user's post-exposure event
-- timeline. DateTime64 is converted to DateTime so windowFunnel's public
-- window unit remains seconds, matching the plain funnel endpoint.
buildExperimentFunnelSQL :: QueryRequest -> SqlName -> Int -> [SqlName] -> Text
buildExperimentFunnelSQL req experiment window steps = boundedSQL ExperimentFunnelOrder (buildExperimentFunnelSQLAggregate req experiment window steps)

buildExperimentFunnelSQLAggregate :: QueryRequest -> SqlName -> Int -> [SqlName] -> Text
buildExperimentFunnelSQLAggregate req _experiment window steps =
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
      ")",
      "SELECT",
      "    '' AS bucket,",
      "    variant AS sort_variant, step.1 AS sort_step,",
      "    toJSONString([toString(step.1), step.2, variant]) AS group_key,",
      "    toFloat64(countIf(level >= step.1)) AS value",
      "FROM",
      "(",
      "    SELECT",
      "        e.variant AS variant,",
      "        r.canonical_user AS canonical_user,",
      "        windowFunnel(" <> Text.pack (show window) <> ")(toDateTime(r.occurred_at), " <> conditions <> ") AS level",
      "    FROM " <> resolvedSource req <> " AS r",
      "    INNER JOIN exposures AS e ON e.canonical_user = r.canonical_user",
      "    WHERE r.canonical_user != ''",
      "      AND r.account_id = {account_id:String}",
      "      AND r.event_name IN (" <> placeholders <> ")",
      "      AND r.occurred_at >= e.first_exposure",
      "      AND " <> qualifiedTimestampPredicate "r" req,
      "    GROUP BY e.variant, r.canonical_user",
      ")",
      "ARRAY JOIN [" <> stepTuples <> "] AS step",
      "GROUP BY variant, step",
      "ORDER BY variant, step.1"
    ]
  where
    indexedSteps = zip [1 :: Int ..] steps
    placeholders =
      Text.intercalate
        ", "
        [parameterPlaceholder "experiment_funnel_step" position | (position, _step) <- indexedSteps]
    conditions =
      Text.intercalate
        ", "
        ["r.event_name = " <> parameterPlaceholder "experiment_funnel_step" position | (position, _step) <- indexedSteps]
    stepTuples =
      Text.intercalate
        ", "
        [ "(" <> Text.pack (show position) <> ", " <> parameterPlaceholder "experiment_funnel_step" position <> ")"
        | (position, _step) <- indexedSteps
        ]

effectiveGrain :: MetricDefinition -> QueryRequest -> Maybe TimeGrain
effectiveGrain MetricDefinition {timeGrain = defaultGrain} QueryRequest {timeGrain = requestedGrain} =
  requestedGrain <|> defaultGrain <|> Just Day

bucketExpr :: Maybe TimeGrain -> Text
bucketExpr = \case
  Just Hour -> "toString(toStartOfHour(occurred_at))"
  Just Week -> "toString(toMonday(occurred_at))"
  Just Month -> "toString(toStartOfMonth(occurred_at))"
  _ -> "toString(toDate(occurred_at))"

requestedGrouping :: EventRegistry -> [EventName] -> Maybe [Text] -> [Text] -> Either QueryCompileError [GroupDimension]
requestedGrouping registry scope = requestedGroupingWith (resolveDimension registry scope)

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

qualifiedTimestampPredicate :: Text -> QueryRequest -> Text
qualifiedTimestampPredicate qualifier req =
  qualifier
    <> ".occurred_at >= "
    <> sqlString (renderDay (req ^. #from) <> " 00:00:00")
    <> " AND "
    <> qualifier
    <> ".occurred_at < "
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
accountParameter req = [("account_id", unAccountId (req ^. #accountId)), ("identity_from", renderDay (req ^. #from)), ("identity_to", renderDay (req ^. #to))]

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
