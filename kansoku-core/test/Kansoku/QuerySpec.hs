module Kansoku.QuerySpec (spec) where

import Data.Foldable (traverse_)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Time (fromGregorian)
import Kansoku.Event
  ( AccountId (..),
    EventName (..),
    EventSchema (..),
    PropertySpec (..),
    PropertyType (..),
    defaultRegistry,
    lookupSchema,
  )
import Kansoku.Metrics.Api (TimeGrain (..))
import Kansoku.Metrics.Definition (Aggregation (Average, Sum))
import Kansoku.Metrics.Query
import Kansoku.Metrics.Query.Validate (SqlName, mkSqlName)
import Kansoku.Metrics.Registry
import Kansoku.Prelude
import Test.Hspec

spec :: Spec
spec = describe "Kansoku.Query.buildSQL" $ do
  it "reads active users at day grain from analytics.dau with uniqCombinedMerge" $
    buildSQL (Simple activeUsers) dayRequest
      `shouldBe` Text.unlines
        [ "SELECT toString(day) AS bucket, '' AS group_key,",
          "       toFloat64(uniqCombinedMerge(users)) AS value",
          "FROM analytics.dau",
          "WHERE account_id = {account_id:String}",
          "  AND day >= '2026-06-01' AND day < '2026-06-08'",
          "GROUP BY day",
          "ORDER BY day"
        ]

  it "reads page views at day grain from the count-state rollup" $
    buildSQL (Simple pageViews) dayRequest
      `shouldBe` Text.unlines
        [ "SELECT toString(day) AS bucket, '' AS group_key,",
          "       toFloat64(countMerge(views)) AS value",
          "FROM analytics.page_views_by_route",
          "WHERE account_id = {account_id:String}",
          "  AND day >= '2026-06-01' AND day < '2026-06-08'",
          "GROUP BY day",
          "ORDER BY day"
        ]

  it "counts events at day grain with distinct event ids" $
    buildSQL (Simple events) dayRequest
      `shouldBe` Text.unlines
        [ "SELECT toString(toDate(occurred_at)) AS bucket, '' AS group_key,",
          "       toFloat64(count(DISTINCT event_id)) AS value",
          "FROM analytics.events_raw",
          "WHERE account_id = {account_id:String}",
          "  AND occurred_at >= '2026-06-01 00:00:00' AND occurred_at < '2026-06-08 00:00:00'",
          "GROUP BY bucket, group_key",
          "ORDER BY bucket, group_key"
        ]

  it "builds conversion ratio SQL from identity-resolved users" $
    buildSQL (Ratioed conversionRate) dayRequest
      `shouldContainText` "if(denominator = 0, 0, numerator / denominator) AS value"

  it "uses native ClickHouse placeholders for built-in event names" $ do
    let sql = buildSQL (Ratioed conversionRate) dayRequest
    sql `shouldContainText` "{numerator_event_name_1:String}"
    sql `shouldContainText` "{denominator_event_name_1:String}"
    sql `shouldNotContainText` "'signup_completed'"
    sql `shouldNotContainText` "'signup_started'"

  it "counts sessions by distinct non-empty session ids" $
    buildSessionsSQL dayRequest
      `shouldBe` """
                 SELECT toString(toDate(occurred_at)) AS bucket, '' AS group_key,
                        toFloat64(uniqExact(session_id)) AS value
                 FROM analytics.events_raw
                 WHERE account_id = {account_id:String}
                   AND occurred_at >= '2026-06-01 00:00:00' AND occurred_at < '2026-06-08 00:00:00'
                   AND session_id != ''
                 GROUP BY bucket, group_key
                 ORDER BY bucket, group_key"""

  it "builds retention SQL with default offsets plus cohort size" $
    buildRetentionSQL dayRequest [1, 7, 14, 30]
      `shouldContainText` "WHERE dateDiff('day', f.cohort_day, a.active_day) IN (0,1,7,14,30)"

  it "builds a single-pass ordered funnel with native placeholders" $ do
    let sql = buildFunnelSQL dayRequest 604800 (sqlName <$> ["signup_started", "signup_completed"])
    sql `shouldContainText` "windowFunnel(604800)(toDateTime(occurred_at), event_name = {funnel_step_1:String}, event_name = {funnel_step_2:String})"
    sql `shouldContainText` "event_name IN ({funnel_step_1:String}, {funnel_step_2:String})"
    sql `shouldContainText` "ARRAY JOIN [(1, {funnel_step_1:String}), (2, {funnel_step_2:String})] AS step"
    sql `shouldContainText` "toFloat64(countIf(level >= step.1)) AS value"
    sql `shouldContainText` "ORDER BY step.1"
    sql `shouldNotContainText` "UNION ALL"

  it "renders three funnel step indices in caller order" $
    buildFunnelSQL dayRequest 3600 (sqlName <$> ["one", "two", "three"])
      `shouldContainText` "ARRAY JOIN [(1, {funnel_step_1:String}), (2, {funnel_step_2:String}), (3, {funnel_step_3:String})] AS step"

  it "scopes every SQL builder with a native account parameter" $ do
    let sqlBuilders =
          [ buildSQL (Simple activeUsers) dayRequest,
            buildSQL (Simple activeUsers) weekRequest,
            buildSQL (Simple pageViews) dayRequest,
            buildSQL (Simple pageViews) routeRequest,
            buildSQL (Simple events) dayRequest,
            buildSQL (requiredMetric "new_users") dayRequest,
            buildSQL (requiredMetric "revenue") dayRequest,
            buildSQL (Ratioed conversionRate) dayRequest,
            buildSessionsSQL dayRequest,
            buildRetentionSQL dayRequest [1, 7],
            buildFunnelSQL dayRequest 604800 (sqlName <$> ["signup_started", "signup_completed"])
          ]
    traverse_ (`shouldContainText` "account_id = {account_id:String}") sqlBuilders
    traverse_ (`shouldNotContainText` "acct_query") sqlBuilders

  it "keeps ClickHouse ORDER BY as the sole ordering authority for every builder" $
    traverse_
      (`shouldContainText` "ORDER BY")
      [ buildSQL (Simple activeUsers) dayRequest,
        buildSQL (Simple pageViews) dayRequest,
        buildSQL (Simple events) dayRequest,
        buildSQL (requiredMetric "new_users") dayRequest,
        buildSQL (requiredMetric "revenue") dayRequest,
        buildSQL (Ratioed conversionRate) dayRequest,
        buildSessionsSQL dayRequest,
        buildRetentionSQL dayRequest [1, 7],
        buildFunnelSQL dayRequest 604800 (sqlName <$> ["signup_started", "signup_completed"])
      ]

  it "requires every Sum or Average builtin to declare a numeric aggregation property" $
    traverse_ assertAggregationProperty (Map.elems builtinMetrics)

dayRequest :: QueryRequest
dayRequest =
  QueryRequest
    { accountId = AccountId "acct_query",
      from = fromGregorian 2026 6 1,
      to = fromGregorian 2026 6 8,
      groupBy = Nothing,
      timeGrain = Just Day
    }

weekRequest :: QueryRequest
weekRequest = dayRequest {timeGrain = Just Week}

routeRequest :: QueryRequest
routeRequest = dayRequest {groupBy = Just ["route"]}

shouldContainText :: Text -> Text -> Expectation
shouldContainText haystack needle =
  Text.isInfixOf needle haystack `shouldBe` True

shouldNotContainText :: Text -> Text -> Expectation
shouldNotContainText haystack needle =
  Text.isInfixOf needle haystack `shouldBe` False

sqlName :: Text -> SqlName
sqlName value =
  case mkSqlName value of
    Right name -> name
    Left invalid -> error ("invalid SQL name fixture: " <> Text.unpack invalid)

requiredMetric :: Text -> BuiltinMetric
requiredMetric name =
  case builtinMetric name of
    Just metric -> metric
    Nothing -> error ("missing built-in metric fixture: " <> Text.unpack name)

assertAggregationProperty :: BuiltinMetric -> Expectation
assertAggregationProperty = \case
  Simple def
    | def ^. #aggregation == Sum || def ^. #aggregation == Average ->
        case def ^. #aggregationProperty of
          Nothing -> expectationFailure ("missing aggregation property for " <> Text.unpack (def ^. #name))
          Just property -> traverse_ (assertNumericDeclaration property) (def ^. #eventNames)
  _ -> pure ()

assertNumericDeclaration :: Text -> Text -> Expectation
assertNumericDeclaration property event =
  case lookupSchema (EventName event) defaultRegistry of
    Nothing -> expectationFailure ("missing event schema for " <> Text.unpack event)
    Just EventSchema {schemaProperties} ->
      case [propType | PropertySpec {propName, propType} <- schemaProperties, propName == property] of
        [PTNumber] -> pure ()
        [PTAny] -> pure ()
        _ -> expectationFailure ("aggregation property is not numeric: " <> Text.unpack event <> "." <> Text.unpack property)
