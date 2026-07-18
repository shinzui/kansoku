module Kansoku.ClickHouseTestSupport
  ( requireConfig,
    resetTable,
    withClickHouse,
  )
where

import ClickHaskell (Connection, command, ping)
import Control.Exception (SomeException, try)
import Kansoku.ClickHouse
import Kansoku.Config
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
  setupResult <- try @SomeException $ do
    bootstrap <- openBootstrapConnection (clickHouseConfigFromConfig cfg)
    ping bootstrap
    ensureSchema bootstrap
    conn <- openClickHouse (clickHouseConfigFromConfig cfg)
    ping conn
    pure conn
  case setupResult of
    Left err -> pendingWith ("ClickHouse not reachable: " <> show err)
    Right conn -> action conn

resetTable :: Connection -> IO ()
resetTable conn =
  command conn "TRUNCATE TABLE analytics.events_raw"
