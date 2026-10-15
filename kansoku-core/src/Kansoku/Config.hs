-- | Runtime configuration for Kansoku, parsed from environment variables that
-- the dev shell (see nix/haskell.nix shellHook) already exports.
module Kansoku.Config
  ( Config (..),
    ConfigError (..),
    defaultEventsQueueName,
    defaultIngestMaxBatchLength,
    defaultIngestMaxBodyBytes,
    defaultServerPort,
    loadConfig,
  )
where

import Data.Int (Int32, Int64)
import Data.Text qualified as Text
import Kansoku.Prelude
import System.Environment (lookupEnv)
import Text.Read (readMaybe)

-- | The port the HTTP server listens on when KANSOKU_SERVER_PORT is unset.
defaultServerPort :: Int
defaultServerPort = 8080

defaultEventsQueueName :: Text
defaultEventsQueueName = "kansoku_events"

defaultIngestMaxBodyBytes :: Int
defaultIngestMaxBodyBytes = 5 * 1024 * 1024

defaultIngestMaxBatchLength :: Int
defaultIngestMaxBatchLength = 500

-- | All configuration the service needs at startup. Later plans extend this
-- record with ClickHouse, pgmq, queue, and metrics-query settings.
data Config = Config
  { pgConnectionString :: !Text,
    clickHouseHost :: !String,
    clickHouseTcpPort :: !Int,
    clickHouseHttpPort :: !Int,
    clickHouseDatabase :: !String,
    clickHouseUser :: !String,
    clickHousePassword :: !String,
    clickHouseQueryPoolSize :: !Int,
    eventsQueueName :: !Text,
    writerMaxBatchSize :: !Int,
    writerMaxLatencyMs :: !Int,
    writerVisibilityTimeoutSec :: !Int32,
    writerAdapterBatchSize :: !Int32,
    corsAllowedOrigins :: !(Maybe [Text]),
    ingestMaxBodyBytes :: !Int,
    ingestMaxBatchLength :: !Int,
    ingestFutureToleranceSec :: !Int,
    ingestQuarantine :: !Bool,
    quarantineRetentionDays :: !Int,
    quarantineMaxRows :: !Int,
    quarantineMaxPayloadBytes :: !Int,
    queuePollIntervalSec :: !Int,
    internalMetricsEnabled :: !Bool,
    readyMaxQueueDepth :: !Int64,
    readyMaxFlushAgeSec :: !Int,
    serverPort :: !Int
  }
  deriving stock (Generic, Eq, Show)

-- | A configuration failure with a human-readable message.
newtype ConfigError = ConfigError Text
  deriving stock (Generic, Eq, Show)

-- | Read configuration from the environment. Missing values fall back to
-- sensible defaults; a non-numeric port yields a Left with a clear message.
loadConfig :: IO (Either ConfigError Config)
loadConfig = do
  pg <- maybe defaultPg Text.pack <$> lookupEnv "PG_CONNECTION_STRING"
  chHost <- fromMaybe "127.0.0.1" <$> lookupEnv "KANSOKU_CLICKHOUSE_HOST"
  chTcp <- lookupEnv "CLICKHOUSE_TCP_PORT"
  chHttp <- lookupEnv "CLICKHOUSE_HTTP_PORT"
  chDatabase <- fromMaybe "analytics" <$> lookupEnv "KANSOKU_CLICKHOUSE_DATABASE"
  chUser <- fromMaybe "default" <$> lookupEnv "KANSOKU_CLICKHOUSE_USER"
  chPassword <- fromMaybe "" <$> lookupEnv "KANSOKU_CLICKHOUSE_PASSWORD"
  chQueryPoolSize <- lookupEnv "KANSOKU_CH_QUERY_POOL_SIZE"
  queue <- maybe defaultEventsQueueName Text.pack <$> lookupEnv "KANSOKU_QUEUE_NAME"
  writerBatch <- lookupEnv "KANSOKU_WRITER_MAX_BATCH"
  writerLatency <- lookupEnv "KANSOKU_WRITER_MAX_LATENCY_MS"
  writerVt <- lookupEnv "KANSOKU_WRITER_VT_SEC"
  writerAdapterBatch <- lookupEnv "KANSOKU_WRITER_ADAPTER_BATCH"
  corsOrigins <- lookupEnv "KANSOKU_CORS_ORIGINS"
  ingestBodyBytes <- lookupEnv "KANSOKU_INGEST_MAX_BODY_BYTES"
  ingestBatchLength <- lookupEnv "KANSOKU_INGEST_MAX_BATCH_LENGTH"
  quarantineEnabled <- lookupEnv "KANSOKU_INGEST_QUARANTINE"
  quarantineRetention <- lookupEnv "KANSOKU_INGEST_QUARANTINE_RETENTION_DAYS"
  quarantineRows <- lookupEnv "KANSOKU_INGEST_QUARANTINE_MAX_ROWS"
  quarantineBytes <- lookupEnv "KANSOKU_INGEST_QUARANTINE_MAX_PAYLOAD_BYTES"
  futureTolerance <- lookupEnv "KANSOKU_INGEST_FUTURE_TOLERANCE_SEC"
  queuePollInterval <- lookupEnv "KANSOKU_QUEUE_POLL_INTERVAL_SEC"
  metricsEnabled <- lookupEnv "KANSOKU_INTERNAL_METRICS_ENABLED"
  maxQueueDepth <- lookupEnv "KANSOKU_READY_MAX_QUEUE_DEPTH"
  maxFlushAge <- lookupEnv "KANSOKU_READY_MAX_FLUSH_AGE_SEC"
  srv <- lookupEnv "KANSOKU_SERVER_PORT"
  pure $ do
    tcp <- parsePort "CLICKHOUSE_TCP_PORT" 9000 chTcp
    http <- parsePort "CLICKHOUSE_HTTP_PORT" 8123 chHttp
    maxBatch <- parseInt "KANSOKU_WRITER_MAX_BATCH" 5000 writerBatch
    maxLatency <- parseInt "KANSOKU_WRITER_MAX_LATENCY_MS" 5000 writerLatency
    visibility <- parseInt32 "KANSOKU_WRITER_VT_SEC" 60 writerVt
    adapterBatch <- parseInt32 "KANSOKU_WRITER_ADAPTER_BATCH" 1000 writerAdapterBatch
    queryPoolSize <- parsePositiveInt "KANSOKU_CH_QUERY_POOL_SIZE" 4 chQueryPoolSize
    maxBodyBytes <- parsePositiveInt "KANSOKU_INGEST_MAX_BODY_BYTES" defaultIngestMaxBodyBytes ingestBodyBytes
    maxBatchLength <- parsePositiveInt "KANSOKU_INGEST_MAX_BATCH_LENGTH" defaultIngestMaxBatchLength ingestBatchLength
    enableQuarantine <- parseBool "KANSOKU_INGEST_QUARANTINE" False quarantineEnabled
    retentionDays <- parsePositiveInt "KANSOKU_INGEST_QUARANTINE_RETENTION_DAYS" 14 quarantineRetention
    maxRows <- parsePositiveInt "KANSOKU_INGEST_QUARANTINE_MAX_ROWS" 10000 quarantineRows
    maxPayloadBytes <- parsePositiveInt "KANSOKU_INGEST_QUARANTINE_MAX_PAYLOAD_BYTES" 16384 quarantineBytes
    unless (maxPayloadBytes >= 2) (Left (ConfigError "KANSOKU_INGEST_QUARANTINE_MAX_PAYLOAD_BYTES: must be at least 2"))
    futureToleranceSec <- parseNonNegativeInt "KANSOKU_INGEST_FUTURE_TOLERANCE_SEC" 86400 futureTolerance
    pollInterval <- parsePositiveInt "KANSOKU_QUEUE_POLL_INTERVAL_SEC" 15 queuePollInterval
    enableMetrics <- parseBool "KANSOKU_INTERNAL_METRICS_ENABLED" True metricsEnabled
    readyQueueDepth <- parseNonNegativeInt64 "KANSOKU_READY_MAX_QUEUE_DEPTH" 100000 maxQueueDepth
    readyFlushAge <- parsePositiveInt "KANSOKU_READY_MAX_FLUSH_AGE_SEC" 120 maxFlushAge
    port <- parsePort "KANSOKU_SERVER_PORT" defaultServerPort srv
    Right
      Config
        { pgConnectionString = pg,
          clickHouseHost = chHost,
          clickHouseTcpPort = tcp,
          clickHouseHttpPort = http,
          clickHouseDatabase = chDatabase,
          clickHouseUser = chUser,
          clickHousePassword = chPassword,
          clickHouseQueryPoolSize = queryPoolSize,
          eventsQueueName = queue,
          writerMaxBatchSize = maxBatch,
          writerMaxLatencyMs = maxLatency,
          writerVisibilityTimeoutSec = visibility,
          writerAdapterBatchSize = adapterBatch,
          corsAllowedOrigins = parseCorsOrigins corsOrigins,
          ingestMaxBodyBytes = maxBodyBytes,
          ingestMaxBatchLength = maxBatchLength,
          ingestQuarantine = enableQuarantine,
          quarantineRetentionDays = retentionDays,
          quarantineMaxRows = maxRows,
          quarantineMaxPayloadBytes = maxPayloadBytes,
          ingestFutureToleranceSec = futureToleranceSec,
          queuePollIntervalSec = pollInterval,
          internalMetricsEnabled = enableMetrics,
          readyMaxQueueDepth = readyQueueDepth,
          readyMaxFlushAgeSec = readyFlushAge,
          serverPort = port
        }
  where
    defaultPg = "postgresql:///kansoku"

parsePort :: Text -> Int -> Maybe String -> Either ConfigError Int
parsePort = parseInt

parseInt :: Text -> Int -> Maybe String -> Either ConfigError Int
parseInt _ def Nothing = Right def
parseInt name _ (Just raw) =
  case readMaybe raw of
    Just n -> Right n
    Nothing ->
      Left (ConfigError (name <> ": not a valid integer: " <> Text.pack raw))

parsePositiveInt :: Text -> Int -> Maybe String -> Either ConfigError Int
parsePositiveInt name def raw = do
  value <- parseInt name def raw
  if value >= 1
    then Right value
    else Left (ConfigError (name <> ": must be at least 1"))

parseBool :: Text -> Bool -> Maybe String -> Either ConfigError Bool
parseBool _ def Nothing = Right def
parseBool name _ (Just raw) =
  case raw of
    "true" -> Right True
    "1" -> Right True
    "false" -> Right False
    "0" -> Right False
    _ -> Left (ConfigError (name <> ": expected true, false, 1, or 0"))

parseCorsOrigins :: Maybe String -> Maybe [Text]
parseCorsOrigins Nothing = Nothing
parseCorsOrigins (Just raw)
  | Text.strip value == "*" = Nothing
  | otherwise = Just (filter (not . Text.null) (Text.strip <$> Text.splitOn "," value))
  where
    value = Text.pack raw

parseInt32 :: Text -> Int32 -> Maybe String -> Either ConfigError Int32
parseInt32 _ def Nothing = Right def
parseInt32 name _ (Just raw) =
  case readMaybe raw of
    Just n -> Right n
    Nothing ->
      Left (ConfigError (name <> ": not a valid integer: " <> Text.pack raw))

parseInt64 :: Text -> Int64 -> Maybe String -> Either ConfigError Int64
parseInt64 _ def Nothing = Right def
parseInt64 name _ (Just raw) =
  case readMaybe raw of
    Just n -> Right n
    Nothing ->
      Left (ConfigError (name <> ": not a valid integer: " <> Text.pack raw))

parseNonNegativeInt64 :: Text -> Int64 -> Maybe String -> Either ConfigError Int64
parseNonNegativeInt64 name def raw = do
  value <- parseInt64 name def raw
  if value >= 0
    then Right value
    else Left (ConfigError (name <> ": must be at least 0"))

parseNonNegativeInt :: Text -> Int -> Maybe String -> Either ConfigError Int
parseNonNegativeInt name def raw = do
  value <- parseInt name def raw
  if value >= 0
    then Right value
    else Left (ConfigError (name <> ": must be at least 0"))
