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
import Data.Text.IO qualified as Text
import Data.Time (fromGregorian)
import Effectful (runEff)
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
      rebuild connection
      snapshot connection materializedSessionProjection `shouldReturn` canonical
      sessions pool SessionCount request `shouldReturn` initial
      rebuild connection
      snapshot connection materializedSessionProjection `shouldReturn` canonical

  it "keeps lifecycle-only visits as bounces, includes zero-duration sessions and counts service keys separately" $ withClickHouse $ \connection -> do
    seed connection
    withPool $ \pool -> do
      bounce <- sessions pool SessionBounceRate request
      buckets bounce `shouldBe` [(Just "2026-07-01", 3 / 7), (Just "2026-07-02", 1)]
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
      forM_ [Week, Month] $ \grain -> do
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
snapshot connection source = do
  let projection = Text.replace "{account_id:String}" "'sessions-native'" source
      sql = "SELECT toJSONString(tuple(source_service,session_id,occurred_at,session_end_at,page_view_count,engagement_count,entry_url,exit_url,is_bot,event_name,source,url,referrer,utm_source,utm_medium,utm_campaign,utm_content,utm_term,browser_family,os_family,device_class,channel,country_code,toString(properties_json))) AS value FROM (" <> projection <> ") ORDER BY source_service,session_id"
  map (\(JsonRow bytes) -> bytes) . concat . reverse <$> select (unsafeMkSelect (const (Text.encodeUtf8Builder sql)) :: Select '[Column "value" ChString] JsonRow) connection pure

rebuild :: Connection -> IO ()
rebuild connection = do
  sql <- Text.readFile "db/clickhouse/migrations/0020_replay_safe_sessions.sql"
  forM_ (filter (not . Text.null . Text.strip) (Text.splitOn ";" sql)) (command connection . fromString . Text.unpack)

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
