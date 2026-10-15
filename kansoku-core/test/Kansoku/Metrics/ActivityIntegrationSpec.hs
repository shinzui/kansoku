module Kansoku.Metrics.ActivityIntegrationSpec (spec) where

import ClickHaskell (Connection, command)
import Control.Exception (bracket)
import Control.Monad (forM_)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Map.Strict qualified as Map
import Data.String (fromString)
import Data.Text qualified as Text
import Data.Time (addDays, fromGregorian, utctDay)
import Effectful (Eff, IOE, runEff)
import Kansoku.ClickHouse
import Kansoku.ClickHouseTestSupport
import Kansoku.Event
import Kansoku.Ingest.QueuedEvent (enrichedQueuedEvent)
import Kansoku.Ingest.RequestContext (emptyRequestContext)
import Kansoku.Metrics.Api (CohortMode (..), MetricPoint, MetricResult, RetentionMode (..), TimeGrain (..), UserWindow (..))
import Kansoku.Metrics.Filter qualified as Filter
import Kansoku.Metrics.Query qualified as Query
import Kansoku.Metrics.Query.Validate (validateObservationCutoff)
import Kansoku.Prelude hiding (filtered)
import Test.Hspec

spec :: Spec
spec = do
  describe "Kansoku.Activity inputs" $ do
    it "defines observation by complete UTC days and rejects future windows before acquiring storage" $ do
      let today = fromGregorian 2026 7 10
      validateObservationCutoff today today `shouldBe` Right ()
      validateObservationCutoff today (addDays (-1) today) `shouldBe` Right ()
      validateObservationCutoff today (addDays 1 today) `shouldSatisfy` (\case Left _ -> True; _ -> False)
      actual <- utctDay <$> getCurrentTime
      let unused = error "observation validation acquired storage"
          req = (request "unused") {Query.from = actual, Query.to = addDays 1 actual}
      results <-
        sequence
          [ runEff (Query.runUsers defaultRegistry unused Rolling7 req),
            runEff (Query.runStickiness defaultRegistry unused req),
            runEff (Query.runLifecycle defaultRegistry unused req),
            runEff (Query.runRetentionMetric defaultRegistry unused RetentionOn WindowCohort req [1])
          ]
      forM_ results $ \result -> result `shouldSatisfy` (\case Left (Query.QueryLimitFailure failure) -> failure ^. #limitCode == "unclosed_observation_window"; _ -> False)

    it "rejects non-daily rolling, retention and lifecycle inputs before acquiring storage" $ do
      let unused = error "grain validation acquired storage"
          req = (request "unused") {Query.timeGrain = Just Week}
      results <-
        sequence
          [ runEff (Query.runUsers defaultRegistry unused Rolling30 req),
            runEff (Query.runStickiness defaultRegistry unused req),
            runEff (Query.runLifecycle defaultRegistry unused req),
            runEff (Query.runRetentionMetric defaultRegistry unused RetentionOn WindowCohort req [1])
          ]
      forM_ results $ \result -> result `shouldSatisfy` (\case Left (Query.QueryLimitFailure failure) -> failure ^. #limitCode == "invalid_time_grain"; _ -> False)

  describe "Kansoku.Activity native" $ do
    it "counts exact stitched rolling subjects at UTC boundaries and applies the same filters and bot population" $ withClickHouse $ \connection -> do
      let account = "activity-rolling"
          first = event account "one" "page_view" "one" "2026-07-01 00:00:00 UTC" & #userId .~ Nothing & #anonymousId ?~ AnonymousId "one-cookie"
          identify = event account "identify" "identify" "one" "2026-07-02 00:00:00 UTC" & #anonymousId ?~ AnonymousId "one-cookie"
          second = event account "two" "page_view" "two" "2026-07-03 00:00:00 UTC" & #sourceService ?~ "other"
          third = event account "three" "page_view" "three" "2026-07-09 00:00:00 UTC"
      insertEvents connection [first, identify, event account "one-repeat" "page_view" "one" "2026-07-02 12:00:00 UTC", second, third, event account "profile" "identify_once" "profile-only" "2026-07-07 00:00:00 UTC"]
      withPool $ \pool -> do
        let req = request account
        rolling <- users pool Rolling7 req
        byDay rolling Map.! "2026-07-07" `shouldBe` 2
        byDay rolling Map.! "2026-07-09" `shouldBe` 2
        let selected = req {Query.from = fromGregorian 2026 7 9, Query.to = fromGregorian 2026 7 10}
        amount <$> users pool CalendarWindow selected `shouldReturn` 1
        insertEvents connection [event account "before-lower" "page_view" "before" "2026-07-02 23:59:59.999 UTC", event account "at-upper" "page_view" "upper" "2026-07-10 00:00:00 UTC"]
        amount <$> users pool Rolling7 selected `shouldReturn` 2
        amount <$> users pool Rolling30 selected `shouldReturn` 4
        source <- input "source_service" Filter.FilterEq (Just (Aeson.String "other"))
        amount <$> users pool Rolling7 selected {Query.filters = [source]} `shouldReturn` 1
        grouped <- users pool Rolling7 selected {Query.groupBy = Just ["source_service", "country_code"]}
        groups "source_service" grouped `shouldBe` Map.fromList [(Just "a", 1), (Just "other", 1)]
        groups "country_code" grouped `shouldBe` Map.fromList [(Nothing, 2)]
        sticky <- metric (Query.runStickiness defaultRegistry pool selected)
        measurements sticky `shouldBe` Map.fromList [("daily_active", 1), ("rolling30_active", 4), ("ratio", 0.25)]
        filtered <- metric (Query.runStickiness defaultRegistry pool selected {Query.filters = [source]})
        measurements filtered `shouldBe` Map.fromList [("daily_active", 0), ("rolling30_active", 1), ("ratio", 0)]
        insertQueuedEvents connection [enrichedQueuedEvent emptyRequestContext (event account "bot" "page_view" "bot" "2026-07-09 01:00:00 UTC" & #context .~ KM.singleton "bot" (Aeson.Bool True))]
        amount <$> users pool Rolling7 selected `shouldReturn` 2
        amount <$> users pool Rolling7 selected {Query.includeBots = True} `shouldReturn` 3
        amount <$> users pool Rolling7 selected {Query.accountId = AccountId "activity-other"} `shouldReturn` 0
        zero <- metric (Query.runStickiness defaultRegistry pool selected {Query.accountId = AccountId "activity-empty"})
        measurements zero `shouldBe` Map.fromList [("daily_active", 0), ("rolling30_active", 0), ("ratio", 0)]

    it "distinguishes exact, cumulative, immature and retained-history cohorts with identical lookback filters" $ withClickHouse $ \connection -> do
      let account = "activity-retention"
      insertEvents
        connection
        [ event account "one-start" "page_view" "one" "2026-07-01 00:00:00 UTC",
          event account "one-return" "page_view" "one" "2026-07-05 00:00:00 UTC",
          event account "two-start" "page_view" "two" "2026-07-01 00:00:00 UTC",
          event account "old" "page_view" "old" "2026-06-30 00:00:00 UTC" & #sourceService ?~ "legacy",
          event account "old-window" "page_view" "old" "2026-07-01 00:00:00 UTC",
          event account "old-return" "page_view" "old" "2026-07-02 00:00:00 UTC",
          event account "recent-start" "page_view" "recent" "2026-07-08 00:00:00 UTC",
          event account "recent-return" "page_view" "recent" "2026-07-09 00:00:00 UTC",
          event account "youngest" "page_view" "youngest" "2026-07-09 00:00:00 UTC",
          event account "profile-only" "identify" "profile-only" "2026-07-01 00:00:00 UTC"
        ]
      withPool $ \pool -> do
        let req = (request account) {Query.to = fromGregorian 2026 7 10}
        exact <- retention pool RetentionOn WindowCohort req [1, 7]
        retentionValues exact `shouldBe` Map.fromList [(("2026-07-01", "0"), 3), (("2026-07-01", "1"), 1), (("2026-07-01", "7"), 0), (("2026-07-08", "0"), 1), (("2026-07-08", "1"), 1), (("2026-07-09", "0"), 1)]
        cumulative <- retention pool RetentionOnOrAfter LifetimeCohort req [1, 7]
        retentionValues cumulative `shouldBe` Map.fromList [(("2026-07-01", "0"), 2), (("2026-07-01", "1"), 1), (("2026-07-01", "7"), 0), (("2026-07-08", "0"), 1), (("2026-07-09", "0"), 1)]
        source <- input "source_service" Filter.FilterEq (Just (Aeson.String "a"))
        filtered <- retention pool RetentionOnOrAfter LifetimeCohort req {Query.filters = [source]} [1, 7]
        Map.lookup ("2026-07-01", "0") (retentionValues filtered) `shouldBe` Just 3
        grouped <- retention pool RetentionOn LifetimeCohort req {Query.groupBy = Just ["source_service", "country_code"]} [1, 7]
        groups "source_service" grouped `shouldBe` Map.fromList [(Just "a", 7)]
        groups "country_code" grouped `shouldBe` Map.fromList [(Nothing, 7)]
        -- Simulate expired retained evidence. This is a query-time cohort, not permanent first_seen state.
        command connection "ALTER TABLE analytics.events_raw DELETE WHERE account_id='activity-retention' AND event_id='old' SETTINGS mutations_sync=2"
        shifted <- retention pool RetentionOn LifetimeCohort req [1, 7]
        Map.lookup ("2026-07-01", "0") (retentionValues shifted) `shouldBe` Just 3

    it "partitions exact daily actives into nonnegative lifecycle statuses and ignores profile-only history" $ withClickHouse $ \connection -> do
      let account = "activity-lifecycle"
      insertEvents
        connection
        [ event account "new" "page_view" "new" "2026-07-02 00:00:00 UTC",
          event account "new-profile" "identify_once" "new" "2026-07-03 00:00:00 UTC",
          event account "return-one" "page_view" "return" "2026-07-01 00:00:00 UTC",
          event account "return-two" "page_view" "return" "2026-07-02 00:00:00 UTC",
          event account "return-three" "page_view" "return" "2026-07-03 00:00:00 UTC",
          event account "res-old" "page_view" "res" "2026-06-29 00:00:00 UTC" & #sourceService ?~ "legacy",
          event account "res-two" "page_view" "res" "2026-07-02 00:00:00 UTC",
          event account "res-four" "page_view" "res" "2026-07-04 00:00:00 UTC",
          event account "dormant" "page_view" "dormant" "2026-07-01 00:00:00 UTC",
          event account "ghost-old" "identify" "ghost" "2026-06-01 00:00:00 UTC",
          event account "ghost-update" "group" "ghost" "2026-07-02 00:00:00 UTC"
        ]
      withPool $ \pool -> do
        let req = (request account) {Query.from = fromGregorian 2026 7 2, Query.to = fromGregorian 2026 7 5}
        lifecycle <- metric (Query.runLifecycle defaultRegistry pool req)
        statuses lifecycle `shouldBe` Map.fromList [(("2026-07-02", "new"), 1), (("2026-07-02", "returning"), 1), (("2026-07-02", "resurrecting"), 1), (("2026-07-02", "dormant"), 1), (("2026-07-03", "new"), 0), (("2026-07-03", "returning"), 1), (("2026-07-03", "resurrecting"), 0), (("2026-07-03", "dormant"), 2), (("2026-07-04", "new"), 0), (("2026-07-04", "returning"), 0), (("2026-07-04", "resurrecting"), 1), (("2026-07-04", "dormant"), 1)]
        active <- users pool CalendarWindow req
        let partition = Map.fromListWith (+) [(day, value) | ((day, status), value) <- Map.toList (statuses lifecycle), status /= "dormant"]
        partition `shouldBe` byDay active
        source <- input "source_service" Filter.FilterEq (Just (Aeson.String "a"))
        filtered <- metric (Query.runLifecycle defaultRegistry pool req {Query.filters = [source]})
        Map.lookup ("2026-07-02", "new") (statuses filtered) `shouldBe` Just 2
        Map.lookup ("2026-07-02", "resurrecting") (statuses filtered) `shouldBe` Just 0
        zero <- metric (Query.runLifecycle defaultRegistry pool req {Query.accountId = AccountId "activity-empty"})
        length (zero ^. #points) `shouldBe` 12
        amount zero `shouldBe` 0

    it "keeps complete-or-error point bounds and classifies native memory exhaustion on every new family" $ withClickHouse $ \connection -> do
      withPool $ \pool -> do
        let req account = (request account) {Query.to = fromGregorian 2026 7 2, Query.groupBy = Just ["source_service"]}
        seedCap connection "rolling-cap" 0 10000
        rolling <- users pool Rolling7 (req "rolling-cap")
        length (rolling ^. #points) `shouldBe` 10000
        seedCap connection "rolling-cap" 10000 1
        runEff (Query.runUsers defaultRegistry pool Rolling7 (req "rolling-cap")) `shouldReturn` Left Query.MetricResultTooLarge
        seedCap connection "sticky-cap" 0 3333
        sticky <- metric (Query.runStickiness defaultRegistry pool (req "sticky-cap"))
        length (sticky ^. #points) `shouldBe` 9999
        seedCap connection "sticky-cap" 3333 1
        runEff (Query.runStickiness defaultRegistry pool (req "sticky-cap")) `shouldReturn` Left Query.MetricResultTooLarge
        seedCap connection "lifecycle-cap" 0 2500
        lifecycle <- metric (Query.runLifecycle defaultRegistry pool (req "lifecycle-cap"))
        length (lifecycle ^. #points) `shouldBe` 10000
        seedCap connection "lifecycle-cap" 2500 1
        runEff (Query.runLifecycle defaultRegistry pool (req "lifecycle-cap")) `shouldReturn` Left Query.MetricResultTooLarge
        seedCap connection "retention-cap" 0 5000
        let retained = (req "retention-cap") {Query.to = fromGregorian 2026 7 3}
        kept <- retention pool RetentionOn WindowCohort retained [1]
        length (kept ^. #points) `shouldBe` 10000
        seedCap connection "retention-cap" 5000 1
        runEff (Query.runRetentionMetric defaultRegistry pool RetentionOn WindowCohort retained [1]) `shouldReturn` Left Query.MetricResultTooLarge
      cfg <- clickHouseConfigFromConfig <$> requireConfig
      bracket (newQueryPoolWithLimits cfg 1 (MetricsQueryLimits 30 1)) closeQueryPool $ \pool -> do
        let req = request "rolling-cap"
        outcomes <- sequence [runEff (Query.runUsers defaultRegistry pool Rolling7 req), runEff (Query.runStickiness defaultRegistry pool req), runEff (Query.runLifecycle defaultRegistry pool req), runEff (Query.runRetentionMetric defaultRegistry pool RetentionOn WindowCohort req [1])]
        forM_ outcomes (`shouldBe` Left Query.QueryResourceLimit)

request :: Text -> Query.QueryRequest
request account = Query.QueryRequest (AccountId account) (fromGregorian 2026 7 1) (fromGregorian 2026 7 11) Nothing (Just Day) [] False

event :: Text -> Text -> Text -> Text -> String -> AnalyticsEvent
event account eid name user timestamp =
  baseEvent (EventId eid) (EventName name) Web (read timestamp) (read timestamp)
    & #accountId
    ?~ AccountId account
    & #userId
    ?~ UserId user
    & #sourceService
    ?~ "a"

withPool :: (QueryPool -> IO a) -> IO a
withPool action = do
  cfg <- clickHouseConfigFromConfig <$> requireConfig
  bracket (newQueryPool cfg 1) closeQueryPool action

metric :: Eff '[IOE] (Either Query.QueryExecutionError MetricResult) -> IO MetricResult
metric action = runEff action >>= either (fail . show) pure

users :: QueryPool -> UserWindow -> Query.QueryRequest -> IO MetricResult
users pool window req = metric (Query.runUsers defaultRegistry pool window req)

retention :: QueryPool -> RetentionMode -> CohortMode -> Query.QueryRequest -> [Int] -> IO MetricResult
retention pool mode cohort req offsets = metric (Query.runRetentionMetric defaultRegistry pool mode cohort req offsets)

amount :: MetricResult -> Double
amount result = sum [point ^. #value | point <- result ^. #points]

group :: Text -> MetricPoint -> Maybe Text
group key point = fromMaybe Nothing (Map.lookup key (point ^. #group))

groups :: Text -> MetricResult -> Map.Map (Maybe Text) Double
groups key result = Map.fromListWith (+) [(group key point, point ^. #value) | point <- result ^. #points]

byDay :: MetricResult -> Map.Map Text Double
byDay result = Map.fromListWith (+) [(fromMaybe "" (point ^. #bucket), point ^. #value) | point <- result ^. #points]

measurements :: MetricResult -> Map.Map Text Double
measurements result = Map.fromList [(fromMaybe "" (group "measure" point), point ^. #value) | point <- result ^. #points]

retentionValues :: MetricResult -> Map.Map (Text, Text) Double
retentionValues result = Map.fromList [((fromMaybe "" (group "cohort" point), fromMaybe "" (group "offset" point)), point ^. #value) | point <- result ^. #points]

statuses :: MetricResult -> Map.Map (Text, Text) Double
statuses result = Map.fromList [((fromMaybe "" (point ^. #bucket), fromMaybe "" (group "status" point)), point ^. #value) | point <- result ^. #points]

input :: Text -> Filter.FilterOp -> Maybe Aeson.Value -> IO Filter.MetricFilter
input dimension operator value = either (fail . Text.unpack) pure (Filter.mkMetricFilter dimension operator value)

seedCap :: Connection -> Text -> Int -> Int -> IO ()
seedCap connection account offset count = command connection (fromString ("INSERT INTO analytics.events_raw(event_id,event_name,source,source_service,occurred_at,received_at,user_id,account_id,properties,context) SELECT concat('cap-',toString(number)),'page_view','web',concat('svc',toString(number)),toDateTime64('2026-07-01',3,'UTC'),toDateTime64('2026-07-01',3,'UTC'),concat('user',toString(number)),'" <> Text.unpack account <> "','{}','{}' FROM numbers(" <> show offset <> "," <> show count <> ")"))
