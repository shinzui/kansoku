module Main (main) where

import Control.Concurrent.Async (poll, race_, wait, withAsync)
import Control.Concurrent.MVar (newEmptyMVar, readMVar, tryPutMVar)
import Control.Exception (bracket)
import Data.Generics.Labels ()
import Data.Text qualified as Text
import Hasql.Pool qualified as Pool
import Kansoku.Admin.Keys (runIssueKey)
import Kansoku.ClickHouse
  ( clickHouseConfigFromConfig,
    closeQueryPool,
    metricsQueryLimitsFromConfig,
    newQueryPoolWithLimits,
    queryReachable,
  )
import Kansoku.Config (loadConfig)
import Kansoku.Event (AccountId (..))
import Kansoku.Ingest.Quarantine (runQuarantineCleanup)
import Kansoku.Ingest.Queue (eventsQueueName, provisionQueue)
import Kansoku.Maintenance (closeMaintenancePool, newMaintenancePool)
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
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import System.Posix.Signals (Handler (Catch), installHandler, sigINT, sigTERM)

main :: IO ()
main = do
  args <- getArgs
  case args of
    [] -> runServer
    "issue-key" : issueArgs -> runIssueKey issueArgs
    _ -> hPutStrLn stderr "usage: kansoku-server [issue-key --kind write|service --account ACCOUNT]" >> exitFailure

runServer :: IO ()
runServer = do
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
      bracket ((,) <$> createPool (cfg ^. #pgConnectionString) <*> newMaintenancePool (cfg ^. #pgConnectionString)) (\(pool, maintenance) -> Pool.release pool >> closeMaintenancePool maintenance) $ \(pool, maintenance) -> do
        provisionQueue pool queueName
        bracket (newQueryPoolWithLimits (clickHouseConfigFromConfig cfg) (cfg ^. #clickHouseQueryPoolSize) (metricsQueryLimitsFromConfig cfg)) closeQueryPool $ \queryPool ->
          bracket makeTelemetry shutdownTelemetry $ \telemetry -> do
            startedAt <- getCurrentTime
            let tracer = telemetry ^. #tracer
            metrics <- registerPipelineMetrics
            heartbeat <- newWriterHeartbeat
            queueDepth <- newQueueDepthCell
            withAsync
              ( runWriter
                  maintenance
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
                                  clickhouseReachable = queryReachable queryPool,
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
                         in do
                              app <- kansokuApp maintenance metrics cfg probe pool queueName queryPool
                              race_ (runQuarantineCleanup cfg metrics) $
                                race_
                                  (wait writerAsync)
                                  ( race_
                                      (wait pollerAsync)
                                      (runApp cfg (startServer ((telemetry ^. #httpMiddleware) app)))
                                  )
                    )
              )
