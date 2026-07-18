module Main (main) where

import Control.Concurrent.Async (race_, wait, withAsync)
import Control.Concurrent.MVar (newEmptyMVar, readMVar, tryPutMVar)
import Control.Exception (bracket)
import Data.Generics.Labels ()
import Hasql.Pool qualified as Pool
import Kansoku.ClickHouse
  ( clickHouseConfigFromConfig,
    openClickHouse,
  )
import Kansoku.Config (loadConfig)
import Kansoku.Ingest.Queue (eventsQueueName, provisionQueue)
import Kansoku.Postgres (createPool)
import Kansoku.Prelude
import Kansoku.Runtime (runApp)
import Kansoku.Server (kansokuApp, startServer)
import Kansoku.Telemetry (makeTracer)
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
        clickHouse <- openClickHouse (clickHouseConfigFromConfig cfg)
        tracer <- makeTracer
        let app = kansokuApp pool queueName clickHouse
        withAsync
          ( runWriter
              pool
              tracer
              clickHouse
              queueName
              (cfg ^. #writerVisibilityTimeoutSec)
              (cfg ^. #writerAdapterBatchSize)
              (cfg ^. #writerMaxBatchSize)
              (cfg ^. #writerMaxLatencyMs)
              (readMVar shutdownVar)
          )
          ( \writerAsync ->
              race_
                (wait writerAsync)
                (runApp cfg (startServer app))
          )
