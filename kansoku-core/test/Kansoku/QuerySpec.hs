module Kansoku.QuerySpec (spec) where

import Data.Aeson qualified as Aeson
import Data.Either (isRight)
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
    latestSchema,
  )
import Kansoku.Metrics.Api (MetricPoint (..), TimeGrain (..))
import Kansoku.Metrics.Definition (Aggregation (Average, Sum), MetricDefinition)
import Kansoku.Metrics.Query hiding (buildSQL)
import Kansoku.Metrics.Query qualified as Query
import Kansoku.Metrics.Query.Property (PropertyError (..))
import Kansoku.Metrics.Query.Validate (SqlName, mkSqlName)
import Kansoku.Metrics.Registry
import Kansoku.Prelude
import Test.Hspec

spec :: Spec
spec = describe "Kansoku.Query.buildSQL" $ do
  it "keeps day/week users exact, resolved and restricted to activity" $
    traverse_
      ( \request -> do
          let sql = buildSQL (Simple activeUsers) request
          sql `shouldContainText` "analytics.events_resolved_http("
          sql `shouldContainText` "uniqExact(canonical_user)"
          sql `shouldContainText` "event_name NOT IN ('identify','identify_once','alias','group')"
          sql `shouldNotContainText` "uniqCombinedMerge"
      )
      [dayRequest, weekRequest]

  it "reads page views from canonical facts with native event-name binding" $ do
    let sql = buildSQL (Simple pageViews) dayRequest
    sql `shouldContainText` "FROM analytics.events_canonical"
    sql `shouldContainText` "count(DISTINCT event_id)"
    sql `shouldContainText` "{event_name_1:String}"

  it "counts distinct event IDs and sorts typed dimensions separately from JSON transport" $ do
    let sql = buildSQL (Simple events) dayRequest
    sql `shouldContainText` "count(DISTINCT event_id)"
    sql `shouldContainText` "toJSONString([]) AS group_key"
    sql `shouldContainText` "ORDER BY bucket, sort_group_1 NULLS FIRST, sort_group_2 NULLS FIRST"

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
      `shouldContainText` """
                          SELECT toString(toDate(occurred_at)) AS bucket, '[]' AS group_key,
                                 toFloat64(uniqExact(session_id)) AS value
                          FROM analytics.events_canonical
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

  it "builds guarded experiment exposure rollup queries at daily and whole-range grains" $ do
    let experiment = sqlName "checkout_v2"
        daily = buildExperimentExposuresSQL dayRequest (Just experiment)
        wholeRange = buildExperimentExposuresSQL wholeRangeRequest Nothing
    daily `shouldContainText` "toFloat64(uniqCombinedMerge(users)) AS value"
    daily `shouldContainText` "FROM analytics.experiment_exposures"
    daily `shouldContainText` "match(experiment, '^[a-z0-9_.:-]{1,128}$')"
    daily `shouldContainText` "match(variant, '^[a-z0-9_.:-]{1,128}$')"
    daily `shouldContainText` "experiment = {experiment:String}"
    daily `shouldNotContainText` "checkout_v2"
    wholeRange `shouldContainText` "'' AS bucket"
    wholeRange `shouldContainText` "GROUP BY experiment, variant"
    wholeRange `shouldNotContainText` "GROUP BY day, experiment, variant"

  it "builds exact conversion SQL with an explicit post-exposure ordering predicate" $ do
    let sql = buildExperimentConversionSQL dayRequest (sqlName "checkout_v2") (sqlName "purchase_completed")
    sql `shouldContainText` "min(occurred_at) AS first_exposure"
    sql `shouldContainText` "max(occurred_at) AS last_conversion"
    sql `shouldContainText` "c.last_conversion >= e.first_exposure"
    sql `shouldContainText` "uniqExactIf"
    sql `shouldContainText` "LEFT JOIN conversions"
    sql `shouldContainText` "ARRAY JOIN"
    sql `shouldContainText` "('conversion_rate', if(exposed = 0, 0., converted / exposed))"
    sql `shouldContainText` "{experiment:String}"
    sql `shouldContainText` "{conversion_event:String}"
    sql `shouldNotContainText` "checkout_v2"
    sql `shouldNotContainText` "purchase_completed"
    sql `shouldNotContainText` "UNION ALL"

  it "builds a parameterized post-exposure ordered funnel per variant" $ do
    let sql =
          buildExperimentFunnelSQL
            dayRequest
            (sqlName "checkout_v2")
            604800
            (sqlName <$> ["checkout_started", "purchase_completed"])
    sql `shouldContainText` "windowFunnel(604800)(toDateTime(r.occurred_at), r.event_name = {experiment_funnel_step_1:String}, r.event_name = {experiment_funnel_step_2:String})"
    sql `shouldContainText` "INNER JOIN exposures AS e"
    sql `shouldContainText` "r.occurred_at >= e.first_exposure"
    sql `shouldContainText` "r.event_name IN ({experiment_funnel_step_1:String}, {experiment_funnel_step_2:String})"
    sql `shouldContainText` "ARRAY JOIN [(1, {experiment_funnel_step_1:String}), (2, {experiment_funnel_step_2:String})] AS step"
    sql `shouldContainText` "toFloat64(countIf(level >= step.1)) AS value"
    sql `shouldContainText` "ORDER BY variant, step.1"
    sql `shouldNotContainText` "checkout_v2"
    sql `shouldNotContainText` "checkout_started"
    sql `shouldNotContainText` "purchase_completed"
    sql `shouldNotContainText` "UNION ALL"

  it "renders three experiment funnel step indices in caller order" $
    buildExperimentFunnelSQL dayRequest (sqlName "checkout_v2") 3600 (sqlName <$> ["one", "two", "three"])
      `shouldContainText` "ARRAY JOIN [(1, {experiment_funnel_step_1:String}), (2, {experiment_funnel_step_2:String}), (3, {experiment_funnel_step_3:String})] AS step"

  it "decodes experiment group keys into the public metric-point vocabulary" $ do
    experimentExposuresPoint (Just "2026-08-01") "[\"checkout_v2\",\"control\"]" 5
      `shouldBe` Right
        MetricPoint
          { bucket = Just "2026-08-01",
            group = fmap Just $ Map.fromList [("experiment", "checkout_v2"), ("variant", "control")],
            value = 5
          }
    experimentConversionPoint (sqlName "checkout_v2") "[\"conversion_rate\",\"treatment\"]" 0.6
      `shouldBe` Right
        MetricPoint
          { bucket = Nothing,
            group = fmap Just $ Map.fromList [("experiment", "checkout_v2"), ("variant", "treatment"), ("measure", "conversion_rate")],
            value = 0.6
          }
    experimentFunnelPoint (sqlName "checkout_v2") "[\"2\",\"purchase_completed\",\"treatment\"]" 3
      `shouldBe` Right
        MetricPoint
          { bucket = Nothing,
            group = fmap Just $ Map.fromList [("experiment", "checkout_v2"), ("variant", "treatment"), ("index", "2"), ("step", "purchase_completed")],
            value = 3
          }

  it "uses the native JSON projection for every experiment query" $
    traverse_
      (`shouldNotContainText` "JSONExtract")
      [ buildExperimentExposuresSQL dayRequest (Just (sqlName "checkout_v2")),
        buildExperimentConversionSQL dayRequest (sqlName "checkout_v2") (sqlName "purchase_completed"),
        buildExperimentFunnelSQL dayRequest (sqlName "checkout_v2") 604800 (sqlName <$> ["checkout_started", "purchase_completed"])
      ]

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
            buildFunnelSQL dayRequest 604800 (sqlName <$> ["signup_started", "signup_completed"]),
            buildExperimentExposuresSQL dayRequest (Just (sqlName "checkout_v2")),
            buildExperimentConversionSQL dayRequest (sqlName "checkout_v2") (sqlName "purchase_completed"),
            buildExperimentFunnelSQL dayRequest (sqlName "checkout_v2") 604800 (sqlName <$> ["checkout_started", "purchase_completed"])
          ]
    traverse_ (`shouldContainText` "account_id = {account_id:String}") sqlBuilders
    traverse_ (`shouldNotContainText` "acct_query") sqlBuilders

  it "keeps ClickHouse ORDER BY as the sole ordering authority for every builder" $
    traverse_
      ( \sql -> do
          sql `shouldContainText` "ORDER BY"
          Text.count "LIMIT 10001" sql `shouldBe` 1
          Text.stripEnd sql `shouldSatisfy` Text.isSuffixOf "LIMIT 10001"
      )
      [ buildSQL (Simple activeUsers) dayRequest,
        buildSQL (Simple pageViews) dayRequest,
        buildSQL (Simple events) dayRequest,
        buildSQL (requiredMetric "new_users") dayRequest,
        buildSQL (requiredMetric "revenue") dayRequest,
        buildSQL (Ratioed conversionRate) dayRequest,
        buildSessionsSQL dayRequest,
        buildRetentionSQL dayRequest [1, 7],
        buildFunnelSQL dayRequest 604800 (sqlName <$> ["signup_started", "signup_completed"]),
        buildExperimentExposuresSQL dayRequest (Just (sqlName "checkout_v2")),
        buildExperimentConversionSQL dayRequest (sqlName "checkout_v2") (sqlName "purchase_completed"),
        buildExperimentFunnelSQL dayRequest (sqlName "checkout_v2") 604800 (sqlName <$> ["checkout_started", "purchase_completed"])
      ]

  it "requires every Sum or Average builtin to declare a numeric aggregation property" $
    traverse_ assertAggregationProperty (Map.elems builtinMetrics)

  it "uses guarded native JSON extraction for scalar grouping and numeric aggregation" $ do
    let sql = buildSQL (Simple revenueDefinition) planRequest
    sql `shouldContainText` "dynamicElement(getSubcolumn(properties_json, 'plan'), 'String')"
    sql `shouldContainText` "toFloat64OrNull"
    sql `shouldContainText` "isNotNull("
    sql `shouldNotContainText` "JSONExtract"

  it "honors feature_adoption's declared property grouping by default" $
    buildSQL (requiredMetric "feature_adoption") dayRequest
      `shouldContainText` "dynamicElement(getSubcolumn(properties_json, 'feature'), 'String') AS sort_group_1"

  it "compiles declared metric filters through typed property expressions" $ do
    let filteredMetric =
          revenueDefinition
            & #filters
            .~ Map.fromList [("plan", Aeson.String "pro")]
    buildSQL (Simple filteredMetric) dayRequest
      `shouldContainText` "{metric_filter_1_1:String}"

  it "rejects undeclared, cross-event, hostile, duplicate and over-arity groups" $ do
    Query.buildSQL defaultRegistry (Simple revenueDefinition) (dayRequest {groupBy = Just ["prop:nope"]})
      `shouldBe` Left (QueryCompilePropertyError (PropertyErrorUndeclared "nope" (EventName "payment_completed")))
    let crossEvent = revenueDefinition & #eventNames .~ ["payment_completed", "feature_used"]
    Query.buildSQL defaultRegistry (Simple crossEvent) planRequest
      `shouldBe` Left (QueryCompilePropertyError (PropertyErrorUndeclared "plan" (EventName "feature_used")))
    traverse_
      ( \property ->
          Query.buildSQL defaultRegistry (Simple revenueDefinition) (dayRequest {groupBy = Just ["prop:" <> property]})
            `shouldBe` Left (QueryCompilePropertyError (PropertyErrorBadName property))
      )
      ["pl'an", "a b", Text.replicate 65 "a"]
    Query.buildSQL defaultRegistry (Simple revenueDefinition) (dayRequest {groupBy = Just ["prop:plan", "event_name"]})
      `shouldSatisfy` isRight
    Query.buildSQL defaultRegistry (Simple revenueDefinition) (dayRequest {groupBy = Just ["prop:plan", "source", "route"]})
      `shouldBe` Left (QueryCompileMultipleGroupBy ["prop:plan", "source", "route"])
    Query.buildSQL defaultRegistry (Simple revenueDefinition) (dayRequest {groupBy = Just ["source", "source"]})
      `shouldBe` Left (QueryCompileMultipleGroupBy ["source", "source"])

  it "rejects Sum metrics without an aggregation property" $
    Query.buildSQL defaultRegistry (Simple (revenueDefinition & #aggregationProperty .~ Nothing)) dayRequest
      `shouldBe` Left (QueryCompileMissingAggregationProperty "revenue")

dayRequest :: QueryRequest
dayRequest =
  QueryRequest
    { accountId = AccountId "acct_query",
      from = fromGregorian 2026 6 1,
      to = fromGregorian 2026 6 8,
      groupBy = Nothing,
      timeGrain = Just Day,
      filters = [],
      includeBots = False
    }

weekRequest :: QueryRequest
weekRequest = dayRequest {timeGrain = Just Week}

wholeRangeRequest :: QueryRequest
wholeRangeRequest = dayRequest {timeGrain = Nothing}

routeRequest :: QueryRequest
routeRequest = dayRequest {groupBy = Just ["route"]}

planRequest :: QueryRequest
planRequest = dayRequest {groupBy = Just ["prop:plan"]}

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

revenueDefinition :: MetricDefinition
revenueDefinition =
  case requiredMetric "revenue" of
    Simple def -> def
    Ratioed _ -> error "revenue fixture must be a simple metric"

buildSQL :: BuiltinMetric -> QueryRequest -> Text
buildSQL metric request =
  case Query.buildSQL defaultRegistry metric request of
    Right sql -> sql
    Left err -> error ("unexpected query compile error: " <> show err)

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
  case latestSchema (EventName event) defaultRegistry of
    Nothing -> expectationFailure ("missing event schema for " <> Text.unpack event)
    Just EventSchema {properties} ->
      case [propertyType | PropertySpec {name, propertyType} <- properties, name == property] of
        [PTNumber] -> pure ()
        [PTAny] -> pure ()
        _ -> expectationFailure ("aggregation property is not numeric: " <> Text.unpack event <> "." <> Text.unpack property)
