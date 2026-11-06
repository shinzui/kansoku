module Kansoku.Metrics.SessionAttributeIntegrationSpec (spec) where

import ClickHaskell (ChString, ClickHaskell, Column, Connection, Select, command, select, unsafeMkSelect)
import Control.Exception (bracket, bracket_)
import Control.Monad (forM_)
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Data.String (fromString)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time (fromGregorian)
import Effectful (runEff)
import Kansoku.ClickHouse
import Kansoku.ClickHouseTestSupport
import Kansoku.Cohort.Query qualified as Cohort
import Kansoku.Event
import Kansoku.Ingest.QueuedEvent (QueuedEvent, enrichedQueuedEvent)
import Kansoku.Ingest.RequestContext (IngestRequestContext (..))
import Kansoku.Metrics.Api (AcquisitionMeasure (..), MetricResult, SessionMeasure (..), TimeGrain (..), UserWindow (..))
import Kansoku.Metrics.Custom
import Kansoku.Metrics.Definition
import Kansoku.Metrics.Filter qualified as Filter
import Kansoku.Metrics.Query qualified as Query
import Kansoku.Metrics.Query.Dimension
import Kansoku.Metrics.Query.Session
import Kansoku.Metrics.Registry (BuiltinMetric (..), pageViews)
import Kansoku.Prelude
import Test.Hspec

spec :: Spec
spec = describe "Kansoku.Session attributes native" $ do
  it "selects every page in a visit, groups route/referrer, and deduplicates replay" $ withClickHouse $ \connection -> withoutMerges connection $ do
    seed connection
    withPool $ \pool -> do
      selected <- selectedRequest "session:channel:eq:organic_search"
      landing <- selectedRequest "channel:eq:organic_search"
      amount <$> pages pool selected `shouldReturn` 3
      amount <$> pages pool landing `shouldReturn` 1
      let req = request {Query.groupBy = Just ["route", "session:referrer_host"]}
      result <- pages pool req
      [(p ^. #group, p ^. #value) | p <- result ^. #points]
        `shouldMatchList` [(Map.fromList [("route", Just route), ("session:referrer_host", Just host)], 1) | (host, routes) <- [("www.google.com", ["/landing", "/pricing", "/checkout"]), ("news.ycombinator.com", ["/landing", "/pricing"])], route <- routes]
      insertQueuedEvents connection (reverse rows)
      mapM_ (insertQueuedEvents connection . pure) rows
      pages pool req `shouldReturn` result
      amount <$> pages pool selected `shouldReturn` 3

  it "counts event identities across sessions and preserves rolling lookback" $ withClickHouse $ \connection -> do
    seed connection
    insertQueuedEvents
      connection
      [ make "a-return" "a-return" "2026-07-01 15:00:00 UTC" "/return" & #event . #userId ?~ UserId "a" & #enrichment . #channel .~ "organic_search",
        make "a-referral" "a-referral" "2026-07-01 16:00:00 UTC" "/return" & #event . #userId ?~ UserId "a" & #enrichment . #channel .~ "referral",
        make "lookback-landing" "lookback" "2026-06-01 12:00:00 UTC" "/old" & #enrichment . #channel .~ "organic_search",
        make "lookback-active" "lookback" "2026-06-30 12:00:00 UTC" "/active"
      ]
    withPool $ \pool -> do
      selected <- selectedRequest "session:channel:eq:organic_search"
      amount <$> users pool CalendarWindow selected `shouldReturn` 1
      forM_ [Rolling7, Rolling30] $ \window ->
        amount <$> users pool window selected `shouldReturn` 2
      result <- users pool CalendarWindow request {Query.groupBy = Just ["session:channel"]}
      groups "session:channel" result `shouldBe` Map.fromList [(Just "organic_search", 1), (Just "referral", 2)]

  it "keeps current traits, cohorts and organization attribution on event identities" $ withClickHouse $ \connection -> do
    seed connection
    let profile = make "profile" "" "2026-07-02 00:00:00 UTC" "" & #event . #eventName .~ EventName "identify" & #event . #schemaVersion ?~ 2 & #event . #userId ?~ UserId "a" & #event . #organizationId ?~ OrganizationId "company-a" & #event . #properties .~ KM.singleton "plan" (Aeson.String "pro") & #traitsEligible .~ True
    insertQueuedEvents connection [profile, profile & #event . #eventId .~ EventId "organization-profile" & #event . #eventName .~ EventName "group"]
    withPool $ \pool -> do
      req <- selectedRequest "session:channel:eq:organic_search"
      trait <- input "user:plan:eq:pro"
      let ident = "00000000-0000-0000-0000-000000000059"
          membership = Cohort.Membership "canonical_user IN (SELECT 'user:a')" [] (fromGregorian 2026 7 1)
      cohort <- input ("cohort:eq:" <> ident)
      let selected = req {Query.filters = Query.filters req <> [trait, cohort], Query.cohorts = [(ident, membership)]}
      amount <$> users pool CalendarWindow selected `shouldReturn` 1
      amount <$> users pool Rolling7 selected `shouldReturn` 1
      amount <$> users pool CalendarWindow selected {Query.aggregateOrganizations = True, Query.userOrganization = True} `shouldReturn` 1
      amount <$> users pool CalendarWindow selected {Query.aggregateOrganizations = True} `shouldReturn` 0

  it "keeps numeric samples and side-local ratio populations replay safe" $ withClickHouse $ \connection -> withoutMerges connection $ do
    seed connection
    insertQueuedEvents connection payments
    withPool $ \pool -> do
      selected <- selectedRequest "session:channel:eq:organic_search"
      forM_ [(Count, 2), (UniqueCount, 1), (Sum, 6), (Average, 3), (Percentile, 3)] $ \(kind, expected) -> do
        let def = CustomSimple paymentDefinition {aggregation = kind, aggregationProperty = if kind `elem` [Sum, Average, Percentile] then Just "amount" else Nothing, quantile = if kind == Percentile then Just 0.5 else Nothing}
        amount <$> custom pool def selected `shouldReturn` expected
      let component channel = paymentDefinition {filters = ["session:channel:eq:" <> channel]}
          ratio = CustomRatio (RatioMetric "rate" Nothing (component "organic_search") (component "referral"))
      amount <$> custom pool ratio request {Query.timeGrain = Nothing} `shouldReturn` 2
      amount <$> custom pool ratio selected {Query.timeGrain = Nothing} `shouldReturn` 0
      result <- custom pool ratio request {Query.timeGrain = Nothing, Query.groupBy = Just ["session:channel"]}
      groups "session:channel" result `shouldBe` Map.fromList [(Just "organic_search", 0), (Just "referral", 0)]
      insertQueuedEvents connection (reverse payments)
      amount <$> custom pool ratio request {Query.timeGrain = Nothing} `shouldReturn` 2
      let saved = CustomSimple paymentDefinition {aggregation = Sum, aggregationProperty = Just "amount", filters = ["session:channel:eq:organic_search"], groupBy = ["session:referrer_host"]}
      amount <$> custom pool saved request `shouldReturn` 6
      amount <$> custom pool saved request {Query.groupBy = Just ["source"]} `shouldReturn` 6

  it "isolates keys and guards missing sessions inside each Boolean alternative" $ withClickHouse $ \connection -> do
    seed connection
    insertQueuedEvents
      connection
      [ make "no-session" "" "2026-07-01 14:00:00 UTC" "/missing",
        make "non-web" "a" "2026-07-01 14:00:00 UTC" "/server" & #event . #source .~ Service,
        make "other-service" "a" "2026-07-01 14:00:00 UTC" "/other-service" & #event . #sourceService ?~ "other-service" & #enrichment . #channel .~ "email",
        make "other-account" "a" "2026-07-01 11:00:00 UTC" "/foreign" & #event . #accountId ?~ AccountId "foreign-account" & #enrichment . #channel .~ "email",
        make "missing-country" "country" "2026-07-01 14:00:00 UTC" "/country" & #enrichment . #countryCode .~ Nothing
      ]
    withPool $ \pool -> do
      forM_ [("session:country_code:unset", 1), ("session:channel:neq:organic_search", 4), ("session:channel:in:[\"organic_search\"]", 3), ("session:channel:eq:organic_search|source:eq:service", 4)] $ \(predicate, expected) -> do
        selected <- selectedRequest predicate
        amount <$> pages pool selected `shouldReturn` expected
      result <- pages pool request {Query.groupBy = Just ["session:channel"]}
      Map.lookup Nothing (groups "session:channel" result) `shouldBe` Just 2
      selected <- selectedRequest "session:channel:eq:organic_search"
      amount <$> pages pool selected `shouldReturn` 3
      foreignResult <- pages pool request {Query.accountId = AccountId "foreign-account", Query.groupBy = Just ["session:channel"]}
      groups "session:channel" foreignResult `shouldBe` Map.singleton (Just "email") 1
      server <- input "source:eq:service"
      forM_ ["session:country_code:unset", "session:channel:neq:email", "session:channel:in:[\"organic_search\"]"] $ \term -> do
        selectedTerm <- input term
        amount <$> pages pool request {Query.filters = [server, selectedTerm]} `shouldReturn` 0

  it "uses retained attribution outside event dates and preserves individual bot selection" $ withClickHouse $ \connection -> do
    seed connection
    let extras =
          [ make "old-landing" "old" "2026-06-30 23:59:00 UTC" "/old" & #enrichment . #channel .~ "organic_search",
            make "old-clean" "old" "2026-07-01 00:01:00 UTC" "/later",
            make "old-bot" "old" "2026-07-01 00:02:00 UTC" "/bot" & #enrichment . #isBot .~ True,
            make "exclusive-to" "old" "2026-07-02 00:00:00 UTC" "/to",
            make "outside-bot" "a" "2026-07-03 00:00:00 UTC" "" & #event . #eventName .~ EventName "page_leave" & #enrichment . #isBot .~ True,
            make "before-page" "future" "2026-07-01 00:00:00 UTC" "/lifecycle" & #event . #eventName .~ EventName "custom",
            make "future-page" "future" "2026-07-02 12:00:00 UTC" "/future" & #enrichment . #channel .~ "email"
          ]
    insertQueuedEvents connection extras
    withPool $ \pool -> do
      old <- selectedRequest "session:entry_page:eq:/old"
      amount <$> pages pool old `shouldReturn` 1
      amount <$> pages pool old {Query.includeBots = True} `shouldReturn` 2
      bots <- selectedRequest "session:is_bot:eq:true"
      amount <$> pages pool bots `shouldReturn` 4
      amount <$> users pool CalendarWindow old `shouldReturn` 1
      amount <$> users pool CalendarWindow old {Query.includeBots = True} `shouldReturn` 1
      wholeSession <- input "entry_page:eq:/old"
      amount <$> (runEff (Query.runSessionMetric pool SessionCount request {Query.filters = [wholeSession], Query.includeBots = True}) >>= either (fail . show) pure) `shouldReturn` 0
      future <- selectedRequest "session:channel:eq:email"
      let def = CustomSimple paymentDefinition {eventNames = ["custom"]}
      amount <$> custom pool def future `shouldReturn` 1
      -- Custom counts keep bot rows; they do not inherit the page-view bot default.
      let allPages = CustomSimple paymentDefinition {eventNames = ["page_view"]}
      amount <$> custom pool allPages old `shouldReturn` 2

  it "matches every intrinsic value against both retained session projections" $ withClickHouse $ \connection -> do
    seed connection
    let changes =
          [ make "a-lifecycle" "a" "2026-07-01 11:00:00 UTC" "/wrong" & #event . #eventName .~ EventName "session_start" & #enrichment . #channel .~ "email",
            make "zero-page" "zero" "2026-07-01 10:00:00 UTC" "/fallback" & #event . #eventName .~ EventName "custom" & #enrichment . #channel .~ "email",
            make "tie-z" "tie" "2026-07-01 10:00:00 UTC" "/last" & #enrichment . #channel .~ "referral",
            make "tie-a" "tie" "2026-07-01 10:00:00 UTC" "/first" & #enrichment . #channel .~ "email",
            make "a-conflict" "a" "2026-07-01 12:03:00 UTC" "/later" & #event . #utmCampaign ?~ "conflict" & #enrichment . #countryCode ?~ "US" & #enrichment . #deviceClass .~ "mobile"
          ]
    insertQueuedEvents connection changes
    let attributes = [minBound .. maxBound]
    expected <- snapshot connection (sessionProjection "analytics.events_canonical" False) (map sessionAttributeExpr attributes)
    snapshot connection materializedSessionProjection (map sessionAttributeExpr attributes) `shouldReturn` expected
    let attached = attachSessionAttributes attributes "analytics.events_canonical"
        eligible = "SELECT * FROM " <> attached <> " WHERE account_id={account_id:String} AND attached_session_present=1"
    actual <- snapshot connection eligible (map sessionAttributeColumn attributes)
    actual `shouldBe` expected
    insertQueuedEvents connection (reverse (rows <> changes))
    snapshot connection eligible (map sessionAttributeColumn attributes) `shouldReturn` expected
    withPool $ \pool -> do
      zero <- selectedRequest "session:route:eq:/fallback"
      let customEvent = CustomSimple paymentDefinition {eventNames = ["custom"]}
      result <- custom pool customEvent zero {Query.groupBy = Just ["session:entry_page", "session:exit_page"]}
      [(p ^. #group, p ^. #value) | p <- result ^. #points] `shouldBe` [(Map.fromList [("session:entry_page", Nothing), ("session:exit_page", Nothing)], 1)]
      -- Known clean keys have the same public selected populations on sessions/acquisition.
      sessionFilter <- input "channel:eq:email"
      let req = request {Query.filters = [sessionFilter], Query.groupBy = Just ["route"]}
      sessions <- runEff (Query.runSessionMetric pool SessionCount req) >>= either (fail . show) pure
      acquisition <- runEff (Query.runAcquisition defaultRegistry pool AcquisitionSessions req) >>= either (fail . show) pure
      sessions ^. #points `shouldBe` acquisition ^. #points
      amount sessions `shouldBe` 2

  it "binds session operands containing quotes, colons and pipes through native execution" $ withClickHouse $ \connection -> do
    seed connection
    let literal = "campaign':pipe|colon:value"
    insertQueuedEvents connection [make "literal" "literal" "2026-07-01 14:00:00 UTC" "/literal" & #event . #utmCampaign ?~ literal]
    selected <- either (fail . Text.unpack) pure (Filter.mkMetricFilter "session:utm_campaign" Filter.FilterEq (Just (Aeson.String literal)))
    withPool $ \pool -> amount <$> pages pool request {Query.filters = [selected]} `shouldReturn` 1

  it "enforces the complete final-point boundary after session grouping" $ withClickHouse $ \connection -> do
    resetTable connection
    let insertSQL offset count = "INSERT INTO analytics.events_raw(event_id,event_name,source,source_service,occurred_at,received_at,account_id,session_id,properties,context) SELECT concat('attached-cap-',toString(number)),'page_view','web',concat('svc',toString(number)),toDateTime64('2026-07-01',3,'UTC'),toDateTime64('2026-07-01',3,'UTC'),'session-attributes-native','session','{}','{}' FROM numbers(" <> show offset <> "," <> show count <> ")"
        capped = request {Query.groupBy = Just ["session:source_service"]}
    command connection (fromString (insertSQL (0 :: Int) (10000 :: Int)))
    withPool $ \pool -> do
      length . view #points <$> pages pool capped `shouldReturn` 10000
      command connection (fromString (insertSQL (10000 :: Int) (1 :: Int)))
      runEff (Query.run defaultRegistry pool (Simple pageViews) capped) `shouldReturn` Left Query.MetricResultTooLarge

withoutMerges :: Connection -> IO a -> IO a
withoutMerges connection = bracket_ (merges "STOP") (merges "START")
  where
    merges operation = forM_ ["events_raw", "sessions"] $ \table -> command connection (fromString ("SYSTEM " <> operation <> " MERGES analytics." <> table))

seed :: Connection -> IO ()
seed connection = resetTable connection >> insertQueuedEvents connection rows

input :: Text -> IO Filter.MetricFilter
input = either (fail . Text.unpack) pure . Filter.parseMetricFilter

users :: QueryPool -> UserWindow -> Query.QueryRequest -> IO MetricResult
users pool window req = runEff (Query.runUsers defaultRegistry pool window req) >>= either (fail . show) pure

custom :: QueryPool -> CustomDefinition -> Query.QueryRequest -> IO MetricResult
custom pool def req = do
  effective <- either (fail . Text.unpack) pure (customRequest def req)
  runEff (Query.run defaultRegistry pool (customBuiltin def) effective) >>= either (fail . show) pure

paymentDefinition :: MetricDefinition
paymentDefinition = MetricDefinition "payments" Nothing ["payment_completed"] Count Nothing Nothing [] [] Nothing

payments :: [QueuedEvent]
payments = [make eid sid "2026-07-01 14:00:00 UTC" "" & #event . #eventName .~ EventName "payment_completed" & #event . #properties .~ KM.singleton "amount" (Aeson.Number amount') | (eid, sid, amount') <- [("payment-2", "a", 2), ("payment-4", "a", 4), ("payment-6", "b", 6)]]

groups :: Text -> MetricResult -> Map.Map (Maybe Text) Double
groups key result = Map.fromListWith (+) [(fromMaybe Nothing (Map.lookup key (point ^. #group)), point ^. #value) | point <- result ^. #points]

newtype JsonRow = JsonRow {value :: BS.ByteString}
  deriving stock (Generic)
  deriving anyclass (ClickHaskell '[Column "value" ChString])

snapshot :: Connection -> Text -> [Text] -> IO [BS.ByteString]
snapshot connection source expressions = do
  let sql = Text.replace "{account_id:String}" "'session-attributes-native'" ("SELECT DISTINCT toJSONString(tuple(source_service,session_id," <> Text.intercalate "," expressions <> ")) AS value FROM (" <> source <> ") ORDER BY value")
  map (\(JsonRow bytes) -> bytes) . concat . reverse <$> select (unsafeMkSelect (const (Text.encodeUtf8Builder sql)) :: Select '[Column "value" ChString] JsonRow) connection pure

request :: Query.QueryRequest
request = Query.QueryRequest (AccountId "session-attributes-native") (fromGregorian 2026 7 1) (fromGregorian 2026 7 2) Nothing (Just Day) [] [] False False False

selectedRequest :: Text -> IO Query.QueryRequest
selectedRequest text = do
  input <- either (fail . Text.unpack) pure (Filter.parseMetricFilter text)
  pure request {Query.filters = [input]}

pages :: QueryPool -> Query.QueryRequest -> IO MetricResult
pages pool req = runEff (Query.run defaultRegistry pool (Simple pageViews) req) >>= either (fail . show) pure

amount :: MetricResult -> Double
amount result = sum [point ^. #value | point <- result ^. #points]

withPool :: (QueryPool -> IO a) -> IO a
withPool action = do
  cfg <- clickHouseConfigFromConfig <$> requireConfig
  bracket (newQueryPool cfg 1) closeQueryPool action

make :: Text -> Text -> String -> Text -> QueuedEvent
make eid sid timestamp route =
  enrichedQueuedEvent (IngestRequestContext Nothing (Just "GB")) $
    baseEvent (EventId eid) (EventName "page_view") Web (read timestamp) (read timestamp)
      & #accountId
      ?~ AccountId "session-attributes-native"
      & #sourceService
      ?~ "session-attributes-web"
      & #sessionId
      ?~ SessionId sid
      & #userId
      ?~ UserId sid
      & #url
      ?~ ("https://shop.example" <> route)

rows :: [QueuedEvent]
rows =
  [ make "a-landing" "a" "2026-07-01 12:00:00 UTC" "/landing" & #event . #referrer ?~ "https://www.google.com/search" & #event . #utmCampaign ?~ "launch" & #enrichment . #channel .~ "organic_search",
    make "a-pricing" "a" "2026-07-01 12:01:00 UTC" "/pricing" & #event . #referrer ?~ "https://shop.example/landing",
    make "a-checkout" "a" "2026-07-01 12:02:00 UTC" "/checkout" & #event . #referrer ?~ "https://shop.example/pricing",
    make "b-landing" "b" "2026-07-01 13:00:00 UTC" "/landing" & #event . #referrer ?~ "https://news.ycombinator.com/" & #enrichment . #channel .~ "referral",
    make "b-pricing" "b" "2026-07-01 13:01:00 UTC" "/pricing" & #event . #referrer ?~ "https://shop.example/landing"
  ]
