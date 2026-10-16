module Kansoku.Metrics.AcquisitionIntegrationSpec (spec) where

import ClickHaskell (Connection, command)
import Control.Exception (bracket)
import Control.Monad (forM_)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.Map.Strict qualified as Map
import Data.String (fromString)
import Data.Text qualified as Text
import Data.Time (fromGregorian)
import Effectful (runEff)
import Kansoku.ClickHouse
import Kansoku.ClickHouseTestSupport
import Kansoku.Event
import Kansoku.Ingest.QueuedEvent (QueuedEvent, enrichedQueuedEvent)
import Kansoku.Ingest.RequestContext (IngestRequestContext (..))
import Kansoku.Metrics.Api (AcquisitionMeasure (..), MetricResult, TimeGrain (Day))
import Kansoku.Metrics.Filter qualified as Filter
import Kansoku.Metrics.Query qualified as Query
import Kansoku.Metrics.Registry (builtinMetric)
import Kansoku.Prelude
import Test.Hspec

spec :: Spec
spec = describe "Kansoku.Acquisition native" $ do
  it "assembles cross-midnight sessions before first-touch filters and isolates service/account keys" $ withClickHouse $ \connection -> do
    seed connection
    withPool $ \pool -> do
      result <- acquisition pool AcquisitionSessions request
      grouped "channel" result `shouldBe` Map.fromList [(Just "organic_search", 1), (Just "direct", 2), (Just "email", 2), (Just "referral", 1)]
      amount <$> acquisition pool AcquisitionSessions request {Query.from = fromGregorian 2026 7 2} `shouldReturn` 5
      country <- input "country_code" Filter.FilterEq (Just (Aeson.String "GB"))
      amount <$> acquisition pool AcquisitionSessions request {Query.filters = [country]} `shouldReturn` 2
      changed <- input "country_code" Filter.FilterEq (Just (Aeson.String "JP"))
      amount <$> acquisition pool AcquisitionSessions request {Query.filters = [changed]} `shouldReturn` 0
      result2 <- acquisition pool AcquisitionSessions request {Query.groupBy = Just ["source_service", "country_code"]}
      grouped "country_code" result2 `shouldBe` Map.fromList [(Nothing, 3), (Just "GB", 2), (Just "US", 1)]
      let services = grouped "source_service" result2
      services `shouldBe` Map.fromList [(Just "a", 5), (Just "b", 1)]
      -- Rebatching and old delivery cannot alter attribution or session identity.
      insertQueuedEvents connection (reverse rows)
      acquisition pool AcquisitionSessions request >>= (\replayed -> replayed `shouldBe` result)

  it "counts one primary canonical subject per session with anonymous/user namespaces and first-user ties" $ withClickHouse $ \connection -> do
    seed connection
    withPool $ \pool -> do
      users <- acquisition pool AcquisitionUsers request
      grouped "channel" users `shouldBe` Map.fromList [(Just "organic_search", 1), (Just "direct", 2), (Just "email", 1), (Just "referral", 1)]
      amount users `shouldBe` 5
      amount <$> acquisition pool AcquisitionUsers request {Query.includeBots = True} `shouldReturn` 7
      amount <$> acquisition pool AcquisitionSessions request {Query.accountId = AccountId "acquisition-other"} `shouldReturn` 1
      amount <$> acquisition pool AcquisitionUsers request {Query.accountId = AccountId "acquisition-other"} `shouldReturn` 1

  it "uses any-bot session exclusion while web metrics exclude individual bot rows on every grain" $ withClickHouse $ \connection -> do
    seed connection
    withPool $ \pool -> do
      amount <$> acquisition pool AcquisitionSessions request `shouldReturn` 6
      amount <$> acquisition pool AcquisitionSessions request {Query.includeBots = True} `shouldReturn` 8
      bot <- input "is_bot" Filter.FilterEq (Just (Aeson.Bool True))
      amount <$> acquisition pool AcquisitionSessions request {Query.includeBots = True, Query.filters = [bot]} `shouldReturn` 2
      forM_ [Nothing, Just Day] $ \grain -> do
        metric pool "page_views" request {Query.timeGrain = grain} `shouldReturn` 10
        metric pool "page_views" request {Query.timeGrain = grain, Query.includeBots = True} `shouldReturn` 12
        metric pool "active_users" request {Query.timeGrain = grain} `shouldReturn` 11
        metric pool "active_users" request {Query.timeGrain = grain, Query.includeBots = True} `shouldReturn` 12
      allSources <- input "source" Filter.FilterIn (Just (Aeson.toJSON (["web", "service"] :: [Text])))
      metric pool "active_users" request {Query.filters = [allSources]} `shouldReturn` 11

  it "enforces complete-or-error point limits on acquisition itself" $ withClickHouse $ \connection -> do
    let insertSql offset count = "INSERT INTO analytics.events_raw(event_id,event_name,source,source_service,occurred_at,received_at,user_id,account_id,session_id,properties,context) SELECT concat('acq-cap-',toString(number)),'custom','web',concat('svc',toString(number)),toDateTime64('2026-07-01',3,'UTC'),toDateTime64('2026-07-01',3,'UTC'),concat('u',toString(number)),'acquisition-cap','session','{}','{}' FROM numbers(" <> show offset <> "," <> show count <> ")"
        req = request {Query.accountId = AccountId "acquisition-cap", Query.groupBy = Just ["source_service"]}
    command connection (fromString (insertSql (0 :: Int) (10000 :: Int)))
    withPool $ \pool -> do
      result <- acquisition pool AcquisitionSessions req
      length (result ^. #points) `shouldBe` 10000
      command connection (fromString (insertSql (10000 :: Int) (1 :: Int)))
      runEff (Query.runAcquisition defaultRegistry pool AcquisitionSessions req) `shouldReturn` Left Query.MetricResultTooLarge

request :: Query.QueryRequest
request = Query.QueryRequest (AccountId "acquisition-native") (fromGregorian 2026 7 1) (fromGregorian 2026 7 3) Nothing (Just Day) [] [] False

acquisition :: QueryPool -> AcquisitionMeasure -> Query.QueryRequest -> IO MetricResult
acquisition pool measure req = runEff (Query.runAcquisition defaultRegistry pool measure req) >>= either (fail . show) pure

metric :: QueryPool -> Text -> Query.QueryRequest -> IO Double
metric pool name req = do
  definition <- maybe (fail "missing metric fixture") pure (builtinMetric name)
  result <- runEff (Query.run defaultRegistry pool definition req) >>= either (fail . show) pure
  pure (amount result)

amount :: MetricResult -> Double
amount result = sum [point ^. #value | point <- result ^. #points]

grouped :: Text -> MetricResult -> Map.Map (Maybe Text) Double
grouped key result = Map.fromListWith (+) [(fromMaybe Nothing (Map.lookup key (point ^. #group)), point ^. #value) | point <- result ^. #points]

input :: Text -> Filter.FilterOp -> Maybe Aeson.Value -> IO Filter.MetricFilter
input dimension operator value = either (fail . Text.unpack) pure (Filter.mkMetricFilter dimension operator value)

withPool :: (QueryPool -> IO a) -> IO a
withPool action = do
  cfg <- clickHouseConfigFromConfig <$> requireConfig
  bracket (newQueryPool cfg 1) closeQueryPool action

seed :: Connection -> IO ()
seed connection = insertQueuedEvents connection rows

rows :: [QueuedEvent]
rows =
  [ enrich Nothing edge (make "a-start" "session_start" "2026-07-01 23:58:00 UTC" "shared" "a" Nothing & #url .~ Nothing & #anonymousId ?~ AnonymousId "cookie-a"),
    enrich (Just "GB") edge (organic (make "a-page" "page_view" "2026-07-01 23:59:00 UTC" "shared" "a" Nothing) & #anonymousId ?~ AnonymousId "cookie-a"),
    enrich (Just "JP") edge (email (make "a-later" "page_view" "2026-07-02 00:02:00 UTC" "shared" "a" Nothing) & #url ?~ "https://other.example/later" & #anonymousId ?~ AnonymousId "cookie-a"),
    enrich Nothing edge (make "a-identify" "identify" "2026-07-02 00:03:00 UTC" "shared" "a" (Just "u-a") & #anonymousId ?~ AnonymousId "cookie-a"),
    enrich Nothing edge (make "b-custom" "custom" "2026-07-02 01:00:00 UTC" "shared" "b" (Just "u-b")),
    enrich Nothing edge (email (make "empty-subject" "page_view" "2026-07-02 02:00:00 UTC" "empty-identity" "a" Nothing)),
    enrich Nothing edge (email (make "missing-session" "page_view" "2026-07-02 03:00:00 UTC" "" "a" (Just "u-missing"))),
    enrich (Just "GB") edge (make "bot-human" "page_view" "2026-07-02 04:00:00 UTC" "bot-session" "a" (Just "u-bot")),
    enrich Nothing "Googlebot/2.1" (make "bot-page" "page_view" "2026-07-02 04:01:00 UTC" "bot-session" "a" (Just "u-bot")),
    enrich Nothing edge (make "old-start" "page_view" "2026-06-30 23:59:00 UTC" "old" "a" (Just "u-old")),
    enrich (Just "GB") edge (organic (make "old-later" "page_view" "2026-07-01 12:00:00 UTC" "old" "a" (Just "u-old"))),
    enrich (Just "US") edge (email (make "a-tie" "page_view" "2026-07-02 05:00:00 UTC" "ties" "a" (Just "u-first"))),
    enrich (Just "GB") edge (make "z-tie" "page_view" "2026-07-02 05:00:00 UTC" "ties" "a" (Just "u-last") & #utmMedium ?~ "cpc"),
    enrich Nothing edge (make "anonymous" "page_view" "2026-07-02 06:00:00 UTC" "anonymous" "a" Nothing & #anonymousId ?~ AnonymousId "unbound" & #referrer ?~ "https://partner.example/"),
    enrich (Just "GB") edge (make "explicit" "page_view" "2026-07-02 07:00:00 UTC" "explicit" "a" (Just "unbound")),
    enrich Nothing "Googlebot/2.1" (make "bot-only" "page_view" "2026-07-02 08:00:00 UTC" "bot-only" "a" (Just "u-only-bot")),
    enrich Nothing edge (make "service" "custom" "2026-07-02 09:00:00 UTC" "not-web" "a" (Just "u-service") & #source .~ Service),
    enrich Nothing edge (make "other-account" "page_view" "2026-07-01 23:59:00 UTC" "shared" "a" (Just "u-other") & #accountId ?~ AccountId "acquisition-other")
  ]
  where
    edge = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/130.0 Safari/537.36 Edg/130.0"
    enrich :: Maybe Text -> Text -> AnalyticsEvent -> QueuedEvent
    enrich country agent = enrichedQueuedEvent (IngestRequestContext (Just agent) country)
    organic :: AnalyticsEvent -> AnalyticsEvent
    organic event = event & #referrer ?~ "https://www.google.com/search?q=x"
    email :: AnalyticsEvent -> AnalyticsEvent
    email event = event & #utmSource ?~ "newsletter" & #utmMedium ?~ "email"
    make :: Text -> Text -> String -> Text -> Text -> Maybe Text -> AnalyticsEvent
    make eid name time sid service user =
      let timestamp = read time
       in baseEvent (EventId eid) (EventName name) Web timestamp timestamp
            & #accountId
            ?~ AccountId "acquisition-native"
            & #userId
            .~ fmap UserId user
            & #sessionId
            .~ (if Text.null sid then Nothing else Just (SessionId sid))
            & #sourceService
            ?~ service
            & #url
            ?~ "https://shop.example/entry"
            & #properties
            .~ KM.singleton "url" (Aeson.String "https://shop.example/entry")
