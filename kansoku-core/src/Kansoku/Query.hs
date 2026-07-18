{-# LANGUAGE TypeApplications #-}

-- | Query compiler and executor for semantic metrics.
module Kansoku.Query
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
import Kansoku.Api.Metrics (MetricPoint (..), MetricResult (..), TimeGrain (..))
import Kansoku.ClickHouse (QueryPool, withQueryConnection)
import Kansoku.Metrics.Definition (Aggregation (..), MetricDefinition (..), RatioMetric (..))
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
  liftIO (runSQL pool (metricName metric) (groupLabel req) (buildSQL metric req))

runSessions :: (IOE :> es) => QueryPool -> QueryRequest -> Eff es MetricResult
runSessions pool req =
  liftIO (runSQL pool "sessions" Nothing (buildSessionsSQL req))

runRetention :: (IOE :> es) => QueryPool -> QueryRequest -> [Int] -> Eff es MetricResult
runRetention pool req offsets =
  liftIO (runSQLWith pool "retention" retentionPoint (buildRetentionSQL req offsets))

runFunnel :: (IOE :> es) => QueryPool -> QueryRequest -> [Text] -> Eff es MetricResult
runFunnel pool req steps =
  liftIO (runSQLWith pool "funnel" funnelPoint (buildFunnelSQL req steps))

runSQL :: QueryPool -> Text -> Maybe Text -> Text -> IO MetricResult
runSQL pool name groupName =
  runSQLWith pool name (defaultPoint groupName)

runSQLWith :: QueryPool -> Text -> (AggRow -> MetricPoint) -> Text -> IO MetricResult
runSQLWith pool metric toPoint sql = do
  rows <- withQueryConnection pool $ \conn -> concat <$> select (aggSelect sql) conn (pure . repairAggRows)
  pure MetricResult {metric, points = toPoint <$> List.sortOn sortKey rows}
  where
    sortKey AggRow {bucket, group_key} = (bucket, group_key)

-- ClickHaskell 1.1.0 reverses the first field of a three-field generic record
-- relative to the other fields. Repair each result block before it escapes the
-- typed decoder so bucket/value associations remain honest.
repairAggRows :: [AggRow] -> [AggRow]
repairAggRows rows =
  zipWith repair rows (reverse (fmap (^. #bucket) rows))
  where
    repair row bucketValue = row & #bucket .~ bucketValue

aggSelect :: Text -> Select AggColumns AggRow
aggSelect sql =
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
      "          AND " <> eventNamePredicate (eventNames numerator),
      "          AND " <> timestampPredicate req,
      "      ) AS numerator,",
      "      ( SELECT toFloat64(uniqExact(canonical_user))",
      "        FROM analytics.events_resolved",
      "        WHERE canonical_user != ''",
      "          AND " <> eventNamePredicate (eventNames denominator),
      "          AND " <> timestampPredicate req,
      "      ) AS denominator",
      "  )"
    ]

countEventsSQL :: MetricDefinition -> QueryRequest -> Text
countEventsSQL def req =
  Text.unlines
    [ "SELECT " <> bucketExpr (effectiveGrain def req) <> " AS bucket, " <> groupExpr req <> " AS group_key,",
      "       toFloat64(count(DISTINCT event_id)) AS value",
      "FROM analytics.events_raw",
      "WHERE " <> timestampPredicate req <> eventNameClause (eventNames def),
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
      "  AND " <> timestampPredicate req <> eventNameClause (eventNames def),
      "GROUP BY bucket, group_key",
      "ORDER BY bucket, group_key"
    ]

propertyAggregateSQL :: Text -> MetricDefinition -> QueryRequest -> Text
propertyAggregateSQL fn def req =
  Text.unlines
    [ "SELECT " <> bucketExpr (effectiveGrain def req) <> " AS bucket, " <> groupExpr req <> " AS group_key,",
      "       toFloat64(" <> fn <> "(JSONExtractFloat(properties, 'amount'))) AS value",
      "FROM analytics.events_raw",
      "WHERE " <> timestampPredicate req <> eventNameClause (eventNames def),
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
  Text.unlines
    [ "SELECT " <> bucketExpr (req ^. #timeGrain <|> Just Day) <> " AS bucket, '' AS group_key,",
      "       toFloat64(uniqExact(session_id)) AS value",
      "FROM analytics.events_raw",
      "WHERE " <> timestampPredicate req,
      "  AND session_id != ''",
      "GROUP BY bucket, group_key",
      "ORDER BY bucket, group_key"
    ]

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

buildFunnelSQL :: QueryRequest -> [Text] -> Text
buildFunnelSQL req steps =
  Text.intercalate "\nUNION ALL\n" (stepSQL <$> zip [1 :: Int ..] steps)
  where
    stepSQL (stepIndex, step) =
      Text.unlines
        [ "SELECT '' AS bucket, " <> sqlString (Text.pack (show stepIndex) <> "|" <> step) <> " AS group_key,",
          "       toFloat64(uniqExact(canonical_user)) AS value",
          "FROM analytics.events_resolved",
          "WHERE canonical_user != ''",
          "  AND event_name = " <> sqlString step,
          previousStepPredicates stepIndex,
          "  AND " <> timestampPredicate req
        ]
    previousStepPredicates stepIndex =
      Text.unlines (previousPredicate <$> take (stepIndex - 1) steps)
    previousPredicate previous =
      "  AND canonical_user IN (SELECT canonical_user FROM analytics.events_resolved WHERE canonical_user != '' AND event_name = "
        <> sqlString previous
        <> " AND "
        <> timestampPredicate req
        <> ")"

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

eventNameClause :: [Text] -> Text
eventNameClause [] = ""
eventNameClause names = "\n  AND " <> eventNamePredicate names

eventNamePredicate :: [Text] -> Text
eventNamePredicate [] = "1 = 1"
eventNamePredicate names = "event_name IN (" <> Text.intercalate ", " (sqlString <$> names) <> ")"

sqlString :: Text -> Text
sqlString value =
  "'" <> Text.replace "\\" "\\\\" (Text.replace "'" "\\'" value) <> "'"

renderDay :: Day -> Text
renderDay = Text.pack . formatTime defaultTimeLocale "%F"

normalizeOffsets :: [Int] -> [Int]
normalizeOffsets offsets =
  List.nub (0 : filter (>= 0) offsets)

metricName :: BuiltinMetric -> Text
metricName = \case
  Simple MetricDefinition {name} -> name
  Ratioed RatioMetric {name} -> name
