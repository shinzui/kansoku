module Kansoku.ConfigSpec (spec) where

import Data.Generics.Labels ()
import Kansoku.Config (ConfigError (..), loadConfig)
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
      "KANSOKU_CH_QUERY_POOL_SIZE",
      "CLICKHOUSE_TCP_PORT",
      "CLICKHOUSE_HTTP_PORT",
      "KANSOKU_QUEUE_NAME",
      "KANSOKU_WRITER_MAX_BATCH",
      "KANSOKU_WRITER_MAX_LATENCY_MS",
      "KANSOKU_WRITER_VT_SEC",
      "KANSOKU_WRITER_ADAPTER_BATCH",
      "KANSOKU_CORS_ORIGINS",
      "KANSOKU_INGEST_MAX_BODY_BYTES",
      "KANSOKU_INGEST_MAX_BATCH_LENGTH",
      "KANSOKU_QUEUE_POLL_INTERVAL_SEC",
      "KANSOKU_INTERNAL_METRICS_ENABLED",
      "KANSOKU_READY_MAX_QUEUE_DEPTH",
      "KANSOKU_READY_MAX_FLUSH_AGE_SEC",
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
        (cfg ^. #clickHouseQueryPoolSize) `shouldBe` 4
        (cfg ^. #eventsQueueName) `shouldBe` "kansoku_events"
        (cfg ^. #writerMaxBatchSize) `shouldBe` 5000
        (cfg ^. #writerMaxLatencyMs) `shouldBe` 5000
        (cfg ^. #writerVisibilityTimeoutSec) `shouldBe` 60
        (cfg ^. #writerAdapterBatchSize) `shouldBe` 1000
        (cfg ^. #corsAllowedOrigins) `shouldBe` Nothing
        (cfg ^. #ingestMaxBodyBytes) `shouldBe` 5242880
        (cfg ^. #ingestMaxBatchLength) `shouldBe` 500
        (cfg ^. #queuePollIntervalSec) `shouldBe` 15
        (cfg ^. #internalMetricsEnabled) `shouldBe` True
        (cfg ^. #readyMaxQueueDepth) `shouldBe` 100000
        (cfg ^. #readyMaxFlushAgeSec) `shouldBe` 120
        (cfg ^. #serverPort) `shouldBe` 8080

  it "parses values from the environment" $ do
    clearEnv
    setEnv "PG_CONNECTION_STRING" "postgresql:///kansoku"
    setEnv "KANSOKU_CLICKHOUSE_HOST" "clickhouse.internal"
    setEnv "KANSOKU_CLICKHOUSE_DATABASE" "product_analytics"
    setEnv "KANSOKU_CLICKHOUSE_USER" "kansoku"
    setEnv "KANSOKU_CLICKHOUSE_PASSWORD" "secret"
    setEnv "KANSOKU_CH_QUERY_POOL_SIZE" "8"
    setEnv "CLICKHOUSE_TCP_PORT" "9100"
    setEnv "KANSOKU_QUEUE_NAME" "custom_events"
    setEnv "KANSOKU_WRITER_MAX_BATCH" "2000"
    setEnv "KANSOKU_WRITER_MAX_LATENCY_MS" "2500"
    setEnv "KANSOKU_WRITER_VT_SEC" "90"
    setEnv "KANSOKU_WRITER_ADAPTER_BATCH" "250"
    setEnv "KANSOKU_CORS_ORIGINS" "https://app.example.com, https://admin.example.com,"
    setEnv "KANSOKU_INGEST_MAX_BODY_BYTES" "1048576"
    setEnv "KANSOKU_INGEST_MAX_BATCH_LENGTH" "250"
    setEnv "KANSOKU_QUEUE_POLL_INTERVAL_SEC" "5"
    setEnv "KANSOKU_INTERNAL_METRICS_ENABLED" "false"
    setEnv "KANSOKU_READY_MAX_QUEUE_DEPTH" "250000"
    setEnv "KANSOKU_READY_MAX_FLUSH_AGE_SEC" "45"
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
        (cfg ^. #clickHouseQueryPoolSize) `shouldBe` 8
        (cfg ^. #clickHouseTcpPort) `shouldBe` 9100
        (cfg ^. #eventsQueueName) `shouldBe` "custom_events"
        (cfg ^. #writerMaxBatchSize) `shouldBe` 2000
        (cfg ^. #writerMaxLatencyMs) `shouldBe` 2500
        (cfg ^. #writerVisibilityTimeoutSec) `shouldBe` 90
        (cfg ^. #writerAdapterBatchSize) `shouldBe` 250
        (cfg ^. #corsAllowedOrigins)
          `shouldBe` Just ["https://app.example.com", "https://admin.example.com"]
        (cfg ^. #ingestMaxBodyBytes) `shouldBe` 1048576
        (cfg ^. #ingestMaxBatchLength) `shouldBe` 250
        (cfg ^. #queuePollIntervalSec) `shouldBe` 5
        (cfg ^. #internalMetricsEnabled) `shouldBe` False
        (cfg ^. #readyMaxQueueDepth) `shouldBe` 250000
        (cfg ^. #readyMaxFlushAgeSec) `shouldBe` 45
        (cfg ^. #serverPort) `shouldBe` 9999

  it "treats an explicit wildcard CORS origin as unrestricted" $ do
    clearEnv
    setEnv "KANSOKU_CORS_ORIGINS" " * "
    result <- loadConfig
    clearEnv
    (result <&> (^. #corsAllowedOrigins)) `shouldBe` Right Nothing

  it "rejects a non-numeric port with a Left" $ do
    clearEnv
    setEnv "KANSOKU_SERVER_PORT" "not-a-number"
    result <- loadConfig
    clearEnv
    result `shouldSatisfy` isLeft

  it "rejects a query pool size below one" $ do
    clearEnv
    setEnv "KANSOKU_CH_QUERY_POOL_SIZE" "0"
    result <- loadConfig
    clearEnv
    result `shouldBe` Left (ConfigError "KANSOKU_CH_QUERY_POOL_SIZE: must be at least 1")

  it "rejects non-positive ingest limits" $ do
    clearEnv
    setEnv "KANSOKU_INGEST_MAX_BODY_BYTES" "0"
    result <- loadConfig
    clearEnv
    result `shouldBe` Left (ConfigError "KANSOKU_INGEST_MAX_BODY_BYTES: must be at least 1")

  it "rejects a non-positive queue poll interval" $ do
    clearEnv
    setEnv "KANSOKU_QUEUE_POLL_INTERVAL_SEC" "0"
    result <- loadConfig
    clearEnv
    result `shouldBe` Left (ConfigError "KANSOKU_QUEUE_POLL_INTERVAL_SEC: must be at least 1")

  it "rejects an invalid internal metrics toggle" $ do
    clearEnv
    setEnv "KANSOKU_INTERNAL_METRICS_ENABLED" "sometimes"
    result <- loadConfig
    clearEnv
    result
      `shouldBe` Left
        (ConfigError "KANSOKU_INTERNAL_METRICS_ENABLED: expected true, false, 1, or 0")

  it "accepts a zero queue-depth threshold but rejects negative values" $ do
    clearEnv
    setEnv "KANSOKU_READY_MAX_QUEUE_DEPTH" "0"
    zeroResult <- loadConfig
    (zeroResult <&> (^. #readyMaxQueueDepth)) `shouldBe` Right 0
    setEnv "KANSOKU_READY_MAX_QUEUE_DEPTH" "-1"
    negativeResult <- loadConfig
    clearEnv
    negativeResult
      `shouldBe` Left (ConfigError "KANSOKU_READY_MAX_QUEUE_DEPTH: must be at least 0")

  it "rejects a non-positive writer flush-age threshold" $ do
    clearEnv
    setEnv "KANSOKU_READY_MAX_FLUSH_AGE_SEC" "0"
    result <- loadConfig
    clearEnv
    result
      `shouldBe` Left (ConfigError "KANSOKU_READY_MAX_FLUSH_AGE_SEC: must be at least 1")
  where
    isLeft (Left _) = True
    isLeft _ = False
