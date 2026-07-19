{-# LANGUAGE TypeApplications #-}

-- | Query compiler and executor for semantic metrics.
module Kansoku.Metrics.Query
  ( QueryRequest (..),
    buildFunnelSQL,
    buildRetentionSQL,
    buildSQL,
    buildSessionsSQL,
    run,
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
import Kansoku.Metrics.Api (MetricPoint (..), MetricResult (..), TimeGrain (..))
import Kansoku.Metrics.Definition (Aggregation (..), MetricDefinition (..), RatioMetric (..))
import Kansoku.Metrics.Query.Validate (SqlName, mkSqlName, renderSqlName)
import Kansoku.Metrics.Registry (BuiltinMetric (..))
import Kansoku.Prelude

data QueryRequest = QueryRequest
  { from :: !Day,
    to :: !Day,
    groupBy :: !(Maybe [Text]),
    timeGrain :: !(Maybe TimeGrain)
  }
  deriving stock (Generic, Eq, Show)

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

buildSQL :: BuiltinMetric -> QueryRequest -> Text
buildSQL = \case
  Simple def -> buildSimpleSQL def
  Ratioed ratio -> buildRatioSQL ratio

run :: (IOE :> es) => QueryPool -> BuiltinMetric -> QueryRequest -> Eff es MetricResult
run pool metric req =
  liftIO (runSQL pool (metricName metric) (groupLabel req) (metricParameters metric req) (buildSQL metric req))

runSessions :: (IOE :> es) => QueryPool -> QueryRequest -> Eff es MetricResult
runSessions pool req =
  liftIO (runSQL pool "sessions" Nothing [] (buildSessionsSQL req))

runRetention :: (IOE :> es) => QueryPool -> QueryRequest -> [Int] -> Eff es MetricResult
runRetention pool req offsets =
  liftIO (runSQLWith pool "retention" retentionPoint [] (buildRetentionSQL req offsets))

runFunnel :: (IOE :> es) => QueryPool -> QueryRequest -> Int -> [SqlName] -> Eff es MetricResult
runFunnel pool req window steps =
  liftIO (runSQLWith pool "funnel" funnelPoint (namedParameters "funnel_step" steps) (buildFunnelSQL req window steps))

type QueryParameter = (String, SqlName)

runSQL :: QueryPool -> Text -> Maybe Text -> [QueryParameter] -> Text -> IO MetricResult
runSQL pool name groupName =
  runSQLWith pool name (defaultPoint groupName)

runSQLWith :: QueryPool -> Text -> (AggRow -> MetricPoint) -> [QueryParameter] -> Text -> IO MetricResult
runSQLWith pool metric toPoint parameters sql = do
  rows <- withQueryConnection pool $ \conn -> concat <$> select (aggSelect parameters sql) conn (pure . repairAggRows)
  pure MetricResult {metric, points = toPoint <$> rows}

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
          Text.unlines
            [ "SELECT CAST(bucket, 'String') AS bucket, CAST(group_key, 'String') AS group_key, CAST(value, 'Float64') AS value",
              "FROM (",
              sql,
              ")",
              "SETTINGS compile_expressions = 0, compile_aggregate_expressions = 0, compile_sort_description = 0"
            ]
  where
    addOne (name, value) rest =
      addParameter name (toChType (Text.unpack (renderSqlName value)) :: ChString) . rest

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

nonEmpty :: Text -> Maybe Text
nonEmpty value
  | Text.null value = Nothing
  | otherwise = Just value

decodeUtf8 :: ByteString -> Text
decodeUtf8 = Text.decodeUtf8

buildSimpleSQL :: MetricDefinition -> QueryRequest -> Text
buildSimpleSQL def req
  | def ^. #name == "active_users",
    Just Day <- effectiveGrain def req =
      activeUsersDaySQL req
  | def ^. #name == "active_users",
    Just Week <- effectiveGrain def req =
      activeUsersWeekSQL req
  | def ^. #name == "page_views",
    Just Day <- effectiveGrain def req =
      pageViewsDaySQL req
  | aggregation def == UniqueCount =
      uniqueUsersSQL def req
  | aggregation def == Sum =
      propertyAggregateSQL "sum" def req
  | aggregation def == Average =
      propertyAggregateSQL "avg" def req
  | otherwise =
      countEventsSQL def req

-- Metric source and accuracy map:
--

-- * active_users at day/week grain is an approximate pre-aggregated raw-

--   identity count from dau/wau (uniqCombined, about 0.8% relative error at
--   high cardinality).

-- * page_views at day grain is an exact inserted-row countMerge rollup, but is

--   replay-sensitive because count states cannot retract a replay later
--   collapsed by events_raw.

-- * unique-user, ratio, retention, and funnel metrics read events_resolved for

--   exact, query-time identity stitching. Its FINAL-free view is safe because
--   these queries use distinct/min/ordered per-user aggregation, not row count.

-- * events, property aggregates, and sessions read events_raw directly;

--   events remains replay-proof via count(DISTINCT event_id).

buildRatioSQL :: RatioMetric -> QueryRequest -> Text
buildRatioSQL RatioMetric {numerator, denominator} req =
  Text.unlines
    [ "SELECT '' AS bucket, '' AS group_key,",
      "       if(denominator = 0, 0, numerator / denominator) AS value",
      "FROM",
      "  ( SELECT",
      "      ( SELECT toFloat64(uniqExact(canonical_user))",
      "        FROM analytics.events_resolved",
      "        WHERE canonical_user != ''",
      "          AND " <> eventNamePredicate "numerator_event_name" (validatedEventNames numerator),
      "          AND " <> timestampPredicate req,
      "      ) AS numerator,",
      "      ( SELECT toFloat64(uniqExact(canonical_user))",
      "        FROM analytics.events_resolved",
      "        WHERE canonical_user != ''",
      "          AND " <> eventNamePredicate "denominator_event_name" (validatedEventNames denominator),
      "          AND " <> timestampPredicate req,
      "      ) AS denominator",
      "  )",
      "ORDER BY bucket, group_key"
    ]

countEventsSQL :: MetricDefinition -> QueryRequest -> Text
countEventsSQL def req =
  Text.unlines
    [ "SELECT " <> bucketExpr (effectiveGrain def req) <> " AS bucket, " <> groupExpr req <> " AS group_key,",
      "       toFloat64(count(DISTINCT event_id)) AS value",
      "FROM analytics.events_raw",
      "WHERE " <> timestampPredicate req <> eventNameClause "event_name" (validatedEventNames def),
      "GROUP BY bucket, group_key",
      "ORDER BY bucket, group_key"
    ]

uniqueUsersSQL :: MetricDefinition -> QueryRequest -> Text
uniqueUsersSQL def req =
  Text.unlines
    [ "SELECT " <> bucketExpr (effectiveGrain def req) <> " AS bucket, " <> groupExpr req <> " AS group_key,",
      "       toFloat64(uniqExact(canonical_user)) AS value",
      "FROM analytics.events_resolved",
      "WHERE canonical_user != ''",
      "  AND " <> timestampPredicate req <> eventNameClause "event_name" (validatedEventNames def),
      "GROUP BY bucket, group_key",
      "ORDER BY bucket, group_key"
    ]

propertyAggregateSQL :: Text -> MetricDefinition -> QueryRequest -> Text
propertyAggregateSQL fn def req =
  Text.unlines
    [ "SELECT " <> bucketExpr (effectiveGrain def req) <> " AS bucket, " <> groupExpr req <> " AS group_key,",
      "       toFloat64(" <> fn <> "(JSONExtractFloat(properties, 'amount'))) AS value",
      "FROM analytics.events_raw",
      "WHERE " <> timestampPredicate req <> eventNameClause "event_name" (validatedEventNames def),
      "GROUP BY bucket, group_key",
      "ORDER BY bucket, group_key"
    ]

activeUsersDaySQL :: QueryRequest -> Text
activeUsersDaySQL req =
  Text.unlines
    [ "SELECT toString(day) AS bucket, '' AS group_key,",
      "       toFloat64(uniqCombinedMerge(users)) AS value",
      "FROM analytics.dau",
      "WHERE day >= " <> sqlString (renderDay (req ^. #from)) <> " AND day < " <> sqlString (renderDay (req ^. #to)),
      "GROUP BY day",
      "ORDER BY day"
    ]

activeUsersWeekSQL :: QueryRequest -> Text
activeUsersWeekSQL req =
  Text.unlines
    [ "SELECT toString(week) AS bucket, '' AS group_key,",
      "       toFloat64(uniqCombinedMerge(users)) AS value",
      "FROM analytics.wau",
      "WHERE week >= " <> sqlString (renderDay (req ^. #from)) <> " AND week < " <> sqlString (renderDay (req ^. #to)),
      "GROUP BY week",
      "ORDER BY week"
    ]

pageViewsDaySQL :: QueryRequest -> Text
pageViewsDaySQL req =
  case groupLabel req of
    Just "route" ->
      Text.unlines
        [ "SELECT toString(day) AS bucket, route AS group_key,",
          "       toFloat64(countMerge(views)) AS value",
          "FROM analytics.page_views_by_route",
          "WHERE day >= " <> sqlString (renderDay (req ^. #from)) <> " AND day < " <> sqlString (renderDay (req ^. #to)),
          "GROUP BY day, route",
          "ORDER BY day, route"
        ]
    _ ->
      Text.unlines
        [ "SELECT toString(day) AS bucket, '' AS group_key,",
          "       toFloat64(countMerge(views)) AS value",
          "FROM analytics.page_views_by_route",
          "WHERE day >= " <> sqlString (renderDay (req ^. #from)) <> " AND day < " <> sqlString (renderDay (req ^. #to)),
          "GROUP BY day",
          "ORDER BY day"
        ]

buildSessionsSQL :: QueryRequest -> Text
buildSessionsSQL req =
  "SELECT "
    <> bucketExpr (req ^. #timeGrain <|> Just Day)
    <> """ AS bucket, '' AS group_key,
              toFloat64(uniqExact(session_id)) AS value
       FROM analytics.events_raw
       WHERE """
    <> timestampPredicate req
    <> """

         AND session_id != ''
       GROUP BY bucket, group_key
       ORDER BY bucket, group_key"""

-- | Retention over new-in-window cohorts. first_seen deliberately computes
-- min(day) inside the requested window; lifetime cohorts require a first-seen
-- rollup and are outside the MVP contract.
buildRetentionSQL :: QueryRequest -> [Int] -> Text
buildRetentionSQL req offsets =
  Text.unlines
    [ "WITH",
      "  first_seen AS",
      "  (",
      "    SELECT canonical_user, min(toDate(occurred_at)) AS cohort_day",
      "    FROM analytics.events_resolved",
      "    WHERE canonical_user != ''",
      "      AND " <> timestampPredicate req,
      "    GROUP BY canonical_user",
      "  ),",
      "  activity AS",
      "  (",
      "    SELECT DISTINCT canonical_user, toDate(occurred_at) AS active_day",
      "    FROM analytics.events_resolved",
      "    WHERE canonical_user != ''",
      "      AND " <> timestampPredicate req,
      "  )",
      "SELECT",
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
buildFunnelSQL req window steps =
  """
  SELECT
      '' AS bucket,
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
         WHERE canonical_user != ''
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

effectiveGrain :: MetricDefinition -> QueryRequest -> Maybe TimeGrain
effectiveGrain MetricDefinition {timeGrain = defaultGrain} QueryRequest {timeGrain = requestedGrain} =
  requestedGrain <|> defaultGrain <|> Just Day

bucketExpr :: Maybe TimeGrain -> Text
bucketExpr = \case
  Just Hour -> "toString(toStartOfHour(occurred_at))"
  Just Week -> "toString(toMonday(occurred_at))"
  Just Month -> "toString(toStartOfMonth(occurred_at))"
  _ -> "toString(toDate(occurred_at))"

groupExpr :: QueryRequest -> Text
groupExpr req =
  case groupLabel req of
    Just "event_name" -> "toString(event_name)"
    Just "source" -> "toString(source)"
    Just "route" -> "path(coalesce(url, ''))"
    _ -> "''"

groupLabel :: QueryRequest -> Maybe Text
groupLabel QueryRequest {groupBy = Just (label : _)} = Just label
groupLabel _ = Nothing

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
  zipWith (\position value -> (Text.unpack (parameterName prefix position), value)) [1 :: Int ..]

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
  List.nub (0 : filter (>= 0) offsets)

metricName :: BuiltinMetric -> Text
metricName = \case
  Simple MetricDefinition {name} -> name
  Ratioed RatioMetric {name} -> name
