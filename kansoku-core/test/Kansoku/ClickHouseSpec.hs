module Kansoku.ClickHouseSpec (spec) where

import ClickHaskell (ClickHaskell, ClientError (UnmatchedResult), Column, Float64, Select, UInt8, command, select, unsafeMkSelect)
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
      let appSignup = sampleEvent "evt_storage_2" "signup" & #source .~ App
      insertEvents conn [sampleEvent "evt_storage_1" "page_view", appSignup]
      countEvents conn `shouldReturn` 2
      rows <- selectEventProjections conn
      rows `shouldContain` [expectedProjection "evt_storage_1" "page_view"]
      rows `shouldContain` [expectedProjectionWithSource "evt_storage_2" "signup" "app"]

  it "collapses replayed events after a final ReplacingMergeTree merge" $
    withClickHouse $ \conn -> do
      resetTable conn
      let event = sampleEvent "evt_storage_dedup" "page_view"
      insertEvents conn [event]
      insertEvents conn [event]
      countEvents conn `shouldReturn` 2
      command conn "OPTIMIZE TABLE analytics.events_raw FINAL"
      countEvents conn `shouldReturn` 1

  it "round-trips an event name containing a tab through projections" $
    withClickHouse $ \conn -> do
      resetTable conn
      insertEvents conn [sampleEvent "evt_tab_1" "signup\tstep"]
      rows <- selectEventProjections conn
      rows `shouldContain` [expectedProjection "evt_tab_1" "signup\tstep"]

  it "raises on a column type mismatch instead of fabricating values" $
    withClickHouse $ \conn ->
      select mistypedSelect conn pure
        `shouldThrow` \case
          UnmatchedResult _ -> True
          _ -> False

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

type MistypedColumns = '[Column "value" Float64]

newtype MistypedRow = MistypedRow {value :: Double}
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ClickHaskell MistypedColumns)

mistypedSelect :: Select MistypedColumns MistypedRow
mistypedSelect = unsafeMkSelect (const "SELECT 'oops' AS value")

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
  expectedProjectionWithSource eid name "web"

expectedProjectionWithSource :: ByteString -> ByteString -> ByteString -> EventProjection
expectedProjectionWithSource eid name sourceName =
  EventProjection
    { event_id = eid,
      event_name = name,
      source = sourceName,
      account_id = "acct_storage",
      user_id = "user_storage"
    }
