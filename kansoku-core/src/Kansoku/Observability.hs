-- | Operational telemetry for the ingest pipeline: Prometheus instruments,
-- the writer heartbeat, and the queue-depth poller. Not to be confused with
-- Kansoku.Metrics.*, which is the analytics query product domain.
module Kansoku.Observability
  ( PipelineMetrics (..),
    registerPipelineMetrics,
    WriterHeartbeat,
    newWriterHeartbeat,
    beatWriter,
    lastWriterBeat,
    QueueDepthSample (..),
    QueueDepthCell,
    newQueueDepthCell,
    readQueueDepth,
    runQueueDepthPoller,
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception
  ( AsyncException,
    SomeException,
    fromException,
    throwIO,
    try,
  )
import Control.Monad (forever)
import Data.Generics.Labels ()
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Int (Int32, Int64)
import Data.Text qualified as Text
import Effectful (runEff)
import Effectful.Error.Static qualified as Error
import Hasql.Pool qualified as Pool
import Kansoku.Logging (logWarn, runLogStderr)
import Kansoku.Prelude
import Pgmq.Effectful (QueueName, queueMetrics, runPgmq)
import Pgmq.Effectful.Interpreter (PgmqRuntimeError)
import Prometheus qualified

data PipelineMetrics = PipelineMetrics
  { queueLength :: !Prometheus.Gauge,
    queueOldestMessageAgeSeconds :: !Prometheus.Gauge,
    writerBatchesTotal :: !Prometheus.Counter,
    writerEventsWrittenTotal :: !Prometheus.Counter,
    writerBatchFlushSeconds :: !Prometheus.Histogram,
    writerInsertFailuresTotal :: !Prometheus.Counter,
    writerDeadLettersTotal :: !Prometheus.Counter
  }
  deriving stock (Generic)

-- | Register all pipeline instruments in prometheus-client's global registry.
-- Call exactly once per process, before the HTTP server starts.
registerPipelineMetrics :: IO PipelineMetrics
registerPipelineMetrics = do
  queueLength <-
    Prometheus.register . Prometheus.gauge $
      Prometheus.Info "kansoku_queue_length" "Messages currently in the pgmq events queue."
  queueOldestMessageAgeSeconds <-
    Prometheus.register . Prometheus.gauge $
      Prometheus.Info
        "kansoku_queue_oldest_message_age_seconds"
        "Age in seconds of the oldest message in the queue; 0 when empty."
  writerBatchesTotal <-
    Prometheus.register . Prometheus.counter $
      Prometheus.Info "kansoku_writer_batches_total" "Batch handler invocations."
  writerEventsWrittenTotal <-
    Prometheus.register . Prometheus.counter $
      Prometheus.Info
        "kansoku_writer_events_written_total"
        "Events successfully inserted into ClickHouse."
  writerBatchFlushSeconds <-
    Prometheus.register $
      Prometheus.histogram
        (Prometheus.Info "kansoku_writer_batch_flush_seconds" "ClickHouse insert duration per batch.")
        Prometheus.defaultBuckets
  writerInsertFailuresTotal <-
    Prometheus.register . Prometheus.counter $
      Prometheus.Info
        "kansoku_writer_insert_failures_total"
        "Failed ClickHouse batch inserts (each retry attempt counts)."
  writerDeadLettersTotal <-
    Prometheus.register . Prometheus.counter $
      Prometheus.Info
        "kansoku_writer_dead_letters_total"
        "Messages dead-lettered because their payload could not be decoded."
  pure
    PipelineMetrics
      { queueLength,
        queueOldestMessageAgeSeconds,
        writerBatchesTotal,
        writerEventsWrittenTotal,
        writerBatchFlushSeconds,
        writerInsertFailuresTotal,
        writerDeadLettersTotal
      }

newtype WriterHeartbeat = WriterHeartbeat (IORef (Maybe UTCTime))

newWriterHeartbeat :: IO WriterHeartbeat
newWriterHeartbeat = WriterHeartbeat <$> newIORef Nothing

beatWriter :: WriterHeartbeat -> IO ()
beatWriter (WriterHeartbeat ref) = getCurrentTime >>= writeIORef ref . Just

lastWriterBeat :: WriterHeartbeat -> IO (Maybe UTCTime)
lastWriterBeat (WriterHeartbeat ref) = readIORef ref

data QueueDepthSample = QueueDepthSample
  { sampleQueueLength :: !Int64,
    sampleOldestAgeSec :: !(Maybe Int32),
    sampledAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)

newtype QueueDepthCell = QueueDepthCell (IORef (Maybe QueueDepthSample))

newQueueDepthCell :: IO QueueDepthCell
newQueueDepthCell = QueueDepthCell <$> newIORef Nothing

readQueueDepth :: QueueDepthCell -> IO (Maybe QueueDepthSample)
readQueueDepth (QueueDepthCell ref) = readIORef ref

-- | Poll pgmq metrics, publishing successful samples to the registry and cell.
-- Per-iteration failures are logged and skipped so transient Postgres failures
-- do not kill the service; readiness rejects stale samples in Milestone 3.
runQueueDepthPoller ::
  Pool.Pool -> QueueName -> PipelineMetrics -> QueueDepthCell -> Int -> IO ()
runQueueDepthPoller pool queueName metrics (QueueDepthCell cell) intervalSec = forever $ do
  result <-
    try @SomeException $
      runEff $
        Error.runErrorNoCallStack @PgmqRuntimeError $
          runPgmq pool $
            queueMetrics queueName
  case result of
    Right (Right queueSample) -> do
      now <- getCurrentTime
      Prometheus.setGauge
        (metrics ^. #queueLength)
        (fromIntegral (queueSample ^. #queueLength))
      Prometheus.setGauge
        (metrics ^. #queueOldestMessageAgeSeconds)
        (maybe 0 fromIntegral (queueSample ^. #oldestMsgAgeSec))
      writeIORef cell . Just $
        QueueDepthSample
          { sampleQueueLength = queueSample ^. #queueLength,
            sampleOldestAgeSec = queueSample ^. #oldestMsgAgeSec,
            sampledAt = now
          }
    Right (Left pgmqError) -> logPollError (show pgmqError)
    Left exception ->
      case fromException exception of
        Just asyncException -> throwIO (asyncException :: AsyncException)
        Nothing -> logPollError (show exception)
  threadDelay (intervalSec * 1_000_000)
  where
    logPollError detail =
      runEff $
        runLogStderr $
          logWarn ("queue-depth poll failed: " <> Text.pack detail)
