module Kansoku.ConfigSpec (spec) where

import Data.Generics.Labels ()
import Kansoku.Config (loadConfig)
import Kansoku.Prelude
import System.Environment (setEnv, unsetEnv)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

-- | Ensure a clean slate for the variables loadConfig reads.
clearEnv :: IO ()
clearEnv =
  mapM_
    unsetEnv
    [ "PG_CONNECTION_STRING",
      "KANSOKU_CLICKHOUSE_HOST",
      "KANSOKU_CLICKHOUSE_DATABASE",
      "KANSOKU_CLICKHOUSE_USER",
      "KANSOKU_CLICKHOUSE_PASSWORD",
      "CLICKHOUSE_TCP_PORT",
      "CLICKHOUSE_HTTP_PORT",
      "KANSOKU_QUEUE_NAME",
      "KANSOKU_WRITER_MAX_BATCH",
      "KANSOKU_WRITER_MAX_LATENCY_MS",
      "KANSOKU_WRITER_VT_SEC",
      "KANSOKU_WRITER_ADAPTER_BATCH",
      "KANSOKU_SERVER_PORT"
    ]

spec :: Spec
spec = describe "Kansoku.Config.loadConfig" $ do
  it "uses defaults when nothing is set" $ do
    clearEnv
    result <- loadConfig
    case result of
      Left err -> fail ("expected defaults, got error: " <> show err)
      Right cfg -> do
        (cfg ^. #clickHouseHost) `shouldBe` "127.0.0.1"
        (cfg ^. #clickHouseTcpPort) `shouldBe` 9000
        (cfg ^. #clickHouseHttpPort) `shouldBe` 8123
        (cfg ^. #clickHouseDatabase) `shouldBe` "analytics"
        (cfg ^. #clickHouseUser) `shouldBe` "default"
        (cfg ^. #clickHousePassword) `shouldBe` ""
        (cfg ^. #eventsQueueName) `shouldBe` "kansoku_events"
        (cfg ^. #writerMaxBatchSize) `shouldBe` 5000
        (cfg ^. #writerMaxLatencyMs) `shouldBe` 5000
        (cfg ^. #writerVisibilityTimeoutSec) `shouldBe` 60
        (cfg ^. #writerAdapterBatchSize) `shouldBe` 1000
        (cfg ^. #serverPort) `shouldBe` 8080

  it "parses values from the environment" $ do
    clearEnv
    setEnv "PG_CONNECTION_STRING" "postgresql:///kansoku"
    setEnv "KANSOKU_CLICKHOUSE_HOST" "clickhouse.internal"
    setEnv "KANSOKU_CLICKHOUSE_DATABASE" "product_analytics"
    setEnv "KANSOKU_CLICKHOUSE_USER" "kansoku"
    setEnv "KANSOKU_CLICKHOUSE_PASSWORD" "secret"
    setEnv "CLICKHOUSE_TCP_PORT" "9100"
    setEnv "KANSOKU_QUEUE_NAME" "custom_events"
    setEnv "KANSOKU_WRITER_MAX_BATCH" "2000"
    setEnv "KANSOKU_WRITER_MAX_LATENCY_MS" "2500"
    setEnv "KANSOKU_WRITER_VT_SEC" "90"
    setEnv "KANSOKU_WRITER_ADAPTER_BATCH" "250"
    setEnv "KANSOKU_SERVER_PORT" "9999"
    result <- loadConfig
    clearEnv
    case result of
      Left err -> fail ("expected a config, got error: " <> show err)
      Right cfg -> do
        (cfg ^. #pgConnectionString) `shouldBe` "postgresql:///kansoku"
        (cfg ^. #clickHouseHost) `shouldBe` "clickhouse.internal"
        (cfg ^. #clickHouseDatabase) `shouldBe` "product_analytics"
        (cfg ^. #clickHouseUser) `shouldBe` "kansoku"
        (cfg ^. #clickHousePassword) `shouldBe` "secret"
        (cfg ^. #clickHouseTcpPort) `shouldBe` 9100
        (cfg ^. #eventsQueueName) `shouldBe` "custom_events"
        (cfg ^. #writerMaxBatchSize) `shouldBe` 2000
        (cfg ^. #writerMaxLatencyMs) `shouldBe` 2500
        (cfg ^. #writerVisibilityTimeoutSec) `shouldBe` 90
        (cfg ^. #writerAdapterBatchSize) `shouldBe` 250
        (cfg ^. #serverPort) `shouldBe` 9999

  it "rejects a non-numeric port with a Left" $ do
    clearEnv
    setEnv "KANSOKU_SERVER_PORT" "not-a-number"
    result <- loadConfig
    clearEnv
    result `shouldSatisfy` isLeft
  where
    isLeft (Left _) = True
    isLeft _ = False
