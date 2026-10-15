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
import Control.Monad (forever)
import Data.Generics.Labels ()
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Int (Int32, Int64)
import Data.Text qualified as Text
import Effectful (runEff)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Kansoku.Exception (trySynchronous)
import Kansoku.Logging (logWarn, runLogStderr)
import Kansoku.Prelude
import Pgmq qualified
import Pgmq.Types (QueueName, queueNameToText)
import Prometheus qualified

data PipelineMetrics = PipelineMetrics
  { queueLength :: !Prometheus.Gauge,
    queueArchiveLength :: !Prometheus.Gauge,
    queueOldestMessageAgeSeconds :: !Prometheus.Gauge,
    writerBatchesTotal :: !Prometheus.Counter,
    writerEventsWrittenTotal :: !Prometheus.Counter,
    writerBatchFlushSeconds :: !Prometheus.Histogram,
    writerInsertFailuresTotal :: !Prometheus.Counter,
    writerDeadLettersTotal :: !Prometheus.Counter,
    writerBreakerState :: !Prometheus.Gauge,
    writerRecoveryFailuresTotal :: !Prometheus.Counter,
    ingestEventsTotal :: !(Prometheus.Vector (Text, Text) Prometheus.Counter),
    ingestNewlyQueuedTotal :: !(Prometheus.Vector Text Prometheus.Counter),
    ingestRateLimitedRequestsTotal :: !(Prometheus.Vector Text Prometheus.Counter),
    ingestRejectionsTotal :: !(Prometheus.Vector (Text, Text) Prometheus.Counter),
    ingestTimestampAdjustmentsTotal :: !(Prometheus.Vector (Text, Text) Prometheus.Counter),
    quarantineFailuresTotal :: !Prometheus.Counter,
    quarantineCleanupLagSeconds :: !Prometheus.Gauge
  }
  deriving stock (Generic)

-- | Register all pipeline instruments in prometheus-client's global registry.
-- Call exactly once per process, before the HTTP server starts.
registerPipelineMetrics :: IO PipelineMetrics
registerPipelineMetrics = do
  queueLength <-
    Prometheus.register . Prometheus.gauge $
      Prometheus.Info "kansoku_queue_length" "Messages currently in the pgmq events queue."
  queueArchiveLength <- Prometheus.register $ Prometheus.gauge $ Prometheus.Info "kansoku_queue_archive_length" "Messages in the queue archive; sampled with queue depth."
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
        (Prometheus.Info "kansoku_writer_batch_flush_seconds" "Batch insert residence, including retained storage recovery.")
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
  writerBreakerState <- Prometheus.register $ Prometheus.gauge $ Prometheus.Info "kansoku_writer_breaker_state" "Writer source gate: 0 closed, 1 storage unavailable, 2 insert rejected/parked."
  writerRecoveryFailuresTotal <- Prometheus.register $ Prometheus.counter $ Prometheus.Info "kansoku_writer_recovery_failures_total" "Failed recovery probes and reinserts."
  ingestEventsTotal <-
    Prometheus.register $
      Prometheus.vector ("outcome", "transport") $
        Prometheus.counter (Prometheus.Info "kansoku_ingest_events_total" "Validated ingest outcomes; acceptance follows queue commit.")
  ingestNewlyQueuedTotal <- Prometheus.register $ Prometheus.vector "transport" $ Prometheus.counter $ Prometheus.Info "kansoku_ingest_newly_queued_total" "New immutable event identities committed to the queue; equal retries excluded."
  ingestRateLimitedRequestsTotal <- Prometheus.register $ Prometheus.vector "transport" $ Prometheus.counter $ Prometheus.Info "kansoku_ingest_rate_limited_requests_total" "Ingest requests denied before normalization or persistence."
  ingestRejectionsTotal <-
    Prometheus.register $
      Prometheus.vector ("reason", "transport") $
        Prometheus.counter (Prometheus.Info "kansoku_ingest_rejections_total" "Distinct validation reasons per rejected event.")
  ingestTimestampAdjustmentsTotal <-
    Prometheus.register $
      Prometheus.vector ("adjustment", "transport") $
        Prometheus.counter (Prometheus.Info "kansoku_ingest_timestamp_adjustments_total" "Ingest timestamp adjustments.")
  quarantineFailuresTotal <-
    Prometheus.register $
      Prometheus.counter $
        Prometheus.Info "kansoku_ingest_quarantine_failures_total" "Failed or timed-out quarantine writes and cleanup operations."
  quarantineCleanupLagSeconds <-
    Prometheus.register $
      Prometheus.gauge $
        Prometheus.Info "kansoku_ingest_quarantine_cleanup_lag_seconds" "Seconds since last successful quarantine cleanup; sampled each minute."
  pure
    PipelineMetrics
      { queueLength,
        queueArchiveLength,
        queueOldestMessageAgeSeconds,
        writerBatchesTotal,
        writerEventsWrittenTotal,
        writerBatchFlushSeconds,
        writerInsertFailuresTotal,
        writerDeadLettersTotal,
        writerBreakerState,
        writerRecoveryFailuresTotal,
        ingestEventsTotal,
        ingestNewlyQueuedTotal,
        ingestRateLimitedRequestsTotal,
        ingestRejectionsTotal,
        ingestTimestampAdjustmentsTotal,
        quarantineFailuresTotal,
        quarantineCleanupLagSeconds
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
    trySynchronous $
      Pool.use pool $
        (,) <$> Pgmq.queueMetrics queueName <*> Session.statement () archiveCount
  case result of
    Right (Right (queueSample, archived)) -> do
      Prometheus.setGauge (metrics ^. #queueArchiveLength) (fromIntegral archived)
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
    Left exception -> logPollError (show exception)
  threadDelay (intervalSec * 1_000_000)
  where
    -- QueueName construction permits only bounded lowercase ASCII/digit/_;
    -- this administrative identifier cannot contain SQL syntax.
    archiveCount =
      Statement.preparable
        ("SELECT count(*) FROM pgmq.a_" <> queueNameToText queueName)
        E.noParams
        (D.singleRow (D.column (D.nonNullable D.int8)))
    logPollError detail =
      runEff $
        runLogStderr $
          logWarn ("queue-depth poll failed: " <> Text.pack detail)
