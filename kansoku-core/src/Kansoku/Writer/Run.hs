-- | Runtime wiring for the shibuya pgmq batch writer.
module Kansoku.Writer.Run
  ( runWriter,
  )
where

import ClickHaskell (Connection)
import Data.Generics.Labels ()
import Data.Int (Int32)
import Data.Text qualified as Text
import Data.Time.Clock (secondsToNominalDiffTime)
import Effectful (runEff)
import Effectful.Error.Static (runErrorNoCallStack)
import Hasql.Pool qualified as Pool
import Kansoku.Prelude
import Kansoku.Writer.Batch (writerBatchHandler)
import OpenTelemetry.Trace.Core qualified as OTel
import Pgmq.Effectful (QueueName, runPgmqTraced)
import Pgmq.Effectful.Interpreter (PgmqRuntimeError)
import Shibuya.Adapter.Pgmq qualified as PgmqAdapter
import Shibuya.App
  ( BatchConfig (..),
    ProcessorId (..),
    ShutdownConfig (..),
    SupervisionStrategy (..),
    defaultBatchConfig,
    defaultBatchKey,
    mkBatchProcessor,
    runApp,
    stopAppGracefully,
  )
import Shibuya.Telemetry.Effect (runTracing)

runWriter ::
  Pool.Pool ->
  OTel.Tracer ->
  Connection ->
  QueueName ->
  Int32 ->
  Int32 ->
  Int ->
  Int ->
  IO () ->
  IO ()
runWriter pool tracer clickHouse queueName visibilityTimeoutSec adapterBatchSize maxBatchSize maxLatencyMs waitForShutdown = do
  result <-
    runEff $
      runErrorNoCallStack @PgmqRuntimeError $
        runPgmqTraced pool tracer $
          runTracing tracer $ do
            adapter <-
              PgmqAdapter.pgmqAdapter $
                PgmqAdapter.defaultConfig queueName
                  & #visibilityTimeout
                  .~ visibilityTimeoutSec
                  & #batchSize
                  .~ adapterBatchSize
            let processor =
                  mkBatchProcessor
                    adapter
                    (writerBatchHandler clickHouse)
                    ( defaultBatchConfig
                        { batchSize = maxBatchSize,
                          batchTimeout = latencySeconds,
                          batchKey = const defaultBatchKey,
                          tickInterval = Nothing
                        }
                    )
            started <- runApp IgnoreFailures 100 [(ProcessorId "kansoku-writer", processor)]
            case started of
              Left err ->
                liftIO $ error ("kansoku writer failed to start: " <> show err)
              Right handle -> do
                liftIO waitForShutdown
                drained <- stopAppGracefully ShutdownConfig {drainTimeout = 30} handle
                unless drained $
                  liftIO $
                    putStrLn ("kansoku writer stopped before all messages drained" :: String)
  case result of
    Left err -> error ("kansoku writer pgmq error: " <> Text.unpack (Text.pack (show err)))
    Right () -> pure ()
  where
    latencySeconds =
      secondsToNominalDiffTime (fromIntegral maxLatencyMs / 1000)
