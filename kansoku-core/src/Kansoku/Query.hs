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
    Connection,
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
import Kansoku.Metrics.Definition (Aggregation (..), MetricDefinition (..), RatioMetric (..))
import Kansoku.Metrics.Registry (BuiltinMetric (..))
import Kansoku.Prelude
import Text.Read (readMaybe)

data QueryRequest = QueryRequest
  { from :: !Day,
    to :: !Day,
    groupBy :: !(Maybe [Text]),
    timeGrain :: !(Maybe TimeGrain)
  }
  deriving stock (Generic, Eq, Show)

type AggColumns =
  '[Column "line" ChString]

newtype AggLine = AggLine
  { line :: ByteString
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ClickHaskell AggColumns)

data AggRow = AggRow
  { bucket :: !Text,
    group_key :: !Text,
    value :: !Double
  }
  deriving stock (Generic, Eq, Show)

buildSQL :: BuiltinMetric -> QueryRequest -> Text
buildSQL = \case
  Simple def -> buildSimpleSQL def
  Ratioed ratio -> buildRatioSQL ratio

run :: (IOE :> es) => Connection -> BuiltinMetric -> QueryRequest -> Eff es MetricResult
run conn metric req =
  liftIO (runSQL conn (metricName metric) (groupLabel req) (buildSQL metric req))

runSessions :: (IOE :> es) => Connection -> QueryRequest -> Eff es MetricResult
runSessions conn req =
  liftIO (runSQL conn "sessions" Nothing (buildSessionsSQL req))

runRetention :: (IOE :> es) => Connection -> QueryRequest -> [Int] -> Eff es MetricResult
runRetention conn req offsets =
  liftIO (runSQLWith conn "retention" retentionPoint (buildRetentionSQL req offsets))

runFunnel :: (IOE :> es) => Connection -> QueryRequest -> [Text] -> Eff es MetricResult
runFunnel conn req steps =
  liftIO (runSQLWith conn "funnel" funnelPoint (buildFunnelSQL req steps))

runSQL :: Connection -> Text -> Maybe Text -> Text -> IO MetricResult
runSQL conn name groupName =
  runSQLWith conn name (defaultPoint groupName)

runSQLWith :: Connection -> Text -> (AggRow -> MetricPoint) -> Text -> IO MetricResult
runSQLWith conn metric toPoint sql = do
  rows <- fmap parseAggLine . concat <$> select (unsafeSelect sql) conn pure
  pure MetricResult {metric, points = toPoint <$> List.sortOn sortKey rows}
  where
    sortKey AggRow {bucket, group_key} = (bucket, group_key)

unsafeSelect :: Text -> Select AggColumns AggLine
unsafeSelect sql =
  unsafeMkSelect $
    const $
      Text.encodeUtf8Builder $
        Text.unlines
          [ "SELECT concat(ifNull(toString(bucket), ''), '\t', ifNull(toString(group_key), ''), '\t', ifNull(toString(value), '0')) AS line",
            "FROM (",
            sql,
            ")",
            "SETTINGS compile_expressions = 0, compile_sort_description = 0"
          ]

parseAggLine :: AggLine -> AggRow
parseAggLine (AggLine raw) =
  case Text.splitOn "\t" (decodeUtf8 raw) of
    [bucket, group_key, valueText] ->
      AggRow {bucket, group_key, value = fromMaybe 0 (readMaybe (Text.unpack valueText))}
    _ ->
      AggRow {bucket = decodeUtf8 raw, group_key = "", value = 0}

defaultPoint :: Maybe Text -> AggRow -> MetricPoint
defaultPoint groupName AggRow {bucket, group_key, value} =
  MetricPoint
    { bucket = nonEmpty bucket,
      group =
        case (groupName, nonEmpty group_key) of
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
          [ ("cohort", bucket),
            ("offset", group_key)
          ],
      value
    }

funnelPoint :: AggRow -> MetricPoint
funnelPoint AggRow {group_key, value} =
  case Text.splitOn "|" group_key of
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
      "       toFloat64(uniqExactMerge(users)) AS value",
      "FROM analytics.dau",
      "WHERE day >= " <> sqlString (renderDay (req ^. #from)) <> " AND day < " <> sqlString (renderDay (req ^. #to)),
      "GROUP BY day",
      "ORDER BY day"
    ]

activeUsersWeekSQL :: QueryRequest -> Text
activeUsersWeekSQL req =
  Text.unlines
    [ "SELECT toString(week) AS bucket, '' AS group_key,",
      "       toFloat64(uniqExactMerge(users)) AS value",
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
          "       toFloat64(uniqExactMerge(views)) AS value",
          "FROM analytics.page_views_by_route",
          "WHERE day >= " <> sqlString (renderDay (req ^. #from)) <> " AND day < " <> sqlString (renderDay (req ^. #to)),
          "GROUP BY day, route",
          "ORDER BY day, route"
        ]
    _ ->
      Text.unlines
        [ "SELECT toString(day) AS bucket, '' AS group_key,",
          "       toFloat64(uniqExactMerge(views)) AS value",
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
      "  AND isNotNull(session_id) AND session_id != ''",
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
