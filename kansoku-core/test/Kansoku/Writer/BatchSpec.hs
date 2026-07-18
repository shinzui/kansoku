module Kansoku.Writer.BatchSpec (spec) where

import ClickHaskell (Connection, command, ping)
import Control.Exception (SomeException, try)
import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.HashMap.Strict qualified as HashMap
import Effectful (IOE, runEff)
import Kansoku.ClickHouse
  ( clickHouseConfigFromConfig,
    countEvents,
    openClickHouse,
  )
import Kansoku.Config (loadConfig)
import Kansoku.Event
  ( AnalyticsEvent,
    EventId (..),
    EventName (..),
    EventSource (..),
    baseEvent,
  )
import Kansoku.Prelude
import Kansoku.Writer.Batch (writerBatchHandler)
import Shibuya.Batch
  ( BatchInfo (..),
    BatchTrigger (..),
    defaultBatchKey,
  )
import Shibuya.Core.Ingested (Message (..))
import Shibuya.Core.Types (Envelope (..), MessageId (..))
import Test.Hspec

spec :: Spec
spec = describe "Kansoku.Writer.Batch" $ do
  it "decodes a pgmq payload and inserts it into ClickHouse" $
    withClickHouse $ \conn -> do
      command conn "TRUNCATE TABLE analytics.events_raw"
      countBefore <- countEvents conn
      _ <- runEff (writerBatchHandler conn batchInfo (handlerMessage :| []))
      countAfter <- countEvents conn
      countAfter `shouldBe` countBefore + 1

withClickHouse :: (Connection -> Expectation) -> Expectation
withClickHouse action = do
  configResult <- loadConfig
  case configResult of
    Left err -> expectationFailure ("failed to load config: " <> show err)
    Right cfg -> do
      setupResult <- try @SomeException $ do
        conn <- openClickHouse (clickHouseConfigFromConfig cfg)
        ping conn
        _ <- countEvents conn
        pure conn
      case setupResult of
        Left err ->
          pendingWith
            ("ClickHouse not reachable or schema missing (run `just ch-migrate`): " <> show err)
        Right conn -> action conn

batchInfo :: BatchInfo
batchInfo =
  BatchInfo
    { batchKey = defaultBatchKey,
      size = 1,
      trigger = TriggerSize,
      partition = Nothing
    }

handlerMessage :: Message '[IOE] Value
handlerMessage =
  Message
    { envelope =
        Envelope
          { messageId = MessageId "writer-spec-1",
            cursor = Nothing,
            partition = Nothing,
            enqueuedAt = Nothing,
            traceContext = Nothing,
            headers = Nothing,
            attempt = Nothing,
            attributes = HashMap.empty,
            payload = Aeson.toJSON sampleEvent
          },
      lease = Nothing
    }

sampleEvent :: AnalyticsEvent
sampleEvent =
  baseEvent
    (EventId "evt_writer_batch")
    (EventName "page_viewed")
    Web
    (read "2026-07-01 12:00:00 UTC")
    (read "2026-07-01 12:00:01 UTC")
