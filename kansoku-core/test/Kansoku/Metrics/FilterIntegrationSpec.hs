module Kansoku.Metrics.FilterIntegrationSpec (spec) where

import ClickHaskell (ChString, ClickHaskell, Column, Connection, Select, closeConnection, command, select, unsafeMkSelect)
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (cancel, waitCatch, withAsync)
import Control.Exception (bracket, bracket_)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.Either (isLeft)
import Data.Foldable (traverse_)
import Data.Map.Strict qualified as Map
import Data.String (fromString)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time (fromGregorian)
import Effectful (runEff)
import Kansoku.ClickHouse
import Kansoku.ClickHouseTestSupport
import Kansoku.Event
import Kansoku.Metrics.Api (MetricResult (..), TimeGrain (Day))
import Kansoku.Metrics.Definition qualified as Definition
import Kansoku.Metrics.Filter qualified as Filter
import Kansoku.Metrics.Query qualified as Query
import Kansoku.Metrics.Registry qualified as Registry
import Kansoku.Prelude
import System.Environment (lookupEnv)
import Test.Hspec

spec :: Spec
spec = describe "Kansoku.Metrics filters native" $ do
  it "applies every operator, missing/type rules, safe revenue and resolved activity consistently" $ withNative $ \connection -> do
    seed connection
    withPool $ \pool -> do
      let cases =
            [ ("prop:plan", "set", Nothing, 6),
              ("prop:plan", "unset", Nothing, 3),
              ("prop:plan", "eq", Just (Aeson.String "pro"), 1),
              ("prop:plan", "neq", Just (Aeson.String "pro"), 5),
              ("prop:plan", "in", Just (Aeson.toJSON (["pro", "enterprise"] :: [Text])), 2),
              ("prop:plan", "contains", Just (Aeson.String "é"), 1),
              ("prop:plan", "contains", Just (Aeson.String ""), 6),
              ("prop:amount", "gt", Just (Aeson.Number 1), 3),
              ("prop:amount", "lt", Just (Aeson.Number 0), 1),
              ("prop:amount", "set", Nothing, 5),
              ("prop:amount", "unset", Nothing, 4),
              ("prop:flag", "eq", Just (Aeson.Bool False), 3),
              ("prop:flag", "neq", Just (Aeson.Bool False), 2),
              ("prop:flag", "in", Just (Aeson.toJSON [True, False]), 5)
            ]
      traverse_
        ( \(dimension, operator, operand, expected) -> do
            input <- filterValue dimension operator operand
            total pool countMetric request {Query.filters = [input]} `shouldReturn` expected
        )
        cases
      total pool countMetric request `shouldReturn` 9
      total pool sumMetric request `shouldReturn` 13.5
      total pool averageMetric request `shouldReturn` 2.7
      plan <- filterValue "prop:plan" "in" (Just (Aeson.toJSON (["pro", "enterprise"] :: [Text])))
      total pool sumMetric request {Query.filters = [plan]} `shouldReturn` 12
      let users = Registry.Simple Registry.activeUsers
      total pool users request `shouldReturn` 8
      present <- filterValue "source" "set" Nothing
      total pool users request {Query.filters = [present]} `shouldReturn` 8
      total pool countMetric request {Query.accountId = AccountId "metrics-filter-é"} `shouldReturn` 1
      total pool users request {Query.accountId = AccountId "metrics-filter-é"} `shouldReturn` 1
      -- Rebatching identical facts cannot change any population or sum.
      insertEvents connection (reverse rows)
      total pool countMetric request `shouldReturn` 9
      total pool sumMetric request `shouldReturn` 13.5
      let step key name user service = event key [] & #eventName .~ EventName name & #userId ?~ UserId user & #sourceService ?~ service & #occurredAt .~ read (if name == "signup_completed" then "2026-07-01 00:00:00.001 UTC" else "2026-07-01 00:00:00 UTC")
          ratio = Registry.Ratioed Registry.conversionRate
          ratioRequest = request {Query.timeGrain = Nothing}
      insertEvents
        connection
        [ step "start-a" "signup_started" "RA" "a",
          step "start-b" "signup_started" "RB" "a",
          step "complete-a" "signup_completed" "RA" "a",
          step "start-c" "signup_started" "RC" "b",
          step "complete-c" "signup_completed" "RC" "b",
          step "complete-b" "signup_completed" "RB" "b"
        ]
      selected <- filterValue "source_service" "eq" (Just (Aeson.String "a"))
      allServices <- filterValue "source_service" "in" (Just (Aeson.toJSON (["a", "b"] :: [Text])))
      total pool ratio ratioRequest `shouldReturn` 1
      total pool ratio ratioRequest {Query.filters = [allServices]} `shouldReturn` 1
      total pool ratio ratioRequest {Query.filters = [selected]} `shouldReturn` 0.5
      split <- query pool ratio ratioRequest {Query.groupBy = Just ["source", "source_service"]}
      [(Map.lookup "source_service" (point ^. #group), point ^. #value) | point <- split ^. #points]
        `shouldBe` [(Just (Just "a"), 1), (Just (Just "b"), 1)]

  it "keeps null, empty, arbitrary Unicode and namespaced dual dimensions distinct and sorts numbers numerically" $ withNative $ \connection -> do
    seed connection
    withPool $ \pool -> do
      grouped <- query pool countMetric request {Query.groupBy = Just ["prop:plan"]}
      let pairs = [(Map.lookup "prop:plan" (point ^. #group), point ^. #value) | point <- grouped ^. #points]
      traverse_ (\expected -> pairs `shouldContain` [expected]) [(Just Nothing, 3), (Just (Just ""), 1), (Just (Just "other"), 1), (Just (Just oddPlan), 1)]
      numeric <- query pool countMetric request {Query.groupBy = Just ["prop:amount"]}
      map (Map.lookup "prop:amount" . view #group) (numeric ^. #points)
        `shouldBe` [Just Nothing, Just (Just "-2"), Just (Just "0"), Just (Just "2"), Just (Just "3.5"), Just (Just "10")]
      booleans <- query pool countMetric request {Query.groupBy = Just ["prop:flag"]}
      map (Map.lookup "prop:flag" . view #group) (booleans ^. #points)
        `shouldBe` [Just Nothing, Just (Just "false"), Just (Just "true")]
      dual <- query pool countMetric request {Query.groupBy = Just ["source", "prop:source"]}
      traverse_ (\point -> Map.keys (point ^. #group) `shouldBe` ["prop:source", "source"]) (dual ^. #points)
      map (view #group) (dual ^. #points)
        `shouldContain` [Map.fromList [("source", Just "web"), ("prop:source", Nothing)], Map.fromList [("source", Just "web"), ("prop:source", Just "web")]]

  it "bounds the entire request, propagates external cancellation and recovers the physical pool" $ withNative $ \connection -> do
    seed connection
    original <- readCanonicalView connection
    config <- clickHouseConfigFromConfig <$> requireConfig
    let restoreSQL = Text.unpack (Text.replace "CREATE VIEW" "CREATE OR REPLACE VIEW" (Text.decodeUtf8 original))
        restore = bracket (openClickHouse config) closeConnection (\admin -> command admin (fromString restoreSQL))
        slow = command connection "CREATE OR REPLACE VIEW analytics.events_canonical AS SELECT * FROM (SELECT *,properties_json,identity_context_key FROM analytics.events_raw FINAL WHERE account_id='metrics-filter-native' LIMIT 10) WHERE sleepEachRow(0.2)=0"
    bracket_ slow restore $
      bracket (newQueryPoolWithLimits config 1 (MetricsQueryLimits 1 536870912)) closeQueryPool $ \pool -> do
        runEff (Query.run registry pool countMetric request) `shouldReturn` Left Query.QueryResourceLimit
        restore
        total pool countMetric request `shouldReturn` 9
        slow
        bracket (newQueryPool config 1) closeQueryPool $ \cancelPool -> do
          withAsync (runEff (Query.run registry cancelPool countMetric request)) $ \running -> do
            threadDelay 100000
            cancel running
            waitCatch running >>= (`shouldSatisfy` isLeft)
          restore
          total cancelPool countMetric request `shouldReturn` 9

  it "classifies native memory limits during both final aggregation and identity preparation without partial answers" $ withNative $ \connection -> do
    seed connection
    config <- clickHouseConfigFromConfig <$> requireConfig
    let populate account name cookie =
          command
            connection
            ( fromString
                ("INSERT INTO analytics.events_raw (event_id,event_name,account_id,source,occurred_at,received_at,user_id,anonymous_id,properties,context) SELECT concat('budget-', '" <> account <> "',toString(number)),'" <> name <> "','" <> account <> "','web',toDateTime64('2026-07-01',3,'UTC'),toDateTime64('2026-07-01',3,'UTC'),concat('budget-user-',toString(number))," <> cookie <> ",'{}','{}' FROM numbers(200000)")
            )
    populate "metrics-budget-aggregate" "metric_probe" "''"
    bracket (newQueryPoolWithLimits config 1 (MetricsQueryLimits 30 8388608)) closeQueryPool $ \pool -> do
      runEff (Query.run registry pool countMetric request {Query.accountId = AccountId "metrics-budget-aggregate"}) `shouldReturn` Left Query.QueryResourceLimit
      total pool countMetric request `shouldReturn` 9
      populate "metrics-budget-preparation" "identify" "concat('budget-cookie-',toString(number))"
      runEff (Query.run registry pool (Registry.Simple Registry.activeUsers) request {Query.accountId = AccountId "metrics-budget-preparation"}) `shouldReturn` Left Query.QueryResourceLimit
      total pool countMetric request `shouldReturn` 9

newtype CreateRow = CreateRow {statement :: ByteString}
  deriving stock (Generic)
  deriving anyclass (ClickHaskell '[Column "statement" ChString])

readCanonicalView :: Connection -> IO ByteString
readCanonicalView connection = do
  let statement :: Select '[Column "statement" ChString] CreateRow
      statement = unsafeMkSelect (const "SELECT create_table_query AS statement FROM system.tables WHERE database='analytics' AND name='events_canonical'")
  definitions <- concat <$> select statement connection pure
  case definitions of
    [CreateRow sql] -> pure sql
    _ -> fail "canonical view definition unavailable"

withNative :: (Connection -> Expectation) -> Expectation
withNative action = do
  required <- lookupEnv "KANSOKU_REQUIRED_INTEGRATION"
  unless (required == Just "1") (pendingWith "requires the owned native acceptance environment")
  withClickHouse action

withPool :: (QueryPool -> IO a) -> IO a
withPool action = do
  config <- clickHouseConfigFromConfig <$> requireConfig
  bracket (newQueryPool config 1) closeQueryPool action

query :: QueryPool -> Registry.BuiltinMetric -> Query.QueryRequest -> IO MetricResult
query pool metric req = runEff (Query.run registry pool metric req) >>= either (fail . show) pure

total :: QueryPool -> Registry.BuiltinMetric -> Query.QueryRequest -> IO Double
total pool metric req = sum . map (view #value) . view #points <$> query pool metric req

filterValue :: Text -> Text -> Maybe Aeson.Value -> IO Filter.MetricFilter
filterValue dimension operator operand =
  either (fail . Text.unpack) pure . Filter.parseMetricFilter . Text.decodeUtf8 . LBS.toStrict . Aeson.encode $
    Aeson.object (["dimension" Aeson..= dimension, "op" Aeson..= operator] <> maybe [] (\value -> ["value" Aeson..= value]) operand)

request :: Query.QueryRequest
request = Query.QueryRequest (AccountId "metrics-filter-native") (fromGregorian 2026 7 1) (fromGregorian 2026 7 2) Nothing (Just Day) [] [] False

registry :: EventRegistry
registry = foldr registerSchema defaultRegistry [schema 1, schema 2]
  where
    schema version =
      EventSchema
        (EventName "metric_probe")
        version
        "native scalar fixture"
        [PropertySpec name kind False Nothing Nothing | (name, kind) <- [("plan", PTString), ("amount", PTNumber), ("flag", PTBool), ("source", PTString)]]

countMetric, sumMetric, averageMetric :: Registry.BuiltinMetric
countMetric = Registry.Simple (Registry.events & #eventNames .~ ["metric_probe"])
sumMetric = Registry.Simple (Registry.events & #name .~ "probe_sum" & #eventNames .~ ["metric_probe"] & #aggregation .~ Definition.Sum & #aggregationProperty ?~ "amount")
averageMetric = Registry.Simple (Registry.events & #name .~ "probe_average" & #eventNames .~ ["metric_probe"] & #aggregation .~ Definition.Average & #aggregationProperty ?~ "amount")

oddPlan :: Text
oddPlan = "é:|,\"\\\t"

rows :: [AnalyticsEvent]
rows =
  [ event "a" [] & #anonymousId ?~ AnonymousId "filter-cookie",
    event "b" [("plan", Aeson.Null)] & #userId ?~ UserId "B",
    event "c" (properties "" 0 False <> [("source", Aeson.String "web")]) & #userId ?~ UserId "U",
    event "d" (properties "pro" 2 True <> [("source", Aeson.String "web")]) & #userId ?~ UserId "D",
    event "e" (properties "enterprise" 10 True) & #userId ?~ UserId "E",
    event "f" (properties "other" (-2) False) & #userId ?~ UserId "F",
    event "g" [("plan", Aeson.String oddPlan), ("amount", Aeson.String "historical"), ("flag", Aeson.String "true")] & #userId ?~ UserId "G",
    event "h" [("plan", Aeson.Number 7), ("amount", Aeson.Bool True), ("flag", Aeson.Null)] & #userId ?~ UserId "H",
    event "i" (properties "1" 3.5 False) & #userId ?~ UserId "I"
  ]
  where
    properties plan amount flag = [("plan", Aeson.String plan), ("amount", Aeson.Number amount), ("flag", Aeson.Bool flag)]

event :: Text -> [(Text, Aeson.Value)] -> AnalyticsEvent
event key values =
  baseEvent (EventId ("filter-" <> key)) (EventName "metric_probe") Web (read "2026-07-01 00:00:00 UTC") (read "2026-07-01 00:00:00 UTC")
    & #accountId
    ?~ AccountId "metrics-filter-native"
    & #sourceService
    ?~ "metrics-test"
    & #sessionId
    ?~ SessionId "filter-session"
    & #properties
    .~ KeyMap.fromList [(Key.fromText property, value) | (property, value) <- values]

seed :: Connection -> IO ()
seed connection = do
  command connection "ALTER TABLE analytics.events_raw DELETE WHERE account_id LIKE 'metrics-filter-%' SETTINGS mutations_sync=2"
  let binding = event "binding" [] & #eventName .~ EventName "identify" & #userId ?~ UserId "U" & #anonymousId ?~ AnonymousId "filter-cookie"
      profile = event "profile-only" [] & #eventName .~ EventName "identify_once" & #userId ?~ UserId "PROFILE"
      other = event "other" [] & #accountId ?~ AccountId "metrics-filter-é" & #anonymousId ?~ AnonymousId "other-cookie"
      otherBinding = other & #eventId .~ EventId "filter-other-binding" & #eventName .~ EventName "identify" & #userId ?~ UserId "OTHER"
  insertEvents connection (rows <> [binding, profile, other, otherBinding])
