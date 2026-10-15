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
    buildSessionsSQL,
    experimentConversionPoint,
    experimentExposuresPoint,
    experimentFunnelPoint,
    queryCompileErrorCode,
    queryCompileErrorMessage,
    run,
    runExperimentConversion,
    runExperimentExposures,
    runExperimentFunnel,
    runFunnel,
    runRetention,
    runSessions,
  )
where

import ClickHaskell
  ( ChString,
    ClickHaskell,
    Column,
    Float64,
    Select,
    ToChType (toChType),
    addParameter,
    passParameters,
    select,
    unsafeMkSelect,
  )
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.List qualified as List
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time (Day)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Effectful (Eff, IOE, type (:>))
import Kansoku.ClickHouse (QueryPool, withQueryConnection)
import Kansoku.Event
  ( AccountId (..),
    EventName (..),
    EventRegistry,
  )
import Kansoku.Exception (trySynchronous)
import Kansoku.Metrics.Api (MetricPoint (..), MetricResult (..), TimeGrain (..))
import Kansoku.Metrics.Definition (Aggregation (..), MetricDefinition (..), RatioMetric (..))
import Kansoku.Metrics.Limits (maxMetricPoints)
import Kansoku.Metrics.Query.Property
  ( PropertyError (..),
    PropertyName,
    propertyEqualsPredicate,
    propertyFloatExpr,
    propertyGroupExpr,
    propertyNameText,
    resolveNumericProperty,
    resolveProperty,
  )
import Kansoku.Metrics.Query.Validate (QueryLimitError (..), SqlName, mkSqlName, renderSqlName, validateDateRange, validateOffsets, validateSteps)
import Kansoku.Metrics.Registry (BuiltinMetric (..))
import Kansoku.Prelude

data QueryRequest = QueryRequest
  { accountId :: !AccountId,
    from :: !Day,
    to :: !Day,
    groupBy :: !(Maybe [Text]),
    timeGrain :: !(Maybe TimeGrain)
  }
  deriving stock (Generic, Eq, Show)

data GroupDimension
  = GroupByEventName
  | GroupBySource
  | GroupByRoute
  | GroupByProperty !PropertyName
  deriving stock (Generic, Eq, Show)

data QueryCompileError
  = QueryCompilePropertyError !PropertyError
  | QueryCompileInvalidGroupBy !Text
  | QueryCompileMultipleGroupBy ![Text]
  | QueryCompileMissingAggregationProperty !Text
  | QueryCompileUnsupportedPropertyGrouping !Text
  deriving stock (Generic, Eq, Show)

data CompiledMetric = CompiledMetric
  { sql :: !Text,
    groupLabel :: !(Maybe Text),
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
  deriving stock (Generic, Eq, Show)

-- No caller-supplied SQL may select a result ordering.
data ResultOrder = BucketGroup | GroupKey | RetentionOrder | FunnelOrder | ExperimentFunnelOrder
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
          (compiled ^. #groupLabel)
          (accountParameter req <> metricParameters metric req)
          (boundedSQL (compiled ^. #ordering) (compiled ^. #sql))

runSessions :: (IOE :> es) => QueryPool -> QueryRequest -> Eff es (Either QueryExecutionError MetricResult)
runSessions pool req =
  checked req (Right ()) $
    runSQL pool "sessions" Nothing (accountParameter req) (buildSessionsSQL req)

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
  case validateDateRange (req ^. #from) (req ^. #to) >> additional of
    Left err -> pure (Left (QueryLimitFailure err))
    Right () -> liftIO action

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
        BucketGroup -> "bucket, group_key"
        GroupKey -> "group_key"
        RetentionOrder -> "sort_cohort, sort_offset"
        FunnelOrder -> "sort_step"
        ExperimentFunnelOrder -> "sort_variant, sort_step",
      "LIMIT " <> Text.pack (show (maxMetricPoints + 1))
    ]

type QueryParameter = (String, Text)

runSQL :: QueryPool -> Text -> Maybe Text -> [QueryParameter] -> Text -> IO (Either QueryExecutionError MetricResult)
runSQL pool name groupName =
  runSQLWith pool name (defaultPoint groupName)

runSQLWith :: QueryPool -> Text -> (AggRow -> MetricPoint) -> [QueryParameter] -> Text -> IO (Either QueryExecutionError MetricResult)
runSQLWith pool metric toPoint parameters sql = do
  outcome <- trySynchronous $
    withQueryConnection pool $
      -- ClickHaskell prepends each completed block; restore arrival order
      -- without sorting or reversing any rows within a repaired block.
      \conn -> concat . reverse <$> select (aggSelect parameters sql) conn (pure . repairAggRows)
  pure $ case outcome of
    Left err -> Left (QueryStorageFailure (Text.pack (show err)))
    Right rows
      | length rows > maxMetricPoints -> Left MetricResultTooLarge
      | otherwise -> Right MetricResult {metric, points = toPoint <$> rows}

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
          sql <> "\nSETTINGS compile_expressions = 0, compile_aggregate_expressions = 0, compile_sort_description = 0"
  where
    addOne (name, value) rest =
      addParameter name (toChType (Text.unpack value) :: ChString) . rest

defaultPoint :: Maybe Text -> AggRow -> MetricPoint
defaultPoint groupName AggRow {bucket, group_key, value} =
  MetricPoint
    { bucket = nonEmpty (decodeUtf8 bucket),
      group =
        case (groupName, nonEmpty (decodeUtf8 group_key)) of
          (Just key, Just groupValue) -> Map.singleton key groupValue
          _ -> Map.empty,
      value
    }

retentionPoint :: AggRow -> MetricPoint
retentionPoint AggRow {bucket, group_key, value} =
  MetricPoint
    { bucket = Nothing,
      group =
        Map.fromList
          [ ("cohort", decodeUtf8 bucket),
            ("offset", decodeUtf8 group_key)
          ],
      value
    }

funnelPoint :: AggRow -> MetricPoint
funnelPoint AggRow {group_key, value} =
  case Text.splitOn "|" (decodeUtf8 group_key) of
    [stepIndex, step] ->
      MetricPoint {bucket = Nothing, group = Map.fromList [("step", step), ("index", stepIndex)], value}
    _ ->
      MetricPoint {bucket = Nothing, group = Map.empty, value}

experimentExposuresAggPoint :: AggRow -> MetricPoint
experimentExposuresAggPoint AggRow {bucket, group_key, value} =
  experimentExposuresPoint (nonEmpty (decodeUtf8 bucket)) (decodeUtf8 group_key) value

experimentConversionAggPoint :: SqlName -> AggRow -> MetricPoint
experimentConversionAggPoint experiment AggRow {group_key, value} =
  experimentConversionPoint experiment (decodeUtf8 group_key) value

experimentFunnelAggPoint :: SqlName -> AggRow -> MetricPoint
experimentFunnelAggPoint experiment AggRow {group_key, value} =
  experimentFunnelPoint experiment (decodeUtf8 group_key) value

experimentExposuresPoint :: Maybe Text -> Text -> Double -> MetricPoint
experimentExposuresPoint bucketValue groupKey value =
  case splitGroupKey groupKey of
    Just (experiment, variant) ->
      MetricPoint
        { bucket = bucketValue,
          group = Map.fromList [("experiment", experiment), ("variant", variant)],
          value
        }
    Nothing -> MetricPoint {bucket = bucketValue, group = Map.empty, value}

experimentConversionPoint :: SqlName -> Text -> Double -> MetricPoint
experimentConversionPoint experiment groupKey value =
  case splitGroupKey groupKey of
    Just (measure, variant) ->
      MetricPoint
        { bucket = Nothing,
          group =
            Map.fromList
              [ ("experiment", renderSqlName experiment),
                ("variant", variant),
                ("measure", measure)
              ],
          value
        }
    Nothing -> MetricPoint {bucket = Nothing, group = Map.empty, value}

experimentFunnelPoint :: SqlName -> Text -> Double -> MetricPoint
experimentFunnelPoint experiment groupKey value =
  case Text.splitOn "|" groupKey of
    [stepIndex, step, variant] ->
      MetricPoint
        { bucket = Nothing,
          group =
            Map.fromList
              [ ("experiment", renderSqlName experiment),
                ("variant", variant),
                ("index", stepIndex),
                ("step", step)
              ],
          value
        }
    _ -> MetricPoint {bucket = Nothing, group = Map.empty, value}

splitGroupKey :: Text -> Maybe (Text, Text)
splitGroupKey value = do
  let (firstPart, suffix) = Text.breakOn "|" value
  secondPart <- Text.stripPrefix "|" suffix
  guard (not (Text.null firstPart) && not (Text.null secondPart))
  pure (firstPart, secondPart)

nonEmpty :: Text -> Maybe Text
nonEmpty value
  | Text.null value = Nothing
  | otherwise = Just value

decodeUtf8 :: ByteString -> Text
decodeUtf8 = Text.decodeUtf8

compileMetric :: EventRegistry -> BuiltinMetric -> QueryRequest -> Either QueryCompileError CompiledMetric
compileMetric registry metric req =
  case metric of
    Simple def -> compileSimpleMetric registry def req
    Ratioed ratio -> do
      validateRatioGrouping ratio req
      pure CompiledMetric {sql = buildRatioSQL ratio req, groupLabel = Nothing, ordering = BucketGroup}

compileSimpleMetric :: EventRegistry -> MetricDefinition -> QueryRequest -> Either QueryCompileError CompiledMetric
compileSimpleMetric registry def req = do
  grouping <- effectiveGrouping registry def req
  predicates <- compileFilters registry def
  compiledSQL <- buildSimpleSQL registry grouping predicates def req
  pure
    CompiledMetric
      { sql = compiledSQL,
        groupLabel = dimensionLabel <$> grouping,
        ordering = BucketGroup
      }

buildSimpleSQL :: EventRegistry -> Maybe GroupDimension -> [Text] -> MetricDefinition -> QueryRequest -> Either QueryCompileError Text
buildSimpleSQL registry grouping predicates def req
  | def ^. #name == "active_users",
    null predicates,
    not (isPropertyGrouping grouping),
    Just Day <- effectiveGrain def req =
      Right (activeUsersDaySQL req)
  | def ^. #name == "active_users",
    null predicates,
    not (isPropertyGrouping grouping),
    Just Week <- effectiveGrain def req =
      Right (activeUsersWeekSQL req)
  | def ^. #name == "page_views",
    null predicates,
    not (isPropertyGrouping grouping),
    Just Day <- effectiveGrain def req =
      Right (pageViewsDaySQL grouping req)
  | aggregation def == UniqueCount =
      Right (uniqueUsersSQL grouping predicates def req)
  | aggregation def == Sum =
      aggregate "sum"
  | aggregation def == Average =
      aggregate "avg"
  | otherwise =
      Right (countEventsSQL grouping predicates def req)
  where
    aggregate functionName = do
      propertyText <-
        maybe
          (Left (QueryCompileMissingAggregationProperty (def ^. #name)))
          Right
          (def ^. #aggregationProperty)
      property <-
        first QueryCompilePropertyError $
          resolveNumericProperty registry (definitionEvents def) propertyText
      pure (propertyAggregateSQL functionName property grouping predicates def req)

-- Canonical rows deduplicate queue replay before every query-time aggregate
-- or identity join. Day/week raw-identity sketches remain approximate; exact
-- page-view states union event IDs across arbitrary insert boundaries.

buildRatioSQL :: RatioMetric -> QueryRequest -> Text
buildRatioSQL RatioMetric {numerator, denominator} req =
  Text.unlines
    [ "SELECT '' AS bucket, '' AS group_key,",
      "       if(denominator = 0, 0, numerator / denominator) AS value",
      "FROM",
      "  ( SELECT",
      "      ( SELECT toFloat64(uniqExact(canonical_user))",
      "        FROM analytics.events_resolved",
      "        WHERE " <> accountPredicate,
      "          AND canonical_user != ''",
      "          AND " <> eventNamePredicate "numerator_event_name" (validatedEventNames numerator),
      "          AND " <> timestampPredicate req,
      "      ) AS numerator,",
      "      ( SELECT toFloat64(uniqExact(canonical_user))",
      "        FROM analytics.events_resolved",
      "        WHERE " <> accountPredicate,
      "          AND canonical_user != ''",
      "          AND " <> eventNamePredicate "denominator_event_name" (validatedEventNames denominator),
      "          AND " <> timestampPredicate req,
      "      ) AS denominator",
      "  )",
      "ORDER BY bucket, group_key"
    ]

countEventsSQL :: Maybe GroupDimension -> [Text] -> MetricDefinition -> QueryRequest -> Text
countEventsSQL grouping predicates def req =
  Text.unlines
    [ "SELECT " <> bucketExpr (effectiveGrain def req) <> " AS bucket, " <> groupExpr grouping <> " AS group_key,",
      "       toFloat64(count(DISTINCT event_id)) AS value",
      "FROM analytics.events_canonical",
      "WHERE " <> accountPredicate,
      "  AND " <> timestampPredicate req <> eventNameClause "event_name" (validatedEventNames def) <> propertyFilterClause predicates,
      "GROUP BY bucket, group_key",
      "ORDER BY bucket, group_key"
    ]

uniqueUsersSQL :: Maybe GroupDimension -> [Text] -> MetricDefinition -> QueryRequest -> Text
uniqueUsersSQL grouping predicates def req =
  Text.unlines
    [ "SELECT " <> bucketExpr (effectiveGrain def req) <> " AS bucket, " <> groupExpr grouping <> " AS group_key,",
      "       toFloat64(uniqExact(canonical_user)) AS value",
      "FROM analytics.events_resolved",
      "WHERE " <> accountPredicate,
      "  AND canonical_user != ''",
      "  AND " <> timestampPredicate req <> eventNameClause "event_name" (validatedEventNames def) <> propertyFilterClause predicates,
      "GROUP BY bucket, group_key",
      "ORDER BY bucket, group_key"
    ]

propertyAggregateSQL :: Text -> PropertyName -> Maybe GroupDimension -> [Text] -> MetricDefinition -> QueryRequest -> Text
propertyAggregateSQL fn property grouping predicates def req =
  Text.unlines
    [ "SELECT " <> bucketExpr (effectiveGrain def req) <> " AS bucket, " <> groupExpr grouping <> " AS group_key,",
      "       toFloat64(" <> fn <> "(" <> propertyFloatExpr property <> ")) AS value",
      "FROM analytics.events_canonical",
      "WHERE " <> accountPredicate,
      "  AND " <> timestampPredicate req <> eventNameClause "event_name" (validatedEventNames def) <> propertyFilterClause predicates,
      "GROUP BY bucket, group_key",
      "ORDER BY bucket, group_key"
    ]

activeUsersDaySQL :: QueryRequest -> Text
activeUsersDaySQL req =
  Text.unlines
    [ "SELECT toString(day) AS bucket, '' AS group_key,",
      "       toFloat64(uniqCombinedMerge(users)) AS value",
      "FROM analytics.dau",
      "WHERE " <> accountPredicate,
      "  AND day >= " <> sqlString (renderDay (req ^. #from)) <> " AND day < " <> sqlString (renderDay (req ^. #to)),
      "GROUP BY day",
      "ORDER BY day"
    ]

activeUsersWeekSQL :: QueryRequest -> Text
activeUsersWeekSQL req =
  Text.unlines
    [ "SELECT toString(week) AS bucket, '' AS group_key,",
      "       toFloat64(uniqCombinedMerge(users)) AS value",
      "FROM analytics.wau",
      "WHERE " <> accountPredicate,
      "  AND week >= " <> sqlString (renderDay (req ^. #from)) <> " AND week < " <> sqlString (renderDay (req ^. #to)),
      "GROUP BY week",
      "ORDER BY week"
    ]

pageViewsDaySQL :: Maybe GroupDimension -> QueryRequest -> Text
pageViewsDaySQL grouping req =
  case grouping of
    Just GroupByRoute ->
      Text.unlines
        [ "SELECT toString(day) AS bucket, route AS group_key,",
          "       toFloat64(uniqExactMerge(views)) AS value",
          "FROM analytics.page_views_by_route",
          "WHERE " <> accountPredicate,
          "  AND day >= " <> sqlString (renderDay (req ^. #from)) <> " AND day < " <> sqlString (renderDay (req ^. #to)),
          "GROUP BY day, route",
          "ORDER BY day, route"
        ]
    _ ->
      Text.unlines
        [ "SELECT toString(day) AS bucket, '' AS group_key,",
          "       toFloat64(uniqExactMerge(views)) AS value",
          "FROM analytics.page_views_by_route",
          "WHERE " <> accountPredicate,
          "  AND day >= " <> sqlString (renderDay (req ^. #from)) <> " AND day < " <> sqlString (renderDay (req ^. #to)),
          "GROUP BY day",
          "ORDER BY day"
        ]

buildSessionsSQL :: QueryRequest -> Text
buildSessionsSQL req = boundedSQL BucketGroup (buildSessionsSQLAggregate req)

buildSessionsSQLAggregate :: QueryRequest -> Text
buildSessionsSQLAggregate req =
  "SELECT "
    <> bucketExpr (req ^. #timeGrain <|> Just Day)
    <> """ AS bucket, '' AS group_key,
              toFloat64(uniqExact(session_id)) AS value
       FROM analytics.events_canonical
       WHERE """
    <> accountPredicate
    <> "\n  AND "
    <> timestampPredicate req
    <> """

         AND session_id != ''
       GROUP BY bucket, group_key
       ORDER BY bucket, group_key"""

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
      "    FROM analytics.events_resolved",
      "    WHERE " <> accountPredicate,
      "      AND canonical_user != ''",
      "      AND " <> timestampPredicate req,
      "    GROUP BY canonical_user",
      "  ),",
      "  activity AS",
      "  (",
      "    SELECT DISTINCT canonical_user, toDate(occurred_at) AS active_day",
      "    FROM analytics.events_resolved",
      "    WHERE " <> accountPredicate,
      "      AND canonical_user != ''",
      "      AND " <> timestampPredicate req,
      "  )",
      "SELECT",
      "    f.cohort_day AS sort_cohort, dateDiff('day', f.cohort_day, a.active_day) AS sort_offset,",
      "    toString(f.cohort_day) AS bucket,",
      "    toString(dateDiff('day', f.cohort_day, a.active_day)) AS group_key,",
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
      concat(toString(step.1), '|', step.2) AS group_key,
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
    <> """
       ) AS level
         FROM analytics.events_resolved
         WHERE """
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
buildExperimentExposuresSQL req experiment = boundedSQL BucketGroup (buildExperimentExposuresSQLAggregate req experiment)

buildExperimentExposuresSQLAggregate :: QueryRequest -> Maybe SqlName -> Text
buildExperimentExposuresSQLAggregate req experiment =
  Text.unlines
    [ "SELECT",
      "    " <> experimentBucketExpr (req ^. #timeGrain) <> " AS bucket,",
      "    concat(experiment, '|', variant) AS group_key,",
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
buildExperimentConversionSQL req experiment conversionEvent = boundedSQL GroupKey (buildExperimentConversionSQLAggregate req experiment conversionEvent)

buildExperimentConversionSQLAggregate :: QueryRequest -> SqlName -> SqlName -> Text
buildExperimentConversionSQLAggregate req _experiment _conversionEvent =
  Text.unlines
    [ "WITH exposures AS",
      "(",
      "    SELECT",
      "        canonical_user,",
      "        CAST(toString(getSubcolumn(properties_json, 'variant')), 'String') AS variant,",
      "        min(occurred_at) AS first_exposure",
      "    FROM analytics.events_resolved",
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
      "    FROM analytics.events_resolved",
      "    WHERE canonical_user != ''",
      "      AND " <> accountPredicate,
      "      AND event_name = {conversion_event:String}",
      "      AND " <> timestampPredicate req,
      "    GROUP BY canonical_user",
      ")",
      "SELECT",
      "    '' AS bucket,",
      "    concat(m.1, '|', variant) AS group_key,",
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
      "    FROM analytics.events_resolved",
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
      "    concat(toString(step.1), '|', step.2, '|', variant) AS group_key,",
      "    toFloat64(countIf(level >= step.1)) AS value",
      "FROM",
      "(",
      "    SELECT",
      "        e.variant AS variant,",
      "        r.canonical_user AS canonical_user,",
      "        windowFunnel(" <> Text.pack (show window) <> ")(toDateTime(r.occurred_at), " <> conditions <> ") AS level",
      "    FROM analytics.events_resolved AS r",
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

groupExpr :: Maybe GroupDimension -> Text
groupExpr = \case
  Just GroupByEventName -> "toString(event_name)"
  Just GroupBySource -> "toString(source)"
  Just GroupByRoute -> "path(coalesce(url, ''))"
  Just (GroupByProperty property) -> propertyGroupExpr property
  Nothing -> "''"

dimensionLabel :: GroupDimension -> Text
dimensionLabel = \case
  GroupByEventName -> "event_name"
  GroupBySource -> "source"
  GroupByRoute -> "route"
  GroupByProperty property -> propertyNameText property

effectiveGrouping :: EventRegistry -> MetricDefinition -> QueryRequest -> Either QueryCompileError (Maybe GroupDimension)
effectiveGrouping registry def QueryRequest {groupBy = requested} =
  case requested of
    Just dimensions -> oneGrouping (parseWireGrouping registry def) dimensions
    Nothing -> oneGrouping (parseDefinitionGrouping registry def) (def ^. #groupBy)

oneGrouping :: (Text -> Either QueryCompileError GroupDimension) -> [Text] -> Either QueryCompileError (Maybe GroupDimension)
oneGrouping _ [] = Right Nothing
oneGrouping parse [value] = Just <$> parse value
oneGrouping _ values = Left (QueryCompileMultipleGroupBy values)

parseWireGrouping :: EventRegistry -> MetricDefinition -> Text -> Either QueryCompileError GroupDimension
parseWireGrouping registry def value =
  case value of
    "event_name" -> Right GroupByEventName
    "source" -> Right GroupBySource
    "route" -> Right GroupByRoute
    _ ->
      case Text.stripPrefix "prop:" value of
        Just property ->
          GroupByProperty
            <$> first
              QueryCompilePropertyError
              (resolveProperty registry (definitionEvents def) property)
        Nothing -> Left (QueryCompileInvalidGroupBy value)

parseDefinitionGrouping :: EventRegistry -> MetricDefinition -> Text -> Either QueryCompileError GroupDimension
parseDefinitionGrouping registry def property =
  GroupByProperty
    <$> first
      QueryCompilePropertyError
      (resolveProperty registry (definitionEvents def) property)

validateRatioGrouping :: RatioMetric -> QueryRequest -> Either QueryCompileError ()
validateRatioGrouping ratio QueryRequest {groupBy = requested} =
  case requested of
    Nothing -> Right ()
    Just [] -> Right ()
    Just ["event_name"] -> Right ()
    Just ["source"] -> Right ()
    Just ["route"] -> Right ()
    Just [value]
      | isJust (Text.stripPrefix "prop:" value) ->
          Left (QueryCompileUnsupportedPropertyGrouping (ratio ^. #name))
      | otherwise -> Left (QueryCompileInvalidGroupBy value)
    Just values -> Left (QueryCompileMultipleGroupBy values)

compileFilters :: EventRegistry -> MetricDefinition -> Either QueryCompileError [Text]
compileFilters registry def =
  traverse compileOne (Map.toList (def ^. #filters))
  where
    compileOne (name, value) = do
      property <-
        first QueryCompilePropertyError $
          resolveProperty registry (definitionEvents def) name
      first QueryCompilePropertyError (propertyEqualsPredicate property value)

definitionEvents :: MetricDefinition -> [EventName]
definitionEvents def = EventName <$> def ^. #eventNames

isPropertyGrouping :: Maybe GroupDimension -> Bool
isPropertyGrouping = \case
  Just GroupByProperty {} -> True
  _ -> False

propertyFilterClause :: [Text] -> Text
propertyFilterClause = foldMap ("\n  AND " <>)

queryCompileErrorCode :: QueryCompileError -> Text
queryCompileErrorCode = \case
  QueryCompilePropertyError PropertyErrorUndeclared {} -> "unknown_property"
  QueryCompilePropertyError PropertyErrorUnsupportedFilterValue {} -> "invalid_property_filter"
  QueryCompilePropertyError {} -> "invalid_property"
  QueryCompileInvalidGroupBy {} -> "invalid_group_by"
  QueryCompileMultipleGroupBy {} -> "invalid_group_by"
  QueryCompileMissingAggregationProperty {} -> "invalid_metric_definition"
  QueryCompileUnsupportedPropertyGrouping {} -> "invalid_group_by"

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
  QueryCompilePropertyError (PropertyErrorUnsupportedFilterValue property value) ->
    "unsupported filter value for property " <> property <> ": " <> Text.pack (show value)
  QueryCompileInvalidGroupBy value ->
    "invalid groupBy value: " <> value
  QueryCompileMultipleGroupBy values ->
    "exactly one groupBy dimension is supported; received: " <> Text.intercalate "," values
  QueryCompileMissingAggregationProperty metric ->
    "metric is missing aggregationProperty: " <> metric
  QueryCompileUnsupportedPropertyGrouping metric ->
    "property grouping is not supported for ratio metric: " <> metric

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
accountParameter req = [("account_id", unAccountId (req ^. #accountId))]

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
simpleMetricParameters def req
  | def ^. #name == "active_users",
    Just Day <- effectiveGrain def req =
      []
  | def ^. #name == "active_users",
    Just Week <- effectiveGrain def req =
      []
  | def ^. #name == "page_views",
    Just Day <- effectiveGrain def req =
      []
  | otherwise =
      namedParameters "event_name" (validatedEventNames def)

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
