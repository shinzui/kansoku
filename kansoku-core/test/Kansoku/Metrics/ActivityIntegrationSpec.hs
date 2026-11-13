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
import Kansoku.Cohort.Query qualified as Cohort
import Kansoku.Event
import Kansoku.Ingest.QueuedEvent (enrichedQueuedEvent)
import Kansoku.Ingest.RequestContext (emptyRequestContext)
import Kansoku.Metrics.Api (CohortMode (..), MetricPoint, MetricResult, RetentionMode (..), RetentionPeriod (..), TimeGrain (..), UserWindow (..))
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
          req = (request "unused") {Query.timeGrain = Just NoTimeBucket}
      results <-
        sequence
          [ runEff (Query.runUsers defaultRegistry unused Rolling30 req),
            runEff (Query.runStickiness defaultRegistry unused req),
            runEff (Query.runLifecycle defaultRegistry unused req),
            runEff (Query.runRetentionMetric defaultRegistry unused RetentionOn WindowCohort req [1])
          ]
      forM_ results $ \result -> result `shouldSatisfy` (\case Left (Query.QueryLimitFailure failure) -> failure ^. #limitCode == "invalid_time_grain"; _ -> False)

    it "rejects invalid retention options consistently in builders and direct executors before storage" $ do
      side <- either (fail . Text.unpack) pure (Filter.parseMetricFilter "country_code:eq:GB|user:plan:eq:pro")
      filter <- input "country_code" Filter.FilterEq (Just (Aeson.String "GB"))
      large <- either (fail . Text.unpack) pure (Filter.parseMetricFilter (Text.replicate 8300 " " <> "{\"dimension\":\"country_code\",\"op\":\"eq\",\"value\":\"GB\"}"))
      let unused = error "retention option validation acquired storage"
          req = (request "unused") {Query.from = fromGregorian 2026 7 6, Query.to = fromGregorian 2026 7 27}
          defaults = Query.defaultRetentionOptions
          cases = [(defaults {Query.startEvent = Just ""}, [1], "invalid_retention_event"), (defaults {Query.returnEvent = Just "a,b"}, [1], "invalid_retention_event"), (defaults {Query.period = RetentionWeek}, [53], "invalid_retention_days"), (defaults {Query.period = RetentionMonth}, [1], "invalid_retention_period"), (defaults {Query.startFilters = [side]}, [1], "invalid_retention_filter"), (defaults {Query.startFilters = replicate 4 filter, Query.returnFilters = replicate 5 filter}, [1], "invalid_filter"), (defaults {Query.startFilters = [large], Query.returnFilters = [large]}, [1], "invalid_filter")]
      forM_ cases $ \(options, offsets, code) -> do
        result <- runEff (Query.runRetentionMetricWithOptions defaultRegistry unused RetentionOn WindowCohort options req offsets)
        result `shouldSatisfy` (\case Left (Query.QueryLimitFailure failure) -> failure ^. #limitCode == code; _ -> False)
        Query.buildRetentionMetricSQLWithOptions defaultRegistry RetentionOn WindowCohort options req offsets `shouldSatisfy` either ((== code) . Query.queryCompileErrorCode) (const False)

      unknown <- input "prop:not_declared" Filter.FilterEq (Just (Aeson.String "x"))
      wrongType <- input "prop:amount" Filter.FilterEq (Just (Aeson.String "10"))
      forM_ [unknown, wrongType] $ \predicate -> do
        let options = defaults {Query.startEvent = Just "payment_completed", Query.startFilters = [predicate]}
        result <- runEff (Query.runRetentionMetricWithOptions defaultRegistry unused RetentionOn WindowCohort options req [1])
        result `shouldSatisfy` (\case Left (Query.QueryCompileFailure failure) -> Query.queryCompileErrorCode failure == "invalid_filter"; _ -> False)
      let schema name kind = EventSchema (EventName name) 1 "retention type fixture" [PropertySpec "dimension" kind False Nothing Nothing]
          registry = registerSchema (schema "typed_start" PTNumber) (registerSchema (schema "typed_return" PTString) defaultRegistry)
          options = defaults {Query.startEvent = Just "typed_start", Query.returnEvent = Just "typed_return"}
      Query.buildRetentionMetricSQLWithOptions registry RetentionOn WindowCohort options req {Query.groupBy = Just ["prop:dimension"]} [1] `shouldSatisfy` either ((== "invalid_group_by") . Query.queryCompileErrorCode) (const False)

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

    it "counts independent weekly starts and returns exactly with retained-history and full-horizon maturity" $ withClickHouse $ \connection -> do
      let account = "calendar-week"
          signup user day = event account (user <> "-start-" <> Text.pack (show day)) "signup_completed" user ("2026-07-" <> day <> " 00:00:00 UTC")
          document user day = event account (user <> "-return-" <> Text.pack (show day)) "document_created" user ("2026-07-" <> day <> " 00:00:00 UTC")
      insertEvents connection ([signup user day | (user, day) <- [("A", "06"), ("B", "06"), ("C", "12"), ("D", "13"), ("old", "05"), ("old", "07"), ("F", "26")]] <> [document user day | (user, day) <- [("A", "13"), ("A", "15"), ("A", "19"), ("A", "20"), ("C", "20"), ("D", "20"), ("E", "14"), ("old", "14")]])
      withPool $ \pool -> do
        let req = (request account) {Query.from = fromGregorian 2026 7 6, Query.to = fromGregorian 2026 7 27}
            options = Query.RetentionOptions RetentionWeek (Just "signup_completed") (Just "document_created") [] []
            query mode cohort request = retentionValues <$> metric (Query.runRetentionMetricWithOptions defaultRegistry pool mode cohort options request [1, 2])
            exact = Map.fromList [(("2026-07-06", "0"), 4), (("2026-07-06", "1"), 2), (("2026-07-06", "2"), 2), (("2026-07-13", "0"), 1), (("2026-07-13", "1"), 1), (("2026-07-20", "0"), 1)]
        query RetentionOn WindowCohort req `shouldReturn` exact
        query RetentionOn LifetimeCohort req `shouldReturn` Map.insert ("2026-07-06", "0") 3 (Map.insert ("2026-07-06", "1") 1 exact)
        query RetentionOnOrAfter WindowCohort req `shouldReturn` Map.delete ("2026-07-13", "1") (Map.insert ("2026-07-06", "1") 3 exact)
        let partial = req {Query.to = fromGregorian 2026 7 26}
        query RetentionOn WindowCohort partial `shouldReturn` Map.delete ("2026-07-13", "1") (Map.delete ("2026-07-20", "0") (Map.delete ("2026-07-06", "2") exact))
        query RetentionOnOrAfter WindowCohort partial `shouldReturn` Map.fromList [(("2026-07-06", "0"), 4), (("2026-07-13", "0"), 1)]

    it "uses actual leap calendar months and omits incomplete February returns" $ withClickHouse $ \connection -> do
      let account = "calendar-month"
      insertEvents connection [event account "M-start" "signup_completed" "M" "2024-01-31 23:59:59.999 UTC", event account "N-start" "signup_completed" "N" "2024-01-01 00:00:00 UTC", event account "P-start" "signup_completed" "P" "2024-02-29 00:00:00 UTC", event account "M-return1" "document_created" "M" "2024-02-01 00:00:00 UTC", event account "M-return2" "document_created" "M" "2024-02-29 23:59:59.999 UTC", event account "upper" "signup_completed" "upper" "2024-03-01 00:00:00 UTC"]
      withPool $ \pool -> do
        let req = (request account) {Query.from = fromGregorian 2024 1 1, Query.to = fromGregorian 2024 3 1}
            options = Query.RetentionOptions RetentionMonth (Just "signup_completed") (Just "document_created") [] []
            query request = retentionValues <$> metric (Query.runRetentionMetricWithOptions defaultRegistry pool RetentionOn WindowCohort options request [1])
        query req `shouldReturn` Map.fromList [(("2024-01-01", "0"), 2), (("2024-01-01", "1"), 1), (("2024-02-01", "0"), 1)]
        query req {Query.to = fromGregorian 2024 2 29} `shouldReturn` Map.singleton ("2024-01-01", "0") 2

    it "keeps side operands independent, preserves nullable group matches and defaults each event selection" $ withClickHouse $ \connection -> do
      let account = "calendar-selection"
          start user = event account (user <> "-start") "signup_completed" user "2026-07-06 00:00:00 UTC"
          returned user source = event account (user <> "-return") "document_created" user "2026-07-13 00:00:00 UTC" & #sourceService ?~ source
      insertEvents connection [start "A", start "B", returned "A" "b", returned "B" "a", returned "C" "a", event account "unrelated-old" "page_view" "A" "2026-06-01 00:00:00 UTC", event account "A-repeat" "signup_completed" "A" "2026-07-13 00:00:00 UTC"]
      sourceA <- input "source_service" Filter.FilterEq (Just (Aeson.String "a"))
      sourceB <- input "source_service" Filter.FilterEq (Just (Aeson.String "b"))
      withPool $ \pool -> do
        let req = (request account) {Query.from = fromGregorian 2026 7 6, Query.to = fromGregorian 2026 7 20}
            options = Query.RetentionOptions RetentionWeek (Just "signup_completed") (Just "document_created") [sourceA] [sourceB]
            query opts request = metric (Query.runRetentionMetricWithOptions defaultRegistry pool RetentionOn LifetimeCohort opts request [1])
            expected n = Map.fromList [(("2026-07-06", "0"), 2), (("2026-07-06", "1"), n)]
        retentionValues <$> query options req `shouldReturn` expected 1
        retentionValues <$> query options req {Query.filters = [sourceA]} `shouldReturn` expected 0
        retentionValues <$> query options req {Query.groupBy = Just ["source_service"]} `shouldReturn` expected 0
        grouped <- query options req {Query.groupBy = Just ["source_service", "country_code"]}
        retentionValues grouped `shouldBe` expected 0
        groups "country_code" grouped `shouldBe` Map.singleton Nothing 2
        retentionValues <$> query options req {Query.groupBy = Just ["event_name"]} `shouldReturn` expected 0
        retentionValues <$> query options {Query.returnEvent = Just "unknown_valid"} req `shouldReturn` expected 0
        amount <$> query options {Query.startEvent = Just "unknown_valid"} req `shouldReturn` 0
        retentionValues <$> query options {Query.returnEvent = Nothing} req `shouldReturn` expected 1
        retentionValues <$> query options {Query.startEvent = Nothing} req `shouldReturn` Map.fromList [(("2026-07-06", "0"), 1), (("2026-07-06", "1"), 0), (("2026-07-13", "0"), 1)]
        contradictory <- either (fail . Text.unpack) pure (Filter.parseMetricFilter "event_name:eq:page_view|event_name:eq:feature_used")
        amount <$> query options {Query.startFilters = [contradictory]} req `shouldReturn` 0
        let daily = req {Query.from = fromGregorian 2026 7 6, Query.to = fromGregorian 2026 7 20}
        old <- retention pool RetentionOn WindowCohort daily [1, 7]
        explicit <- metric (Query.runRetentionMetricWithOptions defaultRegistry pool RetentionOn WindowCohort Query.defaultRetentionOptions daily [1, 7])
        explicit `shouldBe` old

    it "binds independent governed numeric, boolean and missing-property side filters" $ withClickHouse $ \connection -> do
      let account = "calendar-properties"
          start user props = event account (user <> "-start") "payment_completed" user "2026-07-06 00:00:00 UTC" & #properties .~ KM.fromList props
          returned user props = event account (user <> "-return") "client_error" user "2026-07-13 00:00:00 UTC" & #properties .~ KM.fromList props
      insertEvents connection [start "A" [("amount", Aeson.Number 10)], start "B" [("amount", Aeson.Number 2)], start "missing" [], returned "A" [("handled", Aeson.Bool True), ("message", Aeson.String "chosen")], returned "B" [("handled", Aeson.Bool False)], returned "missing" [("handled", Aeson.Bool True)]]
      numeric <- input "prop:amount" Filter.FilterGt (Just (Aeson.Number 5))
      boolean <- input "prop:handled" Filter.FilterEq (Just (Aeson.Bool True))
      string <- either (fail . Text.unpack) pure (Filter.parseMetricFilter "prop:message:eq:absent|prop:message:eq:chosen")
      withPool $ \pool -> do
        let req = (request account) {Query.from = fromGregorian 2026 7 6, Query.to = fromGregorian 2026 7 20}
            options = Query.RetentionOptions RetentionWeek (Just "payment_completed") (Just "client_error") [numeric] [boolean, string]
        result <- metric (Query.runRetentionMetricWithOptions defaultRegistry pool RetentionOn WindowCohort options req [1])
        retentionValues result `shouldBe` Map.fromList [(("2026-07-06", "0"), 1), (("2026-07-06", "1"), 1)]

    it "aligns Monday and calendar month rollover without approximating elapsed days" $ withClickHouse $ \connection -> do
      forM_ [("week-year", RetentionWeek, "2020-12-28", "2021-01-03 23:59:59.999 UTC", "2021-01-04 00:00:00 UTC", "2021-01-11"), ("month28", RetentionMonth, "2023-01-01", "2023-01-31 23:59:59.999 UTC", "2023-02-28 23:59:59.999 UTC", "2023-03-01"), ("month30", RetentionMonth, "2024-03-01", "2024-03-31 23:59:59.999 UTC", "2024-04-30 23:59:59.999 UTC", "2024-05-01"), ("month-year31", RetentionMonth, "2023-12-01", "2023-12-31 23:59:59.999 UTC", "2024-01-31 23:59:59.999 UTC", "2024-02-01")] $ \(account, period, lo, start, returned, hi) -> do
        insertEvents connection [event account "start" "signup_completed" "A" start, event account "return" "document_created" "A" returned, event account "upper" "signup_completed" "upper" (hi <> " 00:00:00 UTC")]
        withPool $ \pool -> do
          let req = (request account) {Query.from = read lo, Query.to = read hi}
              options = Query.RetentionOptions period (Just "signup_completed") (Just "document_created") [] []
          result <- metric (Query.runRetentionMetricWithOptions defaultRegistry pool RetentionOn WindowCohort options req [1])
          retentionValues result `shouldBe` Map.fromList [((Text.pack lo, "0"), 1), ((Text.pack lo, "1"), 1)]

    it "keeps replay, stitched identities, bot rows, current traits and shared membership on both weekly sides" $ withClickHouse $ \connection -> do
      let account = "calendar-identities"
          rows = [event account "start" "signup_completed" "A" "2026-07-06 00:00:00 UTC" & #userId .~ Nothing & #anonymousId ?~ AnonymousId "cookie", event account "identify" "identify" "A" "2026-07-12 00:00:00 UTC" & #schemaVersion ?~ 2 & #anonymousId ?~ AnonymousId "cookie" & #properties .~ KM.singleton "plan" (Aeson.String "pro"), event account "return" "document_created" "A" "2026-07-13 00:00:00 UTC", event account "profile-only" "identify" "profile" "2026-07-06 00:00:00 UTC", event "foreign" "foreign-start" "signup_completed" "foreign" "2026-07-06 00:00:00 UTC"]
          bot eid name stamp = enrichedQueuedEvent emptyRequestContext (event account eid name "bot" stamp & #context .~ KM.singleton "bot" (Aeson.Bool True))
      insertEvents connection (reverse rows <> rows)
      insertQueuedEvents connection [bot "bot-start" "signup_completed" "2026-07-06 00:00:00 UTC", bot "bot-return" "document_created" "2026-07-13 00:00:00 UTC"]
      pro <- either (fail . Text.unpack) pure (Filter.parseMetricFilter "user:plan:eq:pro|user:plan:eq:enterprise")
      member <- input "cohort" Filter.FilterEq (Just (Aeson.String "calendar-member"))
      withPool $ \pool -> do
        let req = (request account) {Query.from = fromGregorian 2026 7 6, Query.to = fromGregorian 2026 7 20}
            options = Query.RetentionOptions RetentionWeek (Just "signup_completed") (Just "document_created") [] []
            query request = retentionValues <$> metric (Query.runRetentionMetricWithOptions defaultRegistry pool RetentionOn WindowCohort options request [1])
            expected n = Map.fromList [(("2026-07-06", "0"), n), (("2026-07-06", "1"), n)]
        query req `shouldReturn` expected 1
        query req {Query.includeBots = True} `shouldReturn` expected 2
        query req {Query.filters = [pro], Query.groupBy = Just ["user:plan"]} `shouldReturn` expected 1
        query req {Query.filters = [member], Query.cohorts = [("calendar-member", Cohort.Membership "canonical_user='user:A'" [] (fromGregorian 2026 1 1))]} `shouldReturn` expected 1
        query req {Query.accountId = AccountId "empty"} `shouldReturn` Map.empty
        insertEvents connection [event account "new-plan" "identify" "A" "2026-07-21 00:00:00 UTC" & #schemaVersion ?~ 2 & #properties .~ KM.singleton "plan" (Aeson.String "free")]
        query req {Query.filters = [pro]} `shouldReturn` Map.empty

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
        seedCap connection "weekly-retention-cap" 0 5000
        let weekly = (req "weekly-retention-cap") {Query.from = fromGregorian 2026 6 29, Query.to = fromGregorian 2026 7 13}
            options = Query.RetentionOptions RetentionWeek (Just "page_view") (Just "document_created") [] []
        keptWeekly <- metric (Query.runRetentionMetricWithOptions defaultRegistry pool RetentionOn WindowCohort options weekly [1])
        length (keptWeekly ^. #points) `shouldBe` 10000
        seedCap connection "weekly-retention-cap" 5000 1
        runEff (Query.runRetentionMetricWithOptions defaultRegistry pool RetentionOn WindowCohort options weekly [1]) `shouldReturn` Left Query.MetricResultTooLarge
      cfg <- clickHouseConfigFromConfig <$> requireConfig
      bracket (newQueryPoolWithLimits cfg 1 (MetricsQueryLimits 30 1)) closeQueryPool $ \pool -> do
        let req = request "rolling-cap"
        outcomes <- sequence [runEff (Query.runUsers defaultRegistry pool Rolling7 req), runEff (Query.runStickiness defaultRegistry pool req), runEff (Query.runLifecycle defaultRegistry pool req), runEff (Query.runRetentionMetric defaultRegistry pool RetentionOn WindowCohort req [1])]
        forM_ outcomes (`shouldBe` Left Query.QueryResourceLimit)
        let weekly = req {Query.from = fromGregorian 2026 6 29, Query.to = fromGregorian 2026 7 13}
            options = Query.RetentionOptions RetentionWeek (Just "page_view") (Just "document_created") [] []
        runEff (Query.runRetentionMetricWithOptions defaultRegistry pool RetentionOn WindowCohort options weekly [1]) `shouldReturn` Left Query.QueryResourceLimit

request :: Text -> Query.QueryRequest
request account = Query.QueryRequest (AccountId account) (fromGregorian 2026 7 1) (fromGregorian 2026 7 11) Nothing (Just Day) [] [] False False False

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
