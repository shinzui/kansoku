module Kansoku.QueryIntegrationSpec (spec) where

import ClickHaskell (ClickHaskell, Column, Select, UInt8, command, select, unsafeMkSelect)
import Control.Concurrent.Async (mapConcurrently)
import Control.Exception (bracket, bracket_)
import Control.Monad (forM_)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key (Key)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (NominalDiffTime, diffUTCTime)
import Data.Word (Word8)
import Effectful (runEff)
import Kansoku.ClickHouse
import Kansoku.ClickHouseTestSupport
import Kansoku.Event
import Kansoku.Metrics.Api (TimeGrain (Day))
import Kansoku.Metrics.Definition (Aggregation (Average))
import Kansoku.Metrics.Query qualified as Query
import Kansoku.Metrics.Query.Validate (SqlName, mkSqlName)
import Kansoku.Metrics.Registry (BuiltinMetric (..), builtinMetric)
import Kansoku.Prelude
import Test.Hspec

spec :: Spec
spec = describe "Kansoku.Query integration" $ do
  it "keeps revenue, average, page views, users and sessions stable across regrouped replays before merges" $
    withClickHouse $ \conn -> do
      cfg <- clickHouseConfigFromConfig <$> requireConfig
      let rows =
            [ propertyEvent "replay-payment-1" "payment_completed" "replay-user" [("amount", Aeson.Number 3)],
              propertyEvent "replay-payment-2" "payment_completed" "replay-user" [("amount", Aeson.Number 7)],
              propertyEvent "replay-page-1" "page_view" "replay-user" [],
              propertyEvent "replay-page-2" "page_view" "replay-user" [],
              propertyEvent "replay-start" "signup_started" "replay-user" [],
              propertyEvent "replay-complete" "signup_completed" "replay-user" [],
              propertyEvent "replay-identify" "identify" "replay-user" [] & #anonymousId ?~ AnonymousId "replay-anon"
            ]
              <&> (\event -> (if event ^. #eventName == EventName "page_view" then event & #userId .~ Nothing & #anonymousId ?~ AnonymousId "replay-anon" else event) & #accountId ?~ AccountId "acct_replay" & #sessionId ?~ SessionId "replay-session" & #url ?~ "https://example.com/replay")
          req = Query.QueryRequest (AccountId "acct_replay") (fromGregorian 2026 7 1) (fromGregorian 2026 7 2) Nothing (Just Day)
      metrics <- traverse requireBuiltinMetric ["events", "revenue", "page_views", "sessions", "active_users", "conversion_rate"]
      revenue <- requireBuiltinMetric "revenue"
      average <- case revenue of Simple definition -> pure (Simple (definition & #name .~ "payment_average" & #aggregation .~ Average)); _ -> fail "expected revenue definition"
      let snapshot pool = traverse (\metric -> runEff (Query.run defaultRegistry pool metric req) >>= expectCompiled >>= pure . sum . fmap (view #value) . view #points) (metrics <> [average])
      bracket (newQueryPool cfg 2) closeQueryPool $ \pool -> do
        bracket_ (command conn "SYSTEM STOP MERGES analytics.events_raw") (command conn "SYSTEM START MERGES analytics.events_raw") $ do
          insertEvents conn rows
          initial <- snapshot pool
          initial `shouldBe` [7, 10, 2, 1, 2, 1, 5]
          -- Simulate restart/rebatching and old archive replays: every copy is
          -- byte-identical to its first queued payload, in different blocks.
          insertEvents conn (reverse rows)
          forM_ rows (insertEvents conn . pure)
          insertEvents conn (drop 2 rows <> take 2 rows)
          snapshot pool `shouldReturn` initial
        command conn "OPTIMIZE TABLE analytics.events_raw FINAL"
        snapshot pool `shouldReturn` [7, 10, 2, 1, 2, 1, 5]

  it "runs concurrent queries in parallel across the pool" $
    withClickHouse $ \_conn -> do
      cfg <- clickHouseConfigFromConfig <$> requireConfig
      pooled <- timedSleeps 4 cfg
      pooled `shouldSatisfy` (< 2.5)

  it "serializes when the pool has a single connection (control)" $
    withClickHouse $ \_conn -> do
      cfg <- clickHouseConfigFromConfig <$> requireConfig
      serialized <- timedSleeps 1 cfg
      serialized `shouldSatisfy` (>= 4)

  it "keeps a tab-bearing group key intact through a grouped metric query" $
    withClickHouse $ \conn -> do
      resetTable conn
      insertEvents conn [sampleEvent "evt_q_1" "signup\tstep", sampleEvent "evt_q_2" "page_view"]
      queryPool <- (`newQueryPool` 2) . clickHouseConfigFromConfig =<< requireConfig
      metric <- requireBuiltinMetric "events"
      compiled <-
        runEff $
          Query.run
            defaultRegistry
            queryPool
            metric
            Query.QueryRequest
              { accountId = AccountId "acct_query",
                from = fromGregorian 2026 7 1,
                to = fromGregorian 2026 7 2,
                groupBy = Just ["event_name"],
                timeGrain = Just Day
              }
      result <- expectCompiled compiled
      let keys =
            [ groupValue
            | point <- result ^. #points,
              Just groupValue <- [Map.lookup "event_name" (point ^. #group)]
            ]
      keys `shouldContain` ["signup\tstep"]

  it "passes built-in event names through native query parameters" $
    withClickHouse $ \conn -> do
      resetTable conn
      insertEvents conn [sampleEvent "evt_parameter_1" "user_registered"]
      queryPool <- (`newQueryPool` 2) . clickHouseConfigFromConfig =<< requireConfig
      metric <- requireBuiltinMetric "new_users"
      compiled <-
        runEff $
          Query.run
            defaultRegistry
            queryPool
            metric
            Query.QueryRequest
              { accountId = AccountId "acct_query",
                from = fromGregorian 2026 7 1,
                to = fromGregorian 2026 7 2,
                groupBy = Nothing,
                timeGrain = Just Day
              }
      result <- expectCompiled compiled
      sum (fmap (^. #value) (result ^. #points)) `shouldBe` 1

  it "passes opaque account ids through native query parameters" $
    withClickHouse $ \conn -> do
      resetTable conn
      let opaqueAccount = AccountId "acct_'opaque"
          event = sampleEvent "evt_account_parameter_1" "account_parameter" & #accountId .~ Just opaqueAccount
      insertEvents conn [event]
      queryPool <- (`newQueryPool` 2) . clickHouseConfigFromConfig =<< requireConfig
      metric <- requireBuiltinMetric "events"
      compiled <-
        runEff $
          Query.run
            defaultRegistry
            queryPool
            metric
            Query.QueryRequest
              { accountId = opaqueAccount,
                from = fromGregorian 2026 7 1,
                to = fromGregorian 2026 7 2,
                groupBy = Nothing,
                timeGrain = Just Day
              }
      result <- expectCompiled compiled
      sum (fmap (^. #value) (result ^. #points)) `shouldBe` 1

  it "groups revenue by a declared property through the native JSON projection" $
    withClickHouse $ \conn -> do
      resetTable conn
      insertEvents
        conn
        [ propertyEvent "evt_revenue_1" "payment_completed" "user-1" [("amount", Aeson.Number 49), ("plan", Aeson.String "pro")],
          propertyEvent "evt_revenue_2" "payment_completed" "user-2" [("amount", Aeson.Number 49), ("plan", Aeson.String "pro")],
          propertyEvent "evt_revenue_3" "payment_completed" "user-3" [("amount", Aeson.Number 9), ("plan", Aeson.String "free")]
        ]
      queryPool <- (`newQueryPool` 2) . clickHouseConfigFromConfig =<< requireConfig
      metric <- requireBuiltinMetric "revenue"
      compiled <-
        runEff $
          Query.run
            defaultRegistry
            queryPool
            metric
            Query.QueryRequest
              { accountId = AccountId "acct_query",
                from = fromGregorian 2026 7 1,
                to = fromGregorian 2026 7 2,
                groupBy = Just ["prop:plan"],
                timeGrain = Just Day
              }
      result <- expectCompiled compiled
      Map.fromList
        [ (groupValue, point ^. #value)
        | point <- result ^. #points,
          Just groupValue <- [Map.lookup "plan" (point ^. #group)]
        ]
        `shouldBe` Map.fromList [("free", 9), ("pro", 98)]

  it "groups canonical feature users by the definition's default property" $
    withClickHouse $ \conn -> do
      resetTable conn
      insertEvents
        conn
        [ propertyEvent "evt_feature_1" "feature_used" "user-1" [("feature", Aeson.String "search")],
          propertyEvent "evt_feature_2" "feature_used" "user-2" [("feature", Aeson.String "search")],
          propertyEvent "evt_feature_3" "feature_used" "user-3" [("feature", Aeson.String "export")]
        ]
      queryPool <- (`newQueryPool` 2) . clickHouseConfigFromConfig =<< requireConfig
      metric <- requireBuiltinMetric "feature_adoption"
      compiled <-
        runEff $
          Query.run
            defaultRegistry
            queryPool
            metric
            Query.QueryRequest
              { accountId = AccountId "acct_query",
                from = fromGregorian 2026 7 1,
                to = fromGregorian 2026 7 2,
                groupBy = Nothing,
                timeGrain = Just Day
              }
      result <- expectCompiled compiled
      Map.fromList
        [ (groupValue, point ^. #value)
        | point <- result ^. #points,
          Just groupValue <- [Map.lookup "feature" (point ^. #group)]
        ]
        `shouldBe` Map.fromList [("export", 1), ("search", 2)]

  it "excludes a user whose funnel events occurred out of order" $
    withClickHouse $ \conn -> do
      resetTable conn
      insertEvents
        conn
        [ funnelEvent "evt_funnel_1" "signup_started" "u1" "2026-06-01 11:05:00 UTC",
          funnelEvent "evt_funnel_2" "signup_completed" "u1" "2026-06-01 11:10:00 UTC",
          funnelEvent "evt_funnel_3" "signup_started" "u3" "2026-06-02 09:00:00 UTC",
          funnelEvent "evt_funnel_4" "signup_completed" "u4" "2026-06-03 09:00:00 UTC",
          funnelEvent "evt_funnel_5" "signup_started" "u4" "2026-06-03 10:00:00 UTC"
        ]
      queryPool <- (`newQueryPool` 2) . clickHouseConfigFromConfig =<< requireConfig
      steps <- traverse validSqlName ["signup_started", "signup_completed"]
      result <-
        expectCompiled
          =<< runEff
            ( Query.runFunnel
                queryPool
                Query.QueryRequest
                  { accountId = AccountId "acct_funnel",
                    from = fromGregorian 2026 6 1,
                    to = fromGregorian 2026 6 8,
                    groupBy = Nothing,
                    timeGrain = Nothing
                  }
                604800
                steps
            )
      [ (Map.lookup "index" (point ^. #group), point ^. #value)
        | point <- result ^. #points
        ]
        `shouldBe` [(Just "1", 3), (Just "2", 1)]

  it "serves account-scoped exposures and excludes pre-exposure conversions" $
    withClickHouse $ \conn -> do
      resetTable conn
      insertEvents
        conn
        [ experimentEvent "evt_exp_c1" "acct_experiment_spec" "experiment_viewed" "c1" "2026-08-01 10:00:00 UTC" (Just "control"),
          experimentEvent "evt_exp_c2" "acct_experiment_spec" "experiment_viewed" "c2" "2026-08-01 10:00:00 UTC" (Just "control"),
          experimentEvent "evt_exp_t1" "acct_experiment_spec" "experiment_viewed" "t1" "2026-08-01 10:00:00 UTC" (Just "treatment"),
          experimentEvent "evt_exp_t2" "acct_experiment_spec" "experiment_viewed" "t2" "2026-08-01 10:00:00 UTC" (Just "treatment"),
          experimentEvent "evt_exp_c1_again" "acct_experiment_spec" "experiment_viewed" "c1" "2026-08-02 10:00:00 UTC" (Just "control"),
          experimentEvent "evt_checkout_c1" "acct_experiment_spec" "checkout_started" "c1" "2026-08-01 11:00:00 UTC" Nothing,
          experimentEvent "evt_checkout_t1" "acct_experiment_spec" "checkout_started" "t1" "2026-08-01 11:00:00 UTC" Nothing,
          experimentEvent "evt_checkout_t2" "acct_experiment_spec" "checkout_started" "t2" "2026-08-01 11:00:00 UTC" Nothing,
          experimentEvent "evt_conv_c2_before" "acct_experiment_spec" "purchase_completed" "c2" "2026-08-01 09:00:00 UTC" Nothing,
          experimentEvent "evt_conv_c1" "acct_experiment_spec" "purchase_completed" "c1" "2026-08-01 12:00:00 UTC" Nothing,
          experimentEvent "evt_conv_t1" "acct_experiment_spec" "purchase_completed" "t1" "2026-08-01 12:00:00 UTC" Nothing,
          experimentEvent "evt_other_account" "acct_experiment_other" "experiment_viewed" "other" "2026-08-01 10:00:00 UTC" (Just "control")
        ]
      queryPool <- (`newQueryPool` 2) . clickHouseConfigFromConfig =<< requireConfig
      experiment <- validSqlName "checkout_v2"
      conversionEvent <- validSqlName "purchase_completed"
      let request =
            Query.QueryRequest
              { accountId = AccountId "acct_experiment_spec",
                from = fromGregorian 2026 8 1,
                to = fromGregorian 2026 8 3,
                groupBy = Nothing,
                timeGrain = Nothing
              }
      exposures <- expectCompiled =<< runEff (Query.runExperimentExposures queryPool request (Just experiment))
      Map.fromList
        [ (Map.lookup "variant" (point ^. #group), point ^. #value)
        | point <- exposures ^. #points
        ]
        `shouldBe` Map.fromList [(Just "control", 2), (Just "treatment", 2)]
      conversion <- expectCompiled =<< runEff (Query.runExperimentConversion queryPool request experiment conversionEvent)
      Map.fromList
        [ ( (Map.lookup "measure" (point ^. #group), Map.lookup "variant" (point ^. #group)),
            point ^. #value
          )
        | point <- conversion ^. #points
        ]
        `shouldBe` Map.fromList
          [ ((Just "converted", Just "control"), 1),
            ((Just "converted", Just "treatment"), 1),
            ((Just "conversion_rate", Just "control"), 0.5),
            ((Just "conversion_rate", Just "treatment"), 0.5),
            ((Just "exposed", Just "control"), 2),
            ((Just "exposed", Just "treatment"), 2)
          ]
      steps <- traverse validSqlName ["checkout_started", "purchase_completed"]
      funnel <- expectCompiled =<< runEff (Query.runExperimentFunnel queryPool request experiment 604800 steps)
      Map.fromList
        [ ( (Map.lookup "index" (point ^. #group), Map.lookup "variant" (point ^. #group)),
            point ^. #value
          )
        | point <- funnel ^. #points
        ]
        `shouldBe` Map.fromList
          [ ((Just "1", Just "control"), 1),
            ((Just "2", Just "control"), 1),
            ((Just "1", Just "treatment"), 2),
            ((Just "2", Just "treatment"), 1)
          ]

type SleepColumns = '[Column "s" UInt8]

newtype SleepRow = SleepRow {s :: Word8}
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ClickHaskell SleepColumns)

sleep1Select :: Select SleepColumns SleepRow
sleep1Select = unsafeMkSelect (const "SELECT toUInt8(sleep(1)) AS s")

timedSleeps :: Int -> ClickHouseConfig -> IO NominalDiffTime
timedSleeps poolSize cfg = do
  queryPool <- newQueryPool cfg poolSize
  started <- getCurrentTime
  _ <- mapConcurrently (\_ -> withQueryConnection queryPool (\conn -> select sleep1Select conn pure)) [1 :: Int .. 4]
  finished <- getCurrentTime
  pure (diffUTCTime finished started)

requireBuiltinMetric :: Text -> IO BuiltinMetric
requireBuiltinMetric name =
  maybe (fail ("missing builtin metric: " <> show name)) pure (builtinMetric name)

sampleEvent :: Text -> Text -> AnalyticsEvent
sampleEvent eid name =
  baseEvent (EventId eid) (EventName name) Web (read "2026-07-01 12:00:00 UTC") (read "2026-07-01 12:00:01 UTC")
    & #accountId
    .~ Just (AccountId "acct_query")
    & #userId
    .~ Just (UserId "user_query")
    & #sourceService
    .~ Just "query-integration-spec"
    & #properties
    .~ KeyMap.fromList [("url", "https://example.com/query")]
    & #context
    .~ KeyMap.fromList [("userAgent", "hspec")]

propertyEvent :: Text -> Text -> Text -> [(Key, Aeson.Value)] -> AnalyticsEvent
propertyEvent eid name user properties =
  baseEvent (EventId eid) (EventName name) Web (read "2026-07-01 12:00:00 UTC") (read "2026-07-01 12:00:01 UTC")
    & #accountId
    .~ Just (AccountId "acct_query")
    & #userId
    .~ Just (UserId user)
    & #properties
    .~ KeyMap.fromList properties

funnelEvent :: Text -> Text -> Text -> String -> AnalyticsEvent
funnelEvent eid name user timestamp =
  baseEvent (EventId eid) (EventName name) Web (read timestamp) (read timestamp)
    & #accountId
    .~ Just (AccountId "acct_funnel")
    & #userId
    .~ Just (UserId user)

experimentEvent :: Text -> Text -> Text -> Text -> String -> Maybe Text -> AnalyticsEvent
experimentEvent eid account name user timestamp variant =
  baseEvent (EventId eid) (EventName name) Web (read timestamp) (read timestamp)
    & #accountId
    .~ Just (AccountId account)
    & #userId
    .~ Just (UserId user)
    & #properties
    .~ case variant of
      Nothing -> KeyMap.empty
      Just variantName ->
        KeyMap.fromList
          [ ("experiment", Aeson.String "checkout_v2"),
            ("variant", Aeson.String variantName)
          ]

validSqlName :: Text -> IO SqlName
validSqlName value =
  case mkSqlName value of
    Right name -> pure name
    Left invalid -> expectationFailure ("invalid SQL name fixture: " <> Text.unpack invalid) >> fail "invalid SQL name fixture"

expectCompiled :: Either Query.QueryExecutionError a -> IO a
expectCompiled = \case
  Right value -> pure value
  Left err -> expectationFailure ("unexpected query compile error: " <> show err) >> fail "query compile failed"
