module Kansoku.Metrics.SessionIntegrationSpec (spec) where

import ClickHaskell (ChString, ClickHaskell, Column, Connection, Select, command, select, unsafeMkSelect)
import Control.Exception (bracket)
import Control.Monad (forM_)
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Data.String (fromString)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time (fromGregorian)
import Effectful (runEff)
import Kansoku.Admin.ClickHouse (rebuildDerived)
import Kansoku.ClickHouse
import Kansoku.ClickHouseTestSupport
import Kansoku.Event
import Kansoku.Ingest.QueuedEvent (QueuedEvent, enrichedQueuedEvent)
import Kansoku.Ingest.RequestContext (IngestRequestContext (..))
import Kansoku.Metrics.Api (AcquisitionMeasure (..), MetricResult, SessionMeasure (..), TimeGrain (..))
import Kansoku.Metrics.Filter qualified as Filter
import Kansoku.Metrics.Query qualified as Query
import Kansoku.Metrics.Query.Session (materializedSessionProjection, sessionProjection)
import Kansoku.Prelude
import Test.Hspec

spec :: Spec
spec = describe "Kansoku.Sessions native" $ do
  it "selects a last-event match without shortening its whole session" $ withClickHouse $ \connection -> do
    insertQueuedEvents
      connection
      [ makeFor "sessions-contains-smoke" "contains-first" "page_view" "2026-07-01 12:00:00 UTC" "contains" "/entry",
        makeFor "sessions-contains-smoke" "contains-second" "page_view" "2026-07-01 12:00:20 UTC" "contains" "/second",
        makeFor "sessions-contains-smoke" "contains-last" "client_error" "2026-07-01 12:01:00 UTC" "contains" "/error"
      ]
    withPool $ \pool -> do
      let selected measure = runEff (Query.runSessionMetricWithContains pool measure (Just ["client_error"]) request {Query.accountId = AccountId "sessions-contains-smoke"}) >>= either (fail . show) pure
      amount <$> selected SessionCount `shouldReturn` 1
      amount <$> selected SessionAverageDuration `shouldReturn` 60
      amount <$> selected SessionBounceRate `shouldReturn` 0

  it "selects whole any-of populations for every measure, grouping and grain without replay weighting" $ withClickHouse $ \connection -> do
    let fixture =
          [ makeFor "sessions-contains-population" "contains-a0" "page_view" "2026-07-01 12:00:00 UTC" "a" "/error" & #enrichment . #channel .~ "email",
            makeFor "sessions-contains-population" "contains-a1" "page_view" "2026-07-01 12:00:20 UTC" "a" "/second",
            makeFor "sessions-contains-population" "contains-a2" "client_error" "2026-07-01 12:01:00 UTC" "a" "/later" & #enrichment . #channel .~ "paid_search",
            makeFor "sessions-contains-population" "contains-b0" "page_view" "2026-07-01 13:00:00 UTC" "b" "/quiet" & #enrichment . #channel .~ "email",
            makeFor "sessions-contains-population" "contains-b1" "page_leave" "2026-07-01 13:00:30 UTC" "b" "/quiet",
            makeFor "sessions-contains-population" "contains-c0" "page_view" "2026-07-01 14:00:00 UTC" "c" "/quiet",
            makeFor "sessions-contains-population" "contains-nosession" "client_error" "2026-07-01 15:00:00 UTC" "" "/ignored",
            makeFor "sessions-contains-population" "contains-server" "client_error" "2026-07-01 15:00:00 UTC" "" "/ignored" & #event . #source .~ Service
          ]
        req = request {Query.accountId = AccountId "sessions-contains-population", Query.to = fromGregorian 2026 7 2, Query.timeGrain = Just NoTimeBucket}
    insertQueuedEvents connection fixture
    withPool $ \pool -> do
      let report names measure selected = runEff (Query.runSessionMetricWithContains pool measure names selected) >>= either (fail . show) pure
          expect names count duration bounce = do
            amount <$> report names SessionCount req `shouldReturn` count
            amount <$> report names SessionAverageDuration req `shouldReturn` duration
            actual <- amount <$> report names SessionBounceRate req
            actual `shouldSatisfy` (\value -> abs (value - bounce) < 1e-9)
          verify = do
            expect Nothing 3 30 (2 / 3)
            expect (Just ["client_error"]) 1 60 0
            expect (Just ["client_error", "page_leave"]) 2 45 0.5
            expect (Just ["absent_event"]) 0 0 0
      verify
      amount <$> report (Just [" client_error ", "client_error"]) SessionCount req `shouldReturn` 1
      empty <- report (Just ["absent_event"]) SessionCount req {Query.groupBy = Just ["entry_page"]}
      empty ^. #points `shouldBe` []
      grouped <- report (Just ["client_error", "page_leave"]) SessionCount req {Query.groupBy = Just ["entry_page"]}
      groups "entry_page" grouped `shouldBe` Map.fromList [(Just "/error", 1), (Just "/quiet", 1)]
      attributed <- report (Just ["client_error"]) SessionCount req {Query.groupBy = Just ["entry_page", "channel"]}
      map (view #group) (attributed ^. #points) `shouldBe` [Map.fromList [("entry_page", Just "/error"), ("channel", Just "email")]]
      forM_ [("email", 2), ("direct", 0)] $ \(channel, expected) -> do
        selected <- input "channel" Filter.FilterEq (Just (Aeson.String channel))
        amount <$> report (Just ["client_error", "page_leave"]) SessionCount req {Query.filters = [selected]} `shouldReturn` expected
      forM_ [Nothing, Just Hour, Just Day, Just Week, Just Month, Just NoTimeBucket] $ \grain -> do
        forM_ [(SessionCount, 1), (SessionBounceRate, 0), (SessionAverageDuration, 60)] $ \(measure, expected) -> do
          amount <$> report (Just ["client_error"]) measure req {Query.timeGrain = grain} `shouldReturn` expected
        result <- report (Just ["client_error"]) SessionCount req {Query.timeGrain = grain}
        [bucket | (bucket, value) <- buckets result, value /= 0] `shouldBe` case grain of
          Just Hour -> [Just "2026-07-01 12:00:00"]
          Just Week -> [Just "2026-06-29"]
          Just Month -> [Just "2026-07-01"]
          Just NoTimeBucket -> [Nothing]
          _ -> [Just "2026-07-01"]
      insertQueuedEvents connection (reverse fixture)
      forM_ fixture (insertQueuedEvents connection . pure)
      -- A second distinct matching event at the same timestamp cannot weight a visit.
      insertQueuedEvents connection [makeFor "sessions-contains-population" "contains-a3" "client_error" "2026-07-01 12:01:00 UTC" "a" "/other"]
      verify
      canonical <- snapshotFor "sessions-contains-population" connection (sessionProjection "analytics.events_canonical" False)
      snapshotFor "sessions-contains-population" connection materializedSessionProjection `shouldReturn` canonical
      rebuildDerived connection
      verify

  it "isolates witness keys and keeps bot and zero-page session rules" $ withClickHouse $ \connection -> do
    let page eid sid = makeFor "sessions-contains-keys" eid "page_view" "2026-07-01 12:00:00 UTC" sid "/page"
        witness eid sid = makeFor "sessions-contains-keys" eid "client_error" "2026-07-01 12:00:10 UTC" sid "/error"
        req = request {Query.accountId = AccountId "sessions-contains-keys", Query.to = fromGregorian 2026 7 2, Query.timeGrain = Just NoTimeBucket}
    insertQueuedEvents
      connection
      [ page "key-page" "collision",
        witness "key-nonweb" "collision" & #event . #source .~ Service,
        witness "key-account" "collision" & #event . #accountId ?~ AccountId "sessions-contains-other",
        witness "key-service" "collision" & #event . #sourceService ?~ "b",
        page "bot-clean-page" "bot-clean",
        witness "bot-clean-error" "bot-clean",
        makeFor "sessions-contains-keys" "bot-other" "page_leave" "2026-07-01 12:00:20 UTC" "bot-clean" "" & #enrichment . #isBot .~ True,
        page "bot-witness-page" "bot-witness",
        witness "bot-witness-error" "bot-witness" & #enrichment . #isBot .~ True,
        witness "zero-page-error" "zero-page"
      ]
    service <- input "source_service" Filter.FilterEq (Just (Aeson.String "a"))
    withPool $ \pool -> do
      let report measure selected = runEff (Query.runSessionMetricWithContains pool measure (Just ["client_error"]) selected) >>= either (fail . show) pure
          selected = req {Query.filters = [service]}
      amount <$> report SessionCount selected `shouldReturn` 1
      amount <$> report SessionBounceRate selected `shouldReturn` 0
      amount <$> report SessionAverageDuration selected `shouldReturn` 0
      amount <$> report SessionCount selected {Query.includeBots = True} `shouldReturn` 3
      collision <- input "entry_page" Filter.FilterEq (Just (Aeson.String "/page"))
      amount <$> report SessionCount selected {Query.filters = [service, collision]} `shouldReturn` 0
      -- The same textual key in another source service is its own matching session.
      amount <$> report SessionCount req `shouldReturn` 2

  it "matches retained history beyond the interval and moves late earlier starts" $ withClickHouse $ \connection -> do
    let page = makeFor "sessions-contains-midnight" "contains-midnight-page" "page_view" "2026-07-01 23:59:00 UTC" "midnight" "/entry"
        err = makeFor "sessions-contains-midnight" "contains-midnight-error" "client_error" "2026-07-02 00:01:00 UTC" "midnight" "/later"
        firstDay = request {Query.accountId = AccountId "sessions-contains-midnight", Query.to = fromGregorian 2026 7 2, Query.timeGrain = Just NoTimeBucket}
        nextDay = firstDay {Query.from = fromGregorian 2026 7 2, Query.to = fromGregorian 2026 7 3}
    insertQueuedEvents connection [page]
    insertQueuedEvents connection [err]
    withPool $ \pool -> do
      let report measure selected = runEff (Query.runSessionMetricWithContains pool measure (Just ["client_error"]) selected) >>= either (fail . show) pure
      amount <$> report SessionCount firstDay `shouldReturn` 1
      amount <$> report SessionAverageDuration firstDay `shouldReturn` 120
      amount <$> report SessionCount nextDay `shouldReturn` 0
      insertQueuedEvents connection [err, page]
      amount <$> report SessionAverageDuration firstDay `shouldReturn` 120
      insertQueuedEvents connection [makeFor "sessions-contains-midnight" "contains-midnight-earlier" "session_start" "2026-06-30 23:58:00 UTC" "midnight" ""]
      amount <$> report SessionCount firstDay `shouldReturn` 0
      moved <- report SessionCount firstDay {Query.from = fromGregorian 2026 6 30, Query.timeGrain = Just Day}
      buckets moved `shouldBe` [(Just "2026-06-30", 1), (Just "2026-07-01", 0)]
      canonical <- snapshotFor "sessions-contains-midnight" connection (sessionProjection "analytics.events_canonical" False)
      snapshotFor "sessions-contains-midnight" connection materializedSessionProjection `shouldReturn` canonical

  it "merges complete retained state across batches, rebatches and canonical rebuilds" $ withClickHouse $ \connection -> do
    seed connection
    canonical <- snapshot connection (sessionProjection "analytics.events_canonical" False)
    materialized <- snapshot connection materializedSessionProjection
    materialized `shouldBe` canonical
    length materialized `shouldBe` 10 -- includes pre-window and bot sessions, never missing IDs/non-web/other-account
    withPool $ \pool -> do
      initial <- sessions pool SessionCount request
      buckets initial `shouldBe` [(Just "2026-07-01", 7), (Just "2026-07-02", 1)]
      insertQueuedEvents connection (reverse rows)
      forM_ rows (insertQueuedEvents connection . pure)
      snapshot connection materializedSessionProjection `shouldReturn` canonical
      sessions pool SessionCount request `shouldReturn` initial
      rebuildDerived connection
      snapshot connection materializedSessionProjection `shouldReturn` canonical
      sessions pool SessionCount request `shouldReturn` initial
      rebuildDerived connection
      snapshot connection materializedSessionProjection `shouldReturn` canonical

  it "keeps lifecycle-only visits as bounces, includes zero-duration sessions and counts service keys separately" $ withClickHouse $ \connection -> do
    seed connection
    withPool $ \pool -> do
      bounce <- sessions pool SessionBounceRate request
      buckets bounce `shouldBe` [(Just "2026-07-01", 3 / 7), (Just "2026-07-02", 1)]
      let whole = request {Query.timeGrain = Just NoTimeBucket}
      buckets <$> sessions pool SessionCount whole `shouldReturn` [(Nothing, 8)]
      buckets <$> sessions pool SessionBounceRate whole `shouldReturn` [(Nothing, 0.5)]
      buckets <$> sessions pool SessionAverageDuration whole `shouldReturn` [(Nothing, 30)]
      duration <- sessions pool SessionAverageDuration request
      buckets duration `shouldBe` [(Just "2026-07-01", 240 / 7), (Just "2026-07-02", 0)]
      entry <- input "entry_page" Filter.FilterEq (Just (Aeson.String "/bounce"))
      let selected = request {Query.filters = [entry]}
      amount <$> sessions pool SessionCount selected `shouldReturn` 1
      amount <$> sessions pool SessionBounceRate selected `shouldReturn` 1
      amount <$> sessions pool SessionAverageDuration selected `shouldReturn` 90
      grouped <- sessions pool SessionCount request {Query.groupBy = Just ["entry_page", "exit_page"]}
      groups "entry_page" grouped `shouldBe` Map.fromList [(Nothing, 1), (Just "/bounce", 1), (Just "/two-entry", 1), (Just "/engaged", 1), (Just "/single", 1), (Just "/shared", 2), (Just "/tie-a", 1)]
      groups "exit_page" grouped `shouldBe` Map.fromList [(Nothing, 1), (Just "/bounce", 1), (Just "/two-exit", 1), (Just "/engaged", 1), (Just "/single", 1), (Just "/shared", 2), (Just "/tie-z", 1)]
      amount <$> sessions pool SessionCount request {Query.includeBots = True} `shouldReturn` 9
      amount <$> sessions pool SessionCount request {Query.accountId = AccountId "sessions-other"} `shouldReturn` 1

  it "excludes diagnostics for every stored version while preserving timestamps, actions and replay" $ withClickHouse $ \connection -> do
    -- Write through the storage boundary: undeclared future versions are not an
    -- ingest contract change, and historical versionless rows stay classifiable.
    let diagnostic = request {Query.accountId = AccountId "sessions-diagnostics", Query.timeGrain = Just NoTimeBucket}
        makeRow eid name stamp sid = make eid name stamp sid ("/" <> sid) & #event . #accountId ?~ AccountId "sessions-diagnostics"
        compareState = do
          canonical <- snapshotFor "sessions-diagnostics" connection (sessionProjection "analytics.events_canonical" False)
          snapshotFor "sessions-diagnostics" connection materializedSessionProjection `shouldReturn` canonical
    withPool $ \pool -> do
      forM_ [("error", ["client_error"]), ("vital", ["web_vital"]), ("both", ["client_error", "web_vital"])] $ \(label, names) ->
        forM_ [("legacy", Nothing), ("v1", Just 1), ("future", Just 999)] $ \(versionLabel, version) -> do
          let sid = label <> "-" <> versionLabel
              page = makeRow (sid <> "-page") "page_view" "2026-07-01 12:00:00 UTC" sid
              diagnostics = [makeRow (sid <> "-" <> name <> suffix) name stamp sid & #event . #schemaVersion .~ version | name <- names, (suffix, stamp) <- [("-10", "2026-07-01 12:00:10 UTC"), ("-20", "2026-07-01 12:00:20 UTC")]]
          entry <- input "entry_page" Filter.FilterEq (Just (Aeson.String ("/" <> sid)))
          let selected = diagnostic {Query.filters = [entry]}
              expect bounce duration = do
                amount <$> sessions pool SessionCount selected `shouldReturn` 1
                amount <$> sessions pool SessionBounceRate selected `shouldReturn` bounce
                amount <$> sessions pool SessionAverageDuration selected `shouldReturn` duration
                compareState
          insertQueuedEvents connection [page]
          expect 1 0
          forM_ diagnostics (insertQueuedEvents connection . pure)
          expect 1 20
          insertQueuedEvents connection (reverse (page : diagnostics))
          expect 1 20
          -- A second page alone removes the bounce, without diagnostic engagement.
          let two = sid <> "-two"
          insertQueuedEvents connection (map (\row -> row & #event . #sessionId ?~ SessionId two & #event . #eventId .~ EventId (two <> "-" <> (let EventId eid = row ^. #event . #eventId in eid)) & #event . #url ?~ ("https://shop.example/" <> two)) (page : diagnostics))
          insertQueuedEvents connection [makeRow (two <> "-second-page") "page_view" "2026-07-01 12:00:30 UTC" two]
          twoEntry <- input "entry_page" Filter.FilterEq (Just (Aeson.String ("/" <> two)))
          amount <$> sessions pool SessionBounceRate diagnostic {Query.filters = [twoEntry]} `shouldReturn` 0
          insertQueuedEvents connection [makeRow (sid <> "-purchase") "purchase" "2026-07-01 12:00:30 UTC" sid]
          expect 0 30
          insertQueuedEvents connection [makeRow (sid <> "-second-page") "page_view" "2026-07-01 12:00:40 UTC" sid]
          expect 0 40
      let only = makeRow "diagnostics-only" "client_error" "2026-07-01 12:00:00 UTC" "diagnostics-only"
      insertQueuedEvents connection [only, makeRow "diagnostics-only-vital" "web_vital" "2026-07-01 12:00:20 UTC" "diagnostics-only"]
      onlyEntry <- input "route" Filter.FilterEq (Just (Aeson.String "/diagnostics-only"))
      amount <$> sessions pool SessionBounceRate diagnostic {Query.filters = [onlyEntry]} `shouldReturn` 0
      let midnight = makeRow "diagnostic-midnight-page" "page_view" "2026-07-02 00:00:00 UTC" "diagnostic-midnight"
          earlier = makeRow "diagnostic-midnight-error" "client_error" "2026-07-01 23:59:50 UTC" "diagnostic-midnight"
          later = makeRow "diagnostic-midnight-vital" "web_vital" "2026-07-02 00:00:10 UTC" "diagnostic-midnight"
      insertQueuedEvents connection [midnight]
      insertQueuedEvents connection [later, earlier]
      entry <- input "entry_page" Filter.FilterEq (Just (Aeson.String "/diagnostic-midnight"))
      let selected = diagnostic {Query.filters = [entry], Query.timeGrain = Just Day}
      buckets <$> sessions pool SessionCount selected `shouldReturn` [(Just "2026-07-01", 1), (Just "2026-07-02", 0)]
      amount <$> sessions pool SessionBounceRate selected `shouldReturn` 1
      amount <$> sessions pool SessionAverageDuration selected `shouldReturn` 20
      compareState
      rebuildDerived connection
      compareState
      rebuildDerived connection
      compareState

  it "agrees with acquisition for equivalent attributes, fills empty ungrouped buckets and rejects property selection" $ withClickHouse $ \connection -> do
    seed connection
    withPool $ \pool -> do
      channel <- input "channel" Filter.FilterEq (Just (Aeson.String "email"))
      let selected = request {Query.groupBy = Just ["channel", "source_service"], Query.filters = [channel]}
      session <- sessions pool SessionCount selected
      acquisition <- runEff (Query.runAcquisition defaultRegistry pool AcquisitionSessions selected) >>= either (fail . show) pure
      session ^. #points `shouldBe` acquisition ^. #points
      amount session `shouldBe` 1
      forM_ [SessionCount, SessionBounceRate, SessionAverageDuration] $ \measure -> do
        empty <- sessions pool measure request {Query.accountId = AccountId "sessions-empty"}
        buckets empty `shouldBe` [(Just "2026-07-01", 0), (Just "2026-07-02", 0)]
        grouped <- sessions pool measure request {Query.accountId = AccountId "sessions-empty", Query.groupBy = Just ["channel"]}
        grouped ^. #points `shouldBe` []
      property <- input "prop:url" Filter.FilterSet Nothing
      runEff (Query.runSessionMetric pool SessionCount request {Query.filters = [property]}) >>= (`shouldSatisfy` (\case Left (Query.QueryCompileFailure _) -> True; _ -> False))
      Query.buildSessionMetricSQL SessionCount request {Query.groupBy = Just ["prop:url"]} `shouldSatisfy` (\case Left _ -> True; _ -> False)
      forM_ [1960, 2199] $ \year -> do
        empty <- sessions pool SessionCount request {Query.accountId = AccountId "sessions-empty", Query.from = fromGregorian year 1 1, Query.to = fromGregorian year 1 2}
        buckets empty `shouldBe` [(Just (Text.pack (show year) <> "-01-01"), 0)]
      hourly <- sessions pool SessionCount request {Query.accountId = AccountId "sessions-empty", Query.timeGrain = Just Hour}
      length (hourly ^. #points) `shouldBe` 48
      forM_ [Week, Month, NoTimeBucket] $ \grain -> do
        empty <- sessions pool SessionAverageDuration request {Query.accountId = AccountId "sessions-empty", Query.timeGrain = Just grain}
        length (empty ^. #points) `shouldBe` 1
        amount empty `shouldBe` 0

  it "moves a late earlier event to its true start bucket and enforces complete point bounds" $ withClickHouse $ \connection -> do
    insertQueuedEvents connection [make "late-page" "page_view" "2026-07-02 00:01:00 UTC" "late" "/late" & #event . #accountId ?~ AccountId "sessions-late"]
    withPool $ \pool -> do
      let late = request {Query.accountId = AccountId "sessions-late"}
          req = late {Query.from = fromGregorian 2026 7 2}
      amount <$> sessions pool SessionCount req `shouldReturn` 1
      insertQueuedEvents connection [make "late-start" "session_start" "2026-07-01 23:58:00 UTC" "late" "" & #event . #accountId ?~ AccountId "sessions-late"]
      amount <$> sessions pool SessionCount req `shouldReturn` 0
      amount <$> sessions pool SessionCount late `shouldReturn` 1
      let insertSQL offset count = "INSERT INTO analytics.events_raw(event_id,event_name,source,source_service,occurred_at,received_at,account_id,session_id,properties,context) SELECT concat('session-cap-',toString(number)),'page_view','web',concat('svc',toString(number)),toDateTime64('2026-07-01',3,'UTC'),toDateTime64('2026-07-01',3,'UTC'),'sessions-cap','session','{}','{}' FROM numbers(" <> show offset <> "," <> show count <> ")"
          capped = request {Query.accountId = AccountId "sessions-cap", Query.groupBy = Just ["source_service"]}
      command connection (fromString (insertSQL (0 :: Int) (10000 :: Int)))
      length . view #points <$> sessions pool SessionCount capped `shouldReturn` 10000
      command connection (fromString (insertSQL (10000 :: Int) (1 :: Int)))
      runEff (Query.runSessionMetric pool SessionCount capped) `shouldReturn` Left Query.MetricResultTooLarge

request :: Query.QueryRequest
request = Query.QueryRequest (AccountId "sessions-native") (fromGregorian 2026 7 1) (fromGregorian 2026 7 3) Nothing (Just Day) [] [] False False False

sessions :: QueryPool -> SessionMeasure -> Query.QueryRequest -> IO MetricResult
sessions pool measure req = runEff (Query.runSessionMetric pool measure req) >>= either (fail . show) pure

amount :: MetricResult -> Double
amount result = sum [point ^. #value | point <- result ^. #points]

buckets :: MetricResult -> [(Maybe Text, Double)]
buckets result = [(point ^. #bucket, point ^. #value) | point <- result ^. #points]

groups :: Text -> MetricResult -> Map.Map (Maybe Text) Double
groups key result = Map.fromListWith (+) [(fromMaybe Nothing (Map.lookup key (point ^. #group)), point ^. #value) | point <- result ^. #points]

input :: Text -> Filter.FilterOp -> Maybe Aeson.Value -> IO Filter.MetricFilter
input dimension operator value = either (fail . Text.unpack) pure (Filter.mkMetricFilter dimension operator value)

withPool :: (QueryPool -> IO a) -> IO a
withPool action = do
  cfg <- clickHouseConfigFromConfig <$> requireConfig
  bracket (newQueryPool cfg 1) closeQueryPool action

newtype JsonRow = JsonRow {value :: BS.ByteString}
  deriving stock (Generic)
  deriving anyclass (ClickHaskell '[Column "value" ChString])

snapshot :: Connection -> Text -> IO [BS.ByteString]
snapshot = snapshotFor "sessions-native"

snapshotFor :: Text -> Connection -> Text -> IO [BS.ByteString]
snapshotFor account connection source = do
  let projection = Text.replace "{account_id:String}" ("'" <> account <> "'") source
      sql = "SELECT toJSONString(tuple(source_service,session_id,occurred_at,session_end_at,page_view_count,engagement_count,entry_url,exit_url,is_bot,event_name,source,url,referrer,utm_source,utm_medium,utm_campaign,utm_content,utm_term,browser_family,os_family,device_class,channel,country_code,toString(properties_json))) AS value FROM (" <> projection <> ") ORDER BY source_service,session_id"
  map (\(JsonRow bytes) -> bytes) . concat . reverse <$> select (unsafeMkSelect (const (Text.encodeUtf8Builder sql)) :: Select '[Column "value" ChString] JsonRow) connection pure

seed :: Connection -> IO ()
seed connection = do
  let (first, second) = splitAt 5 rows
  insertQueuedEvents connection first
  insertQueuedEvents connection second

make :: Text -> Text -> String -> Text -> Text -> QueuedEvent
make eid name timestamp sid route =
  enrichedQueuedEvent (IngestRequestContext Nothing (Just "GB")) $
    baseEvent (EventId eid) (EventName name) Web (read timestamp) (read timestamp)
      & #accountId
      ?~ AccountId "sessions-native"
      & #sourceService
      ?~ "a"
      & #sessionId
      .~ (if Text.null sid then Nothing else Just (SessionId sid))
      & #userId
      ?~ UserId "first-user"
      & #url
      .~ (if Text.null route then Nothing else Just ("https://shop.example" <> route))

makeFor :: Text -> Text -> Text -> String -> Text -> Text -> QueuedEvent
makeFor account eid name stamp sid route = make eid name stamp sid route & #event . #accountId ?~ AccountId account

rows :: [QueuedEvent]
rows =
  [ make "bounce-start" "session_start" "2026-07-01 12:00:00 UTC" "bounce" "",
    make "bounce-page" "page_view" "2026-07-01 12:00:10 UTC" "bounce" "/bounce" & #event . #utmMedium ?~ "email" & #enrichment . #channel .~ "email",
    make "two-first" "page_view" "2026-07-01 23:59:00 UTC" "two" "/two-entry",
    make "engaged-page" "page_view" "2026-07-01 13:00:00 UTC" "engaged" "/engaged",
    make "shared-a" "page_view" "2026-07-01 14:00:00 UTC" "shared" "/shared",
    make "two-last" "page_view" "2026-07-02 00:01:00 UTC" "two" "/two-exit",
    make "bounce-leave" "page_leave" "2026-07-01 12:01:10 UTC" "bounce" "",
    make "bounce-identify" "identify" "2026-07-01 12:01:20 UTC" "bounce" "" & #event . #userId ?~ UserId "second-user",
    make "bounce-experiment" "experiment_viewed" "2026-07-01 12:01:30 UTC" "bounce" "",
    make "bounce-once" "identify_once" "2026-07-01 12:01:30 UTC" "bounce" "",
    make "bounce-alias" "alias" "2026-07-01 12:01:30 UTC" "bounce" "",
    make "bounce-group" "group" "2026-07-01 12:01:30 UTC" "bounce" "",
    make "engagement" "purchase" "2026-07-01 13:00:30 UTC" "engaged" "",
    make "zero-page" "session_start" "2026-07-01 15:00:00 UTC" "zero" "",
    make "single-page" "page_view" "2026-07-02 15:00:00 UTC" "single" "/single",
    make "shared-b" "page_view" "2026-07-01 14:00:00 UTC" "shared" "/shared" & #event . #sourceService ?~ "b",
    make "a-tie" "page_view" "2026-07-01 16:00:00 UTC" "ties" "/tie-a",
    make "z-tie" "page_view" "2026-07-01 16:00:00 UTC" "ties" "/tie-z",
    make "old-first" "page_view" "2026-06-30 23:59:00 UTC" "old" "/old",
    make "old-last" "page_view" "2026-07-01 00:01:00 UTC" "old" "/old",
    make "bot-page" "page_view" "2026-07-01 17:00:00 UTC" "bot" "/bot",
    make "bot-later" "page_leave" "2026-07-01 17:00:30 UTC" "bot" "" & #enrichment . #isBot .~ True,
    make "missing" "page_view" "2026-07-01 18:00:00 UTC" "" "/missing",
    make "service" "custom" "2026-07-01 18:00:00 UTC" "service" "" & #event . #source .~ Service,
    make "other" "page_view" "2026-07-01 14:00:00 UTC" "shared" "/other" & #event . #accountId ?~ AccountId "sessions-other"
  ]
