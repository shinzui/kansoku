module Kansoku.ClickHouseSpec (spec) where

import ClickHaskell (Connection, command, ping)
import Control.Exception (SomeException, try)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.Generics.Labels ()
import Kansoku.ClickHouse
import Kansoku.Config
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

withClickHouse :: (Connection -> Expectation) -> Expectation
withClickHouse action = do
  configResult <- loadConfig
  case configResult of
    Left err -> expectationFailure ("failed to load config: " <> show err)
    Right cfg -> do
      setupResult <- try @SomeException $ do
        bootstrap <- openBootstrapConnection (clickHouseConfigFromConfig cfg)
        ping bootstrap
        ensureSchema bootstrap
        conn <- openClickHouse (clickHouseConfigFromConfig cfg)
        ping conn
        pure conn
      case setupResult of
        Left err -> pendingWith ("ClickHouse not reachable: " <> show err)
        Right conn -> action conn

resetTable :: Connection -> IO ()
resetTable conn =
  command conn "TRUNCATE TABLE analytics.events_raw"

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
