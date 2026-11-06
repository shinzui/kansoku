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
import Kansoku.Cohort.Query qualified as Cohort
import Kansoku.Cohort.Types qualified as Cohort
import Kansoku.Event
import Kansoku.Ingest.QueuedEvent (QueuedEvent, enrichedQueuedEvent)
import Kansoku.Ingest.RequestContext (IngestRequestContext (..))
import Kansoku.Metrics.Api (AcquisitionMeasure (..), MetricResult, TimeGrain (..))
import Kansoku.Metrics.Filter qualified as Filter
import Kansoku.Metrics.Query qualified as Query
import Kansoku.Metrics.Registry (builtinMetric)
import Kansoku.Prelude
import Test.Hspec

spec :: Spec
spec = describe "Kansoku.Acquisition native" $ do
  it "attributes aliased service conversions once to the first selected session across the range" $ withClickHouse $ \connection -> do
    insertQueuedEvents connection conversionRows
    withPool $ \pool -> do
      forM_ [Just Day, Just NoTimeBucket] $ \grain -> do
        let req = conversionRequest {Query.timeGrain = grain}
            expected count rate = Map.fromList [(Just "organic_search", count), (Just "email", rate)]
        counts <- conversions pool AcquisitionConvertedUsers [" signup_completed ", "other_conversion", "signup_completed"] req
        grouped "channel" counts `shouldBe` expected 1 1
        rates <- conversions pool AcquisitionConversionRate ["signup_completed", "other_conversion"] req
        grouped "channel" rates `shouldBe` expected 0.5 1
        map (view #bucket) (counts ^. #points) `shouldBe` replicate 2 (if grain == Just NoTimeBucket then Nothing else Just "2026-07-01")
        absent <- conversions pool AcquisitionConversionRate ["never_registered"] req
        grouped "channel" absent `shouldBe` expected 0 0
      legacy <- acquisition pool AcquisitionUsers conversionRequest
      grouped "channel" legacy `shouldBe` Map.fromList [(Just "organic_search", 2), (Just "email", 2)]
      insertQueuedEvents connection (reverse conversionRows)
      grouped "channel" <$> conversions pool AcquisitionConvertedUsers ["signup_completed", "other_conversion"] conversionRequest
        `shouldReturn` Map.fromList [(Just "organic_search", 1), (Just "email", 1)]
      later <- input "channel" Filter.FilterEq (Just (Aeson.String "email"))
      laterCount <- conversions pool AcquisitionConvertedUsers ["signup_completed", "other_conversion"] conversionRequest {Query.filters = [later]}
      grouped "channel" laterCount `shouldBe` Map.singleton (Just "email") 1

  it "keeps timing, namespace, ambiguous alias, empty identity and account boundaries" $ withClickHouse $ \connection -> do
    let page person stamp = conversionEvent (person <> "-page") "page_view" stamp person person (Just person)
        convert person stamp = conversionEvent (person <> "-convert") "conversion" stamp "" "backend" (Just person) & #source .~ Service
        start = "2026-07-01 09:00:00 UTC"
        fixture =
          [ page "equal" start,
            convert "equal" start,
            page "before" start,
            convert "before" "2026-07-01 08:59:59.999 UTC",
            page "exclusive" start,
            convert "exclusive" "2026-07-03 00:00:00 UTC",
            page "next-day" start,
            convert "next-day" "2026-07-02 12:00:00 UTC",
            page "old" "2026-06-30 23:59:00 UTC",
            page "old" start & #eventId .~ EventId "old-in-range-page",
            page "old" "2026-07-02 09:00:00 UTC" & #eventId .~ EventId "old-new-session" & #sessionId ?~ SessionId "new-session",
            convert "old" "2026-07-02 09:00:01 UTC",
            page "unconverted" start,
            page "empty" start & #userId .~ Nothing,
            page "blank-session" start & #sessionId .~ Nothing,
            convert "blank-session" start,
            page "same-text" start & #sourceService ?~ "explicit",
            page "same-text" start & #eventId .~ EventId "namespace-anonymous" & #sessionId ?~ SessionId "anonymous" & #sourceService ?~ "anonymous" & #userId .~ Nothing & #anonymousId ?~ AnonymousId "same-text",
            convert "same-text" start,
            page "ambiguous" start & #userId .~ Nothing & #anonymousId ?~ AnonymousId "shared-cookie",
            conversionEvent "alias-one" "alias" start "" "identity" (Just "one") & #source .~ Service & #anonymousId ?~ AnonymousId "shared-cookie" & #properties .~ KM.fromList [("previousId", Aeson.String "shared-cookie"), ("newId", Aeson.String "one")],
            conversionEvent "alias-two" "alias" start "" "identity" (Just "two") & #source .~ Service & #anonymousId ?~ AnonymousId "shared-cookie" & #properties .~ KM.fromList [("previousId", Aeson.String "shared-cookie"), ("newId", Aeson.String "two")],
            convert "one" "2026-07-02 00:00:00 UTC",
            convert "two" "2026-07-02 00:00:00 UTC"
          ]
        req = request {Query.accountId = AccountId "conversion-boundaries", Query.groupBy = Just ["source_service"], Query.timeGrain = Just NoTimeBucket}
        expected = Map.fromList [(Just name, value) | (name, value) <- [("equal", 1), ("before", 0), ("exclusive", 0), ("next-day", 1), ("old", 1), ("unconverted", 0), ("explicit", 1), ("anonymous", 0), ("ambiguous", 0)]]
    insertConversionFacts connection "conversion-boundaries" fixture
    insertConversionFacts connection "conversion-other-account" [convert "unconverted" start]
    withPool $ \pool -> do
      forM_ [AcquisitionConvertedUsers, AcquisitionConversionRate] $ \measure ->
        grouped "source_service" <$> conversions pool measure ["conversion"] req `shouldReturn` expected
      insertConversionFacts connection "conversion-boundaries" (reverse fixture)
      grouped "source_service" <$> conversions pool AcquisitionConvertedUsers ["conversion"] req `shouldReturn` expected

  it "selects complete deterministic attribution rows and keeps session filters out of conversions" $ withClickHouse $ \connection -> do
    let page eid sid svc = conversionEvent eid "page_view" "2026-07-01 09:00:00 UTC" sid svc (Just "person")
        selected = page "chosen" "a" "a" & #referrer ?~ "https://www.google.com/search" & #utmSource ?~ "search" & #utmMedium ?~ "organic" & #utmCampaign ?~ "chosen-campaign"
        other = page "other-source" "a" "b" & #utmMedium ?~ "email" & #utmCampaign ?~ "wrong-source"
        otherSession = page "other-session" "b" "a" & #utmMedium ?~ "email" & #utmCampaign ?~ "wrong-session"
        conversion = conversionEvent "conversion" "conversion" "2026-07-02 00:00:00 UTC" "" "backend" (Just "person") & #source .~ Service & #utmCampaign ?~ "backend-campaign"
        req = request {Query.accountId = AccountId "conversion-dimensions"}
    insertConversionFacts connection "conversion-dimensions" [other, otherSession, conversion, selected]
    withPool $ \pool -> do
      forM_ [("channel", "other_campaign"), ("referrer_host", "www.google.com"), ("utm_source", "search"), ("utm_medium", "organic"), ("utm_campaign", "chosen-campaign"), ("entry_page", "/entry")] $ \(dimension, value) -> do
        result <- conversions pool AcquisitionConvertedUsers ["conversion"] req {Query.groupBy = Just [dimension]}
        grouped dimension result `shouldBe` Map.singleton (Just value) 1
      result <- conversions pool AcquisitionConversionRate ["conversion"] req {Query.groupBy = Just ["utm_campaign", "entry_page"]}
      map (view #group) (result ^. #points) `shouldBe` [Map.fromList [("utm_campaign", Just "chosen-campaign"), ("entry_page", Just "/entry")]]
      selectedService <- input "source_service" Filter.FilterEq (Just (Aeson.String "b"))
      grouped "channel" <$> conversions pool AcquisitionConvertedUsers ["conversion"] req {Query.filters = [selectedService]} `shouldReturn` Map.singleton (Just "email") 1

  it "excludes retained any-bot sessions and individual bot conversions before choosing ownership" $ withClickHouse $ \connection -> do
    let row eid stamp sid user = conversionEvent eid "page_view" stamp sid "site" (Just user)
        bot event = event & #context .~ KM.singleton "bot" (Aeson.Bool True)
        convert eid stamp user = conversionEvent eid "conversion" stamp "" "backend" (Just user) & #source .~ Service
        req = request {Query.accountId = AccountId "conversion-bots", Query.groupBy = Just ["entry_page"], Query.timeGrain = Just NoTimeBucket}
    insertConversionFacts
      connection
      "conversion-bots"
      [ row "old" "2026-07-01 09:00:00 UTC" "bot-session" "a" & #url ?~ "https://shop.example/bot",
        bot (row "late-bot" "2026-07-04 09:00:00 UTC" "bot-session" "a"),
        row "clean" "2026-07-02 09:00:00 UTC" "clean" "a" & #url ?~ "https://shop.example/clean",
        convert "early-conversion" "2026-07-01 10:00:00 UTC" "a",
        row "human" "2026-07-01 09:00:00 UTC" "human" "b",
        bot (convert "bot-conversion" "2026-07-01 10:00:00 UTC" "b")
      ]
    withPool $ \pool -> do
      forM_ [AcquisitionConvertedUsers, AcquisitionConversionRate] $ \measure -> do
        grouped "entry_page" <$> conversions pool measure ["conversion"] req `shouldReturn` Map.fromList [(Just "/clean", 0), (Just "/entry", 0)]
        grouped "entry_page" <$> conversions pool measure ["conversion"] req {Query.includeBots = True} `shouldReturn` Map.fromList [(Just "/bot", 1), (Just "/entry", 1)]

  it "selects current traits and cohorts on people while retaining backend conversions" $ withClickHouse $ \connection -> do
    insertQueuedEvents connection conversionRows
    insertConversionFacts
      connection
      "acquisition-conversion"
      [conversionEvent "a-profile" "identify" "2026-07-04 00:00:00 UTC" "" "identity" (Just "a") & #source .~ Service & #schemaVersion ?~ 2 & #properties .~ KM.singleton "plan" (Aeson.String "pro")]
    pro <- input "user:plan" Filter.FilterEq (Just (Aeson.String "pro"))
    let ident = "eb0aa865-9092-41b1-8c6d-8febd3192ae1"
    membership <- either (fail . Text.unpack) pure (Cohort.compileMembership ident (fromGregorian 2026 7 3) (Cohort.CohortDefinition "converted" "behavioural" [Cohort.CohortCondition (Just "signup_completed") Nothing (Just 1) Nothing 30 []] []))
    cohort <- input "cohort" Filter.FilterEq (Just (Aeson.String ident))
    withPool $ \pool -> do
      forM_ [AcquisitionConvertedUsers, AcquisitionConversionRate] $ \measure -> do
        grouped "channel" <$> conversions pool measure ["signup_completed"] conversionRequest {Query.filters = [pro]} `shouldReturn` Map.singleton (Just "organic_search") 1
        grouped "channel" <$> conversions pool measure ["signup_completed"] conversionRequest {Query.filters = [cohort], Query.cohorts = [(ident, membership)]} `shouldReturn` Map.singleton (Just "organic_search") 1

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
      forM_ [Nothing, Just Day, Just NoTimeBucket] $ \grain -> do
        metric pool "page_views" request {Query.timeGrain = grain} `shouldReturn` 10
        metric pool "page_views" request {Query.timeGrain = grain, Query.includeBots = True} `shouldReturn` 12
        metric pool "active_users" request {Query.timeGrain = grain} `shouldReturn` (if grain == Just NoTimeBucket then 10 else 11)
        metric pool "active_users" request {Query.timeGrain = grain, Query.includeBots = True} `shouldReturn` (if grain == Just NoTimeBucket then 11 else 12)
      allSources <- input "source" Filter.FilterIn (Just (Aeson.toJSON (["web", "service"] :: [Text])))
      metric pool "active_users" request {Query.filters = [allSources]} `shouldReturn` 11

  it "enforces complete-or-error point limits on acquisition itself" $ withClickHouse $ \connection -> do
    let insertSql offset count = "INSERT INTO analytics.events_raw(event_id,event_name,source,source_service,occurred_at,received_at,user_id,account_id,session_id,properties,context) SELECT concat('acq-cap-',toString(number)),'custom','web',concat('svc',toString(number)),toDateTime64('2026-07-01',3,'UTC'),toDateTime64('2026-07-01',3,'UTC'),concat('u',toString(number)),'acquisition-cap','session','{}','{}' FROM numbers(" <> show offset <> "," <> show count <> ")"
        req = request {Query.accountId = AccountId "acquisition-cap", Query.groupBy = Just ["source_service"], Query.timeGrain = Just NoTimeBucket}
    command connection (fromString (insertSql (0 :: Int) (10000 :: Int)))
    withPool $ \pool -> do
      result <- acquisition pool AcquisitionSessions req
      length (result ^. #points) `shouldBe` 10000
      forM_ [AcquisitionConvertedUsers, AcquisitionConversionRate] $ \measure -> do
        zeroes <- conversions pool measure ["unregistered"] req
        length (zeroes ^. #points) `shouldBe` 10000
        amount zeroes `shouldBe` 0
      command connection (fromString (insertSql (10000 :: Int) (1 :: Int)))
      runEff (Query.runAcquisition defaultRegistry pool AcquisitionSessions req) `shouldReturn` Left Query.MetricResultTooLarge
      forM_ [AcquisitionConvertedUsers, AcquisitionConversionRate] $ \measure ->
        runEff (Query.runAcquisitionWithConversions defaultRegistry pool measure (Just ["unregistered"]) req) `shouldReturn` Left Query.MetricResultTooLarge

request :: Query.QueryRequest
request = Query.QueryRequest (AccountId "acquisition-native") (fromGregorian 2026 7 1) (fromGregorian 2026 7 3) Nothing (Just Day) [] [] False False False

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

conversionRequest :: Query.QueryRequest
conversionRequest = request {Query.accountId = AccountId "acquisition-conversion"}

conversions :: QueryPool -> AcquisitionMeasure -> [Text] -> Query.QueryRequest -> IO MetricResult
conversions pool measure names req = runEff (Query.runAcquisitionWithConversions defaultRegistry pool measure (Just names) req) >>= either (fail . show) pure

conversionRows :: [QueuedEvent]
conversionRows =
  map
    (enrichedQueuedEvent (IngestRequestContext (Just "Mozilla/5.0 Chrome/130.0") Nothing))
    [ conversionEvent "a-first" "page_view" "2026-07-01 09:00:00 UTC" "a" "site" Nothing & #anonymousId ?~ AnonymousId "cookie-a" & #referrer ?~ "https://www.google.com/",
      conversionEvent "a-alias" "alias" "2026-07-01 09:01:00 UTC" "" "identity" (Just "a") & #source .~ Service & #anonymousId ?~ AnonymousId "cookie-a" & #properties .~ KM.fromList [("previousId", Aeson.String "cookie-a"), ("newId", Aeson.String "a")],
      conversionEvent "b-first" "page_view" "2026-07-01 10:00:00 UTC" "b" "site" (Just "b") & #referrer ?~ "https://www.google.com/",
      conversionEvent "c-first" "page_view" "2026-07-01 11:00:00 UTC" "c" "site" (Just "c") & #utmSource ?~ "newsletter" & #utmMedium ?~ "email",
      conversionEvent "c-convert" "other_conversion" "2026-07-01 11:00:00 UTC" "" "backend" (Just "c") & #source .~ Service,
      conversionEvent "a-convert" "signup_completed" "2026-07-02 08:00:00 UTC" "" "backend" (Just "a") & #source .~ Service,
      conversionEvent "a-repeat" "signup_completed" "2026-07-02 08:01:00 UTC" "" "backend" (Just "a") & #source .~ Service,
      conversionEvent "a-return" "page_view" "2026-07-02 09:00:00 UTC" "return" "site" (Just "a") & #utmMedium ?~ "email"
    ]

conversionEvent :: Text -> Text -> String -> Text -> Text -> Maybe Text -> AnalyticsEvent
conversionEvent eid name stamp sid service user =
  let timestamp = read stamp
   in baseEvent (EventId eid) (EventName name) Web timestamp timestamp
        & #accountId
        ?~ AccountId "acquisition-conversion"
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

insertConversionFacts :: Connection -> Text -> [AnalyticsEvent] -> IO ()
insertConversionFacts connection account events =
  insertQueuedEvents
    connection
    (map (enrichedQueuedEvent (IngestRequestContext (Just "Mozilla/5.0 Chrome/130.0") Nothing) . (\event -> event & #accountId ?~ AccountId account)) events)
