module Kansoku.Writer.BatchSpec (spec) where

import ClickHaskell (Connection, command, ping)
import Control.Concurrent.Async (AsyncCancelled (..))
import Control.Exception (SomeException, fromException, throwIO, try)
import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.HashMap.Strict qualified as HashMap
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Effectful (IOE, runEff)
import Kansoku.ClickHouse
  ( clickHouseConfigFromConfig,
    countEvents,
    insertQueuedEvents,
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
import Kansoku.Observability
  ( PipelineMetrics,
    lastWriterBeat,
    newWriterHeartbeat,
  )
import Kansoku.Prelude
import Kansoku.Writer.Batch (writerBatchHandler)
import Kansoku.Writer.Recovery
import Prometheus qualified
import Shibuya.Batch
  ( BatchInfo (..),
    BatchTrigger (..),
    defaultBatchKey,
  )
import Shibuya.Core.Ack (AckDecision (..), RetryDelay (..))
import Shibuya.Core.Ingested (Message (..))
import Shibuya.Core.Types (Envelope (..), MessageId (..))
import Test.Hspec

spec :: PipelineMetrics -> Spec
spec metrics = describe "Kansoku.Writer.Batch" $ do
  it "decodes a pgmq payload and inserts it into ClickHouse" $
    withClickHouse $ \conn -> do
      command conn "TRUNCATE TABLE analytics.events_raw"
      countBefore <- countEvents conn
      batchesBefore <- Prometheus.getCounter (metrics ^. #writerBatchesTotal)
      eventsBefore <- Prometheus.getCounter (metrics ^. #writerEventsWrittenTotal)
      heartbeat <- newWriterHeartbeat
      _ <- runEff (writerBatchHandler metrics heartbeat (insertQueuedEvents conn) batchInfo (handlerMessage :| []))
      countAfter <- countEvents conn
      countAfter `shouldBe` countBefore + 1
      Prometheus.getCounter (metrics ^. #writerBatchesTotal)
        `shouldReturn` (batchesBefore + 1)
      Prometheus.getCounter (metrics ^. #writerEventsWrittenTotal)
        `shouldReturn` (eventsBefore + 1)
      latest <- lastWriterBeat heartbeat
      latest `shouldSatisfy` isJust

  it "counts decode failures as dead letters and still beats" $ do
    deadLettersBefore <- Prometheus.getCounter (metrics ^. #writerDeadLettersTotal)
    heartbeat <- newWriterHeartbeat
    _ <-
      runEff
        ( writerBatchHandler
            metrics
            heartbeat
            (error "ClickHouse must not be forced for an all-invalid batch")
            batchInfo
            (invalidHandlerMessage :| [])
        )
    Prometheus.getCounter (metrics ^. #writerDeadLettersTotal)
      `shouldReturn` (deadLettersBefore + 1)
    latest <- lastWriterBeat heartbeat
    latest `shouldSatisfy` isJust

  it "propagates asynchronous insert cancellation to Shibuya" $ do
    heartbeat <- newWriterHeartbeat
    result <- try @SomeException $ runEff (writerBatchHandler metrics heartbeat (\_ -> throwIO AsyncCancelled) batchInfo (handlerMessage :| []))
    case result of
      Left err -> (fromException err :: Maybe AsyncCancelled) `shouldBe` Just AsyncCancelled
      Right _ -> expectationFailure "writer swallowed asynchronous cancellation"

  it "keeps a committed insert logically unique after its result is lost and the queue redelivers" $
    withClickHouse $ \conn -> do
      command conn "TRUNCATE TABLE analytics.events_raw"
      heartbeat <- newWriterHeartbeat
      let lostResult events = insertQueuedEvents conn events >> ioError (userError "injected lost insert confirmation")
      retried <- runEff (writerBatchHandler metrics heartbeat lostResult batchInfo (handlerMessage :| []))
      retried ^. #fallback `shouldBe` AckRetry (RetryDelay 5)
      countEvents conn `shouldReturn` 1
      _ <- runEff (writerBatchHandler metrics heartbeat (insertQueuedEvents conn) batchInfo (handlerMessage :| []))
      countEvents conn `shouldReturn` 1

  it "retries every decodable message when the ClickHouse insert fails" $ do
    failuresBefore <- Prometheus.getCounter (metrics ^. #writerInsertFailuresTotal)
    eventsBefore <- Prometheus.getCounter (metrics ^. #writerEventsWrittenTotal)
    heartbeat <- newWriterHeartbeat
    batchAck <-
      runEff
        ( writerBatchHandler
            metrics
            heartbeat
            (\_ -> ioError (userError "ClickHouse unavailable"))
            batchInfo
            (handlerMessage :| [])
        )
    batchAck ^. #fallback `shouldBe` AckRetry (RetryDelay 5)
    Prometheus.getCounter (metrics ^. #writerInsertFailuresTotal)
      `shouldReturn` (failuresBefore + 1)
    Prometheus.getCounter (metrics ^. #writerEventsWrittenTotal)
      `shouldReturn` eventsBefore
    lastWriterBeat heartbeat `shouldReturn` Nothing

  it "retains a committed batch after lost confirmation and only acknowledges its successful retry" $
    withClickHouse $ \conn -> do
      command conn "TRUNCATE TABLE analytics.events_raw"
      heartbeat <- newWriterHeartbeat
      attempts <- newIORef (0 :: Int)
      recovery <- newWriterRecovery (defaultRecoveryPolicy {probeIntervalMicros = 1000}) metrics (ping conn)
      let insert events = do
            number <- atomicModifyIORef' attempts (\n -> (n + 1, n))
            insertQueuedEvents conn events
            when (number == 0) $ ioError (userError "injected lost committed insert confirmation")
      ack <- runEff (writerBatchHandler metrics heartbeat (recoverInsert recovery (pure ()) insert) batchInfo (handlerMessage :| []))
      ack ^. #fallback `shouldBe` AckOk
      readIORef attempts `shouldReturn` 2
      readBreakerState recovery `shouldReturn` Closed
      countEvents conn `shouldReturn` 1

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

invalidHandlerMessage :: Message '[IOE] Value
invalidHandlerMessage =
  case handlerMessage of
    Message {envelope = originalEnvelope, lease} ->
      Message
        { envelope =
            originalEnvelope
              { messageId = MessageId "writer-spec-invalid",
                payload = Aeson.String "not an event"
              },
          lease
        }

sampleEvent :: AnalyticsEvent
sampleEvent =
  baseEvent
    (EventId "evt_writer_batch")
    (EventName "page_viewed")
    Web
    (read "2026-07-01 12:00:00 UTC")
    (read "2026-07-01 12:00:01 UTC")
