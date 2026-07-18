module Kansoku.ClickHouseSpec (spec) where

import ClickHaskell (ClickHaskell, Column, Select, UInt8, command, select, unsafeMkSelect)
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (wait, withAsync)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Data.Time.Clock (diffUTCTime)
import Data.Word (Word8)
import Kansoku.ClickHouse
import Kansoku.ClickHouseTestSupport
import Kansoku.Event
import Kansoku.Prelude
import Test.Hspec

spec :: Spec
spec = describe "Kansoku.ClickHouse" $ do
  it "ensures the schema, inserts events, and reads a projection back" $
    withClickHouse $ \conn -> do
      resetTable conn
      insertEvents conn [sampleEvent "evt_storage_1" "page_view", sampleEvent "evt_storage_2" "signup"]
      countEvents conn `shouldReturn` 2
      rows <- selectEventProjections conn
      rows `shouldContain` [expectedProjection "evt_storage_1" "page_view"]
      rows `shouldContain` [expectedProjection "evt_storage_2" "signup"]

  it "collapses replayed events after a final ReplacingMergeTree merge" $
    withClickHouse $ \conn -> do
      resetTable conn
      let event = sampleEvent "evt_storage_dedup" "page_view"
      insertEvents conn [event]
      insertEvents conn [event]
      countEvents conn `shouldReturn` 2
      command conn "OPTIMIZE TABLE analytics.events_raw FINAL"
      countEvents conn `shouldReturn` 1

  describe "connection ownership" $
    it "does not block a writer insert behind a slow query on another connection" $
      withClickHouse $ \queryConn -> do
        resetTable queryConn
        writerConn <- openClickHouse . clickHouseConfigFromConfig =<< requireConfig
        withAsync (select sleepSelect queryConn pure) $ \slow -> do
          threadDelay 100_000
          started <- getCurrentTime
          insertEvents writerConn [sampleEvent "evt_split_1" "page_view"]
          finished <- getCurrentTime
          _ <- wait slow
          diffUTCTime finished started `shouldSatisfy` (< 1)

type SleepColumns = '[Column "s" UInt8]

newtype SleepRow = SleepRow {s :: Word8}
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ClickHaskell SleepColumns)

sleepSelect :: Select SleepColumns SleepRow
sleepSelect = unsafeMkSelect (const "SELECT toUInt8(sleep(2)) AS s")

sampleEvent :: Text -> Text -> AnalyticsEvent
sampleEvent eid name =
  baseEvent (EventId eid) (EventName name) Web (read "2026-07-01 12:00:00 UTC") (read "2026-07-01 12:00:01 UTC")
    & #accountId
    .~ Just (AccountId "acct_storage")
    & #userId
    .~ Just (UserId "user_storage")
    & #sourceService
    .~ Just "storage-spec"
    & #properties
    .~ KeyMap.fromList [("url", "https://example.com/storage")]
    & #context
    .~ KeyMap.fromList [("userAgent", "hspec")]

expectedProjection :: ByteString -> ByteString -> EventProjection
expectedProjection eid name =
  EventProjection
    { event_id = eid,
      event_name = name,
      source = "web",
      account_id = "acct_storage",
      user_id = "user_storage"
    }
