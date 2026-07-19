module Main (main) where

import Control.Concurrent.Async (poll, race_, wait, withAsync)
import Control.Concurrent.MVar (newEmptyMVar, readMVar, tryPutMVar)
import Control.Exception (bracket)
import Data.Generics.Labels ()
import Hasql.Pool qualified as Pool
import Kansoku.ClickHouse
  ( clickHouseConfigFromConfig,
    newQueryPool,
  )
import Kansoku.Config (loadConfig)
import Kansoku.Ingest.Queue (eventsQueueName, provisionQueue)
import Kansoku.Observability
  ( lastWriterBeat,
    newQueueDepthCell,
    newWriterHeartbeat,
    readQueueDepth,
    registerPipelineMetrics,
    runQueueDepthPoller,
  )
import Kansoku.Postgres (createPool)
import Kansoku.Prelude
import Kansoku.Readiness
  ( ReadyThresholds (..),
    evaluatePipelineReadiness,
  )
import Kansoku.Runtime (runApp)
import Kansoku.Server (ReadyProbe (..), kansokuApp, pgmqReady, startServer)
import Kansoku.Telemetry (Telemetry (..), makeTelemetry)
import Kansoku.Writer.Run (runWriter)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import System.Posix.Signals (Handler (Catch), installHandler, sigINT, sigTERM)

main :: IO ()
main = do
  shutdownVar <- newEmptyMVar
  let requestShutdown = void (tryPutMVar shutdownVar ())
  void $ installHandler sigTERM (Catch requestShutdown) Nothing
  void $ installHandler sigINT (Catch requestShutdown) Nothing
  result <- loadConfig
  case result of
    Left err -> do
      hPutStrLn stderr ("configuration error: " <> show err)
      exitFailure
    Right cfg -> do
      let queueName = eventsQueueName (cfg ^. #eventsQueueName)
      bracket (createPool (cfg ^. #pgConnectionString)) Pool.release $ \pool -> do
        provisionQueue pool queueName
        queryPool <- newQueryPool (clickHouseConfigFromConfig cfg) (cfg ^. #clickHouseQueryPoolSize)
        bracket makeTelemetry shutdownTelemetry $ \telemetry -> do
          startedAt <- getCurrentTime
          let tracer = telemetry ^. #tracer
          metrics <- registerPipelineMetrics
          heartbeat <- newWriterHeartbeat
          queueDepth <- newQueueDepthCell
          withAsync
            ( runWriter
                metrics
                heartbeat
                pool
                tracer
                (clickHouseConfigFromConfig cfg)
                queueName
                (cfg ^. #writerVisibilityTimeoutSec)
                (cfg ^. #writerAdapterBatchSize)
                (cfg ^. #writerMaxBatchSize)
                (cfg ^. #writerMaxLatencyMs)
                (readMVar shutdownVar)
            )
            ( \writerAsync ->
                withAsync
                  ( runQueueDepthPoller
                      pool
                      queueName
                      metrics
                      queueDepth
                      (cfg ^. #queuePollIntervalSec)
                  )
                  ( \pollerAsync ->
                      let probe =
                            ReadyProbe
                              { writerAlive = isNothing <$> poll writerAsync,
                                pgmqReachable = pgmqReady pool queueName,
                                pipelineReady = do
                                  queueSample <- readQueueDepth queueDepth
                                  lastFlush <- lastWriterBeat heartbeat
                                  now <- getCurrentTime
                                  pure $
                                    evaluatePipelineReadiness
                                      ReadyThresholds
                                        { maxQueueDepth = cfg ^. #readyMaxQueueDepth,
                                          maxFlushAgeSec = cfg ^. #readyMaxFlushAgeSec,
                                          sampleMaxAgeSec = 3 * (cfg ^. #queuePollIntervalSec)
                                        }
                                      startedAt
                                      queueSample
                                      lastFlush
                                      now
                              }
                          app = kansokuApp cfg probe pool queueName queryPool
                       in race_
                            (wait writerAsync)
                            ( race_
                                (wait pollerAsync)
                                (runApp cfg (startServer app))
                            )
                  )
            )
