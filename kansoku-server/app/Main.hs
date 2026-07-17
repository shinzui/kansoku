module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (withAsync)
import Control.Exception (bracket)
import Control.Monad (forever)
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

main :: IO ()
main = do
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
            keepRunning = forever (threadDelay 1000000000)
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
              keepRunning
          )
          (const (runApp cfg (startServer app)))
