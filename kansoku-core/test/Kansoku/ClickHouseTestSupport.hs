module Kansoku.ClickHouseTestSupport
  ( requireConfig,
    resetTable,
    withClickHouse,
  )
where

import ClickHaskell (Connection, closeConnection, command, ping)
import Control.Exception (bracketOnError, finally)
import Kansoku.ClickHouse
import Kansoku.Config
import Kansoku.Exception (trySynchronous)
import System.Environment (lookupEnv)
import Test.Hspec (Expectation, expectationFailure, pendingWith)

requireConfig :: IO Config
requireConfig = do
  result <- loadConfig
  case result of
    Left err -> expectationFailure ("failed to load config: " <> show err) >> error "unreachable"
    Right cfg -> pure cfg

withClickHouse :: (Connection -> Expectation) -> Expectation
withClickHouse action = do
  cfg <- requireConfig
  setupResult <- trySynchronous $
    bracketOnError (openClickHouse (clickHouseConfigFromConfig cfg)) closeConnection $ \conn -> do
      ping conn
      _ <- countEvents conn
      pure conn
  case setupResult of
    Left err -> do
      required <- lookupEnv "KANSOKU_REQUIRED_INTEGRATION"
      if required == Just "1"
        then expectationFailure ("required ClickHouse unavailable: " <> show err)
        else pendingWith ("ClickHouse not reachable or schema missing (run `just ch-migrate`): " <> show err)
    Right conn -> action conn `finally` closeConnection conn

resetTable :: Connection -> IO ()
resetTable conn = do
  command conn "TRUNCATE TABLE analytics.events_raw"
  command conn "TRUNCATE TABLE analytics.sessions"
  command conn "TRUNCATE TABLE analytics.user_properties"
  command conn "TRUNCATE TABLE analytics.user_properties_once"
  command conn "TRUNCATE TABLE analytics.trait_event_erasures"
