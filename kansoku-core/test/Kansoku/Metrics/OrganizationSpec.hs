module Kansoku.Metrics.OrganizationSpec (spec) where

import ClickHaskell (command)
import Control.Exception (bracket)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Time (fromGregorian)
import Effectful (runEff)
import Kansoku.Admin.ClickHouse (rebuildDerived)
import Kansoku.ClickHouse
import Kansoku.ClickHouseTestSupport
import Kansoku.Event
import Kansoku.Metrics.Api (CohortMode (..), MetricResult, RetentionMode (..))
import Kansoku.Metrics.Filter qualified as Filter
import Kansoku.Metrics.Query qualified as Q
import Kansoku.Metrics.Query.Validate (mkSqlName)
import Kansoku.Metrics.Registry (builtinMetric)
import Kansoku.Prelude
import Test.Hspec

spec :: Spec
spec = do
  describe "Organization schema" $ do
    it "keeps v1 context-only and validates governed v2 traits" $ do
      (view #properties <$> lookupSchemaVersion (EventName "group") 1 defaultRegistry) `shouldBe` Just []
      let group = sample "schema" "group" "alice" "A" "2026-07-01 00:00:00 UTC" & #schemaVersion ?~ 2
      validateEvent (group & #properties .~ KM.singleton "seats" (Aeson.Number 1.5)) `shouldSatisfy` isLeft
      validateEvent (group & #properties .~ KM.singleton "plan" Aeson.Null) `shouldSatisfy` isLeft
      governedTraitEligible group `shouldBe` True
      governedTraitEligible (group & #schemaVersion ?~ 1) `shouldBe` False
    it "uses the account-scoped resolved source and rejects undeclared traits" $ do
      metric <- maybe (fail "organizations missing") pure (builtinMetric "organizations")
      sql <- either (fail . show) pure (Q.buildSQL defaultRegistry metric (request {Q.groupBy = Just ["org:plan"]}))
      sql `shouldSatisfy` Text.isInfixOf "analytics.events_resolved_http("
      sql `shouldSatisfy` Text.isInfixOf "WHERE account_id={account_id:String}"
      Q.buildSQL defaultRegistry metric (request {Q.groupBy = Just ["org:invalid"]}) `shouldSatisfy` isLeft

  describe "Organization native" $ do
    it "counts organizations, merges member funnels and retention, and preserves user defaults" $ withClickHouse $ \connection -> do
      let rows =
            [ sample "a-start" "signup_started" "alice" "A" "2026-07-01 00:00:00 UTC",
              sample "b-start" "signup_started" "bob" "A" "2026-07-01 00:00:00 UTC",
              sample "a-end" "signup_completed" "alice" "A" "2026-07-01 00:00:01 UTC",
              sample "b-end" "signup_completed" "bob" "A" "2026-07-01 00:00:01 UTC",
              sample "c-start" "signup_started" "carol" "B" "2026-07-01 00:00:00 UTC",
              sample "a-return" "feature_used" "bob" "A" "2026-07-02 00:00:00 UTC" & #properties .~ KM.singleton "feature" (Aeson.String "test"),
              sample "unknown" "activity" "unknown" "" "2026-07-01 00:00:00 UTC"
            ]
      insertEvents connection (rows <> rows)
      withPool $ \pool -> do
        total pool "organizations" request {Q.aggregateOrganizations = False} `shouldReturn` 3 -- two on day one; A on day two
        selected <- either (fail . Text.unpack) pure (Filter.parseMetricFilter "organization:eq:A")
        total pool "organizations" request {Q.filters = [selected]} `shouldReturn` 2
        steps <- either (fail . Text.unpack) pure (traverse mkSqlName ["signup_started", "signup_completed"])
        let funnel req = runEff (Q.runFunnelMetric defaultRegistry pool req Nothing Q.defaultFunnelOptions 60 steps) >>= either (fail . show) pure
        values <$> funnel request `shouldReturn` [2, 1]
        values <$> funnel request {Q.aggregateOrganizations = False} `shouldReturn` [3, 2]
        retained <- runEff (Q.runRetentionMetric defaultRegistry pool RetentionOn WindowCohort request [1]) >>= either (fail . show) pure
        values retained `shouldBe` [2, 1]
        total pool "conversion_rate" request `shouldReturn` 0.5
        total pool "feature_adoption" request `shouldReturn` 1
        total pool "organizations" request {Q.accountId = AccountId "organization-other"} `shouldReturn` 0
    it "resolves current typed traits and attributes only missing event organizations to resolved users" $ withClickHouse $ \connection -> do
      let profile eid stamp props = sample eid "group" "owner" "C" stamp & #schemaVersion ?~ 2 & #properties .~ KM.fromList props
          rows =
            [ profile "org-enterprise" "2026-07-01 00:00:00 UTC" [("plan", Aeson.String "enterprise")],
              profile "org-pro" "2026-07-02 00:00:00 UTC" [("plan", Aeson.String "pro"), ("seats", Aeson.Number 10)],
              sample "org-page" "page_view" "owner" "" "2026-07-01 00:00:01 UTC",
              sample "org-explicit" "page_view" "owner" "D" "2026-07-01 00:00:02 UTC",
              sample "org-payment" "payment_completed" "owner" "C" "2026-07-01 00:00:03 UTC" & #properties .~ KM.singleton "amount" (Aeson.Number 7),
              sample "org-login" "identify" "owner" "" "2026-07-02 00:00:00 UTC" & #anonymousId ?~ AnonymousId "before-login",
              sample "org-prelogin" "page_view" "" "" "2026-07-01 00:00:04 UTC" & #anonymousId ?~ AnonymousId "before-login",
              sample "org-anon" "page_view" "" "" "2026-07-01 00:00:04 UTC" & #anonymousId ?~ AnonymousId "owner"
            ]
      insertEvents connection (reverse rows <> rows)
      onlyPages <- either (fail . Text.unpack) pure (Filter.parseMetricFilter "event_name:eq:page_view")
      withPool $ \pool -> do
        let req = request {Q.filters = [onlyPages]}
        total pool "organizations" req `shouldReturn` 1
        total pool "organizations" req {Q.userOrganization = True} `shouldReturn` 2
        result <- builtin pool "revenue" request {Q.groupBy = Just ["org:plan", "org:seats"]}
        [(point ^. #group, point ^. #value) | point <- result ^. #points] `shouldBe` [(Map.fromList [("org:plan", Just "pro"), ("org:seats", Just "10")], 7)]
        pro <- either (fail . Text.unpack) pure (Filter.parseMetricFilter "org:plan:eq:pro")
        total pool "organizations" req {Q.userOrganization = True, Q.filters = [onlyPages, pro]} `shouldReturn` 1
        insertEvents connection [sample "org-moved" "group" "owner" "D" "2026-07-03 00:00:00 UTC"]
        total pool "organizations" req {Q.userOrganization = True} `shouldReturn` 1
        total pool "organizations" req {Q.userOrganization = True, Q.filters = [onlyPages, pro]} `shouldReturn` 0
        rebuildDerived connection
        total pool "organizations" req {Q.userOrganization = True} `shouldReturn` 1
    it "returns complete point-cap and resource errors for organization populations" $ withClickHouse $ \connection -> do
      command connection "INSERT INTO analytics.events_raw(event_id,event_name,account_id,organization_id,occurred_at,received_at,properties,context) SELECT concat('org-cap-',toString(number)),'activity','organization-cap',concat('org-',toString(number)),toDateTime64('2026-07-01',3,'UTC'),toDateTime64('2026-07-01',3,'UTC'),'{}','{}' FROM numbers(10001)"
      withPool $ \pool -> do
        metric <- maybe (fail "organizations missing") pure (builtinMetric "organizations")
        runEff (Q.run defaultRegistry pool metric request {Q.accountId = AccountId "organization-cap", Q.groupBy = Just ["organization"]}) `shouldReturn` Left Q.MetricResultTooLarge

      cfg <- clickHouseConfigFromConfig <$> requireConfig
      bracket (newQueryPoolWithLimits cfg 1 (MetricsQueryLimits 30 1)) closeQueryPool $ \pool -> do
        metric <- maybe (fail "organizations missing") pure (builtinMetric "organizations")
        runEff (Q.run defaultRegistry pool metric request {Q.accountId = AccountId "organization-cap"}) `shouldReturn` Left Q.QueryResourceLimit

request :: Q.QueryRequest
request = Q.QueryRequest (AccountId "organization-native") (fromGregorian 2026 7 1) (fromGregorian 2026 7 3) Nothing Nothing [] [] True False False

sample :: Text -> Text -> Text -> Text -> String -> AnalyticsEvent
sample eid name user organization stamp =
  baseEvent (EventId eid) (EventName name) Service (read stamp) (read stamp)
    & #accountId
    ?~ AccountId "organization-native"
    & #userId
    .~ (if Text.null user then Nothing else Just (UserId user))
    & #organizationId
    ?~ OrganizationId organization

withPool :: (QueryPool -> IO a) -> IO a
withPool action = do
  cfg <- clickHouseConfigFromConfig <$> requireConfig
  bracket (newQueryPool cfg 1) closeQueryPool action

builtin :: QueryPool -> Text -> Q.QueryRequest -> IO MetricResult
builtin pool name req = do
  metric <- maybe (fail "missing metric") pure (builtinMetric name)
  runEff (Q.run defaultRegistry pool metric req) >>= either (fail . show) pure

total :: QueryPool -> Text -> Q.QueryRequest -> IO Double
total pool name req = sum . values <$> builtin pool name req

values :: MetricResult -> [Double]
values = map (view #value) . view #points

isLeft :: Either a b -> Bool
isLeft (Left _) = True
isLeft _ = False
