-- | Runtime wiring for the shibuya pgmq batch writer.
module Kansoku.Writer.Run
  ( runWriter,
  )
where

import ClickHaskell (closeConnection, ping)
import Control.Exception (bracket)
import Control.Monad (forM)
import Data.Foldable (toList)
import Data.Generics.Labels ()
import Data.Int (Int32, Int64)
import Data.Text qualified as Text
import Data.Time.Clock (secondsToNominalDiffTime)
import Effectful (runEff)
import Effectful.Concurrent qualified as Concurrent
import Effectful.Concurrent.Async qualified as Async
import Effectful.Error.Static (runErrorNoCallStack)
import Hasql.Pool qualified as Pool
import Kansoku.ClickHouse
  ( ClickHouseConfig,
    insertWriterEvents,
    newWriterConnection,
    openClickHouse,
  )
import Kansoku.Observability (PipelineMetrics, WriterHeartbeat)
import Kansoku.Prelude
import Kansoku.Writer.Batch (writerBatchHandler)
import Kansoku.Writer.Recovery (defaultRecoveryPolicy, gateAdapter, newWriterRecovery, recoverInsert)
import OpenTelemetry.Trace.Core qualified as OTel
import Pgmq qualified
import Pgmq.Effectful (QueueName, runPgmqTraced)
import Pgmq.Effectful.Interpreter (PgmqRuntimeError)
import Pgmq.Hasql.Statements.Types (BatchVisibilityTimeoutQuery (..))
import Pgmq.Types qualified as PgmqTypes
import Shibuya.Adapter.Pgmq qualified as PgmqAdapter
import Shibuya.App
  ( AppConfig (..),
    BatchConfig (..),
    ProcessorId (..),
    ShutdownConfig (..),
    SupervisionStrategy (..),
    defaultBatchConfig,
    defaultBatchKey,
    defaultShutdownConfig,
    mkBatchProcessor,
    runApp,
    stopAppGracefully,
    waitApp,
  )
import Shibuya.Core.Ingested (Message (..))
import Shibuya.Core.Types qualified as Shibuya
import Shibuya.Telemetry.Effect (runTracing)
import Text.Read (readMaybe)

runWriter ::
  PipelineMetrics ->
  WriterHeartbeat ->
  Pool.Pool ->
  OTel.Tracer ->
  ClickHouseConfig ->
  QueueName ->
  Int32 ->
  Int32 ->
  Int ->
  Int ->
  IO () ->
  IO ()
runWriter metrics heartbeat pool tracer clickHouseConfig queueName visibilityTimeoutSec adapterBatchSize maxBatchSize maxLatencyMs waitForShutdown = do
  clickHouse <- newWriterConnection clickHouseConfig
  recovery <- newWriterRecovery defaultRecoveryPolicy metrics (bracket (openClickHouse clickHouseConfig) closeConnection ping)
  result <-
    runEff $
      Concurrent.runConcurrent $
        runErrorNoCallStack @PgmqRuntimeError $
          runPgmqTraced pool tracer $
            runTracing tracer $ do
              adapter <-
                PgmqAdapter.pgmqAdapter
                  (PgmqAdapter.mkPgmqAdapterEnv pool)
                  ( PgmqAdapter.defaultConfig queueName
                      & #visibilityTimeout
                      .~ visibilityTimeoutSec
                      & #batchSize
                      .~ adapterBatchSize
                      & #maxRetries
                      .~ (maxBound :: Int64)
                      & #prefetchConfig
                      .~ Nothing
                  )
                  >>= \case
                    Left err ->
                      liftIO $ error ("invalid kansoku writer pgmq adapter configuration: " <> show err)
                    Right configuredAdapter -> pure configuredAdapter
              let processor =
                    mkBatchProcessor
                      (gateAdapter recovery adapter)
                      (\info messages -> writerBatchHandler metrics heartbeat (recoverInsert recovery (renewBatch messages) (insertWriterEvents clickHouse)) info messages)
                      ( defaultBatchConfig
                          { batchSize = maxBatchSize,
                            batchTimeout = latencySeconds,
                            batchKey = const defaultBatchKey,
                            tickInterval = Nothing
                          }
                      )
              started <-
                runApp
                  AppConfig
                    { strategy = StopAllOnFailure,
                      inboxSize = 1
                    }
                  [(ProcessorId "kansoku-writer", processor)]
              case started of
                Left err ->
                  liftIO $ error ("kansoku writer failed to start: " <> show err)
                Right handle -> do
                  outcome <- Async.race (liftIO waitForShutdown) (waitApp handle)
                  case outcome of
                    Left () -> do
                      drained <- stopAppGracefully defaultShutdownConfig {drainTimeout = 30, totalShutdownTimeout = 35} handle
                      unless drained $
                        liftIO $
                          putStrLn ("kansoku writer stopped before all messages drained" :: String)
                    Right () ->
                      liftIO $ error "kansoku writer stopped unexpectedly"
  case result of
    Left err -> error ("kansoku writer pgmq error: " <> Text.unpack (Text.pack (show err)))
    Right () -> pure ()
  where
    latencySeconds =
      secondsToNominalDiffTime (fromIntegral maxLatencyMs / 1000)

    -- The selected public adapter maps its server-assigned numeric PGMQ IDs to
    -- decimal Shibuya message IDs. Batch renewal avoids one roundtrip per lease
    -- on large retained batches. Missing rows after another ack are normal.
    renewBatch messages = do
      ids <- forM (toList messages) $ \Message {envelope = Shibuya.Envelope {messageId = Shibuya.MessageId raw}} ->
        maybe (fail "unexpected PGMQ writer message identity") (pure . PgmqTypes.MessageId) (readMaybe (Text.unpack raw))
      renewed <-
        Pool.use pool $
          Pgmq.batchChangeVisibilityTimeout
            BatchVisibilityTimeoutQuery
              { queueName,
                messageIds = ids,
                visibilityTimeoutOffset = max 60 visibilityTimeoutSec
              }
      either (const (fail "writer lease renewal failed")) (const (pure ())) renewed
