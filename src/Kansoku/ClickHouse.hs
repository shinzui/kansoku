-- | ClickHouse connection and raw event table operations.
module Kansoku.ClickHouse
  ( ClickHouseConfig (..),
    EventProjection (..),
    clickHouseConfigFromConfig,
    countEvents,
    ensureSchema,
    insertEvents,
    openBootstrapConnection,
    openClickHouse,
    selectEventProjections,
  )
where

import ClickHaskell
  ( Connection,
    ConnectionArgs,
    Select,
    UInt64,
    command,
    defaultConnectionArgs,
    insert,
    intoTable,
    openConnection,
    select,
    setDatabase,
    setHost,
    setPort,
    setUser,
    unsafeMkSelect,
  )
import Data.ByteString.Char8 qualified as BS8
import Data.String (IsString)
import Kansoku.ClickHouse.EventRow
import Kansoku.Config qualified as Config
import Kansoku.Event (AnalyticsEvent)
import Kansoku.Prelude

data ClickHouseConfig = ClickHouseConfig
  { clickHouseHost :: !String,
    clickHouseTcpPort :: !String,
    clickHouseDatabase :: !String
  }
  deriving stock (Generic, Eq, Show)

clickHouseConfigFromConfig :: Config.Config -> ClickHouseConfig
clickHouseConfigFromConfig cfg =
  ClickHouseConfig
    { clickHouseHost = Config.clickHouseHost cfg,
      clickHouseTcpPort = show (Config.clickHouseTcpPort cfg),
      clickHouseDatabase = Config.clickHouseDatabase cfg
    }

openBootstrapConnection :: ClickHouseConfig -> IO Connection
openBootstrapConnection cfg =
  openConnection (connectionArgs cfg {clickHouseDatabase = "default"})

openClickHouse :: ClickHouseConfig -> IO Connection
openClickHouse = openConnection . connectionArgs

connectionArgs :: ClickHouseConfig -> ConnectionArgs
connectionArgs ClickHouseConfig {clickHouseHost = host, clickHouseTcpPort = port, clickHouseDatabase = database} =
  setHost host
    . setPort port
    . setUser "default"
    . setDatabase database
    $ defaultConnectionArgs

ensureSchema :: Connection -> IO ()
ensureSchema conn = do
  command conn "CREATE DATABASE IF NOT EXISTS analytics"
  command conn createEventsRawTable

insertEvents :: Connection -> [AnalyticsEvent] -> IO ()
insertEvents conn events =
  insert (intoTable @"events_raw" @EventColumns @EventRow) conn (eventRowFromEvent <$> events)

selectEventProjections :: Connection -> IO [EventProjection]
selectEventProjections conn = do
  rows <- concat <$> select projectionLineSelect conn pure
  pure (parseProjectionLine <$> rows)

countEvents :: Connection -> IO UInt64
countEvents conn = do
  rows <- concat <$> select countSelect conn pure
  case rows of
    CountRow n : _ -> pure n
    [] -> pure 0

projectionLineSelect :: Select ProjectionLineColumns ProjectionLine
projectionLineSelect =
  unsafeMkSelect $ \_ ->
    "SELECT concat(event_id, '\t', CAST(event_name, 'String'), '\t', CAST(source, 'String'), '\t', account_id, '\t', user_id) AS line FROM events_raw"

countSelect :: Select CountColumns CountRow
countSelect =
  unsafeMkSelect $ \_ ->
    "SELECT count() AS count FROM events_raw"

parseProjectionLine :: ProjectionLine -> EventProjection
parseProjectionLine (ProjectionLine line) =
  case BS8.split '\t' line of
    [event_id, event_name, source, account_id, user_id] ->
      EventProjection {event_id, event_name, source, account_id, user_id}
    _ ->
      EventProjection
        { event_id = line,
          event_name = "",
          source = "",
          account_id = "",
          user_id = ""
        }

createEventsRawTable :: (IsString a) => a
createEventsRawTable =
  """
  CREATE TABLE IF NOT EXISTS analytics.events_raw
  (
      event_id               String,
      event_name             LowCardinality(String),
      source                 LowCardinality(String),
      source_service         Nullable(String),
      occurred_at            DateTime64(3, 'UTC'),
      received_at            DateTime64(3, 'UTC'),
      anonymous_id           Nullable(String),
      user_id                String,
      organization_id        Nullable(String),
      account_id             String,
      session_id             Nullable(String),
      url                    Nullable(String),
      referrer               Nullable(String),
      utm_source             Nullable(String),
      utm_medium             Nullable(String),
      utm_campaign           Nullable(String),
      utm_content            Nullable(String),
      utm_term               Nullable(String),
      correlation_id         Nullable(String),
      causation_id           Nullable(String),
      source_event_id        Nullable(String),
      source_global_position Nullable(UInt64),
      properties             String,
      context                String
  )
  ENGINE = ReplacingMergeTree(received_at)
  PARTITION BY toYYYYMM(occurred_at)
  ORDER BY (account_id, user_id, event_name, occurred_at, event_id)
  """
