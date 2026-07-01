module Main (main) where

import Kansoku.Config (loadConfig)
import Kansoku.Runtime (runApp)
import Kansoku.Server (startServer)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
  result <- loadConfig
  case result of
    Left err -> do
      hPutStrLn stderr ("configuration error: " <> show err)
      exitFailure
    Right cfg ->
      runApp cfg startServer
