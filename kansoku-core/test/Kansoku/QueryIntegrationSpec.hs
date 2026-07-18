module Kansoku.QueryIntegrationSpec (spec) where

import ClickHaskell (ClickHaskell, Column, Select, UInt8, select, unsafeMkSelect)
import Control.Concurrent.Async (mapConcurrently)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (NominalDiffTime, diffUTCTime)
import Data.Word (Word8)
import Effectful (runEff)
import Kansoku.Api.Metrics (TimeGrain (Day))
import Kansoku.ClickHouse
import Kansoku.ClickHouseTestSupport
import Kansoku.Event
import Kansoku.Metrics.Registry (BuiltinMetric, builtinMetric)
import Kansoku.Prelude
import Kansoku.Query qualified as Query
import Test.Hspec

spec :: Spec
spec = describe "Kansoku.Query integration" $ do
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
      result <-
        runEff $
          Query.run
            queryPool
            metric
            Query.QueryRequest
              { from = fromGregorian 2026 7 1,
                to = fromGregorian 2026 7 2,
                groupBy = Just ["event_name"],
                timeGrain = Just Day
              }
      let keys =
            [ groupValue
            | point <- result ^. #points,
              Just groupValue <- [Map.lookup "event_name" (point ^. #group)]
            ]
      keys `shouldContain` ["signup\tstep"]

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
