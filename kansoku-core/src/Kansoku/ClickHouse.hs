-- | ClickHouse connection and raw event table operations.
module Kansoku.ClickHouse
  ( ClickHouseConfig (..),
    EventProjection (..),
    QueryPool,
    WriterConnection,
    clickHouseConfigFromConfig,
    countEvents,
    insertEvents,
    insertWriterEvents,
    newWriterConnection,
    openClickHouse,
    newQueryPool,
    selectEventProjections,
    withQueryConnection,
  )
where

import ClickHaskell
  ( Connection,
    ConnectionArgs,
    Select,
    UInt64,
    defaultConnectionArgs,
    insert,
    intoTable,
    openConnection,
    select,
    setDatabase,
    setHost,
    setPassword,
    setPort,
    setUser,
    unsafeMkSelect,
  )
import Control.Concurrent.MVar (MVar, modifyMVar, newMVar)
import Control.Exception (SomeException, throwIO, try)
import Data.Generics.Labels ()
import Data.Pool qualified as Pool
import Kansoku.ClickHouse.EventRow
import Kansoku.Config qualified as Config
import Kansoku.Event (AnalyticsEvent)
import Kansoku.Prelude

data ClickHouseConfig = ClickHouseConfig
  { clickHouseHost :: !String,
    clickHouseTcpPort :: !String,
    clickHouseDatabase :: !String,
    clickHouseUser :: !String,
    clickHousePassword :: !String
  }
  deriving stock (Generic, Eq, Show)

clickHouseConfigFromConfig :: Config.Config -> ClickHouseConfig
clickHouseConfigFromConfig cfg =
  ClickHouseConfig
    { clickHouseHost = Config.clickHouseHost cfg,
      clickHouseTcpPort = show (Config.clickHouseTcpPort cfg),
      clickHouseDatabase = Config.clickHouseDatabase cfg,
      clickHouseUser = Config.clickHouseUser cfg,
      clickHousePassword = Config.clickHousePassword cfg
    }

openClickHouse :: ClickHouseConfig -> IO Connection
openClickHouse = openConnection . connectionArgs

-- | A dedicated writer connection cache. ClickHaskell reconnects internally,
-- but a reconnect that fails can leave its opaque connection lock empty. We
-- therefore discard every handle whose operation throws and open a fresh one
-- on the next queue retry.
data WriterConnection = WriterConnection !ClickHouseConfig !(MVar (Maybe Connection))

newWriterConnection :: ClickHouseConfig -> IO WriterConnection
newWriterConnection config = WriterConnection config <$> newMVar Nothing

insertWriterEvents :: WriterConnection -> [AnalyticsEvent] -> IO ()
insertWriterEvents (WriterConnection config connectionCell) events = do
  result <-
    modifyMVar connectionCell $ \cachedConnection -> do
      attempted <- try @SomeException $ do
        connection <- maybe (openClickHouse config) pure cachedConnection
        insertEvents connection events
        pure connection
      pure $ case attempted of
        Left exception -> (Nothing, Left exception)
        Right connection -> (Just connection, Right ())
  either throwIO pure result

-- | A fixed-size pool of ClickHouse connections for the metrics query path.
-- The writer never uses this; it owns its own dedicated connection.
newtype QueryPool = QueryPool (Pool.Pool Connection)

newQueryPool :: ClickHouseConfig -> Int -> IO QueryPool
newQueryPool cfg size =
  QueryPool
    <$> Pool.newPool
      ( Pool.setNumStripes (Just 1) $
          Pool.defaultPoolConfig (openClickHouse cfg) (const (pure ())) queryConnectionIdleSeconds size
      )

-- | Effectively never reap idle connections: ClickHaskell exposes no close,
-- so reaping could only leak sockets.
queryConnectionIdleSeconds :: Double
queryConnectionIdleSeconds = 1e9

withQueryConnection :: QueryPool -> (Connection -> IO a) -> IO a
withQueryConnection (QueryPool pool) action = do
  result <- Pool.withResource pool (try @SomeException . action)
  either throwIO pure result

connectionArgs :: ClickHouseConfig -> ConnectionArgs
connectionArgs ClickHouseConfig {clickHouseHost = host, clickHouseTcpPort = port, clickHouseDatabase = database, clickHouseUser = user, clickHousePassword = password} =
  setHost host
    . setPort port
    . setUser user
    . setPassword password
    . setDatabase database
    $ defaultConnectionArgs

insertEvents :: Connection -> [AnalyticsEvent] -> IO ()
insertEvents conn events =
  insert (intoTable @"events_raw" @EventColumns @EventRow) conn (eventRowFromEvent <$> events)

selectEventProjections :: Connection -> IO [EventProjection]
selectEventProjections conn =
  concat <$> select projectionSelect conn (pure . repairProjectionRows)

-- ClickHaskell 1.1.0 reverses the accumulated row list at each generic product
-- node. For this five-field record that reverses fields 1 and 3 relative to
-- fields 2, 4, and 5. Repair each native-protocol block before concatenating.
repairProjectionRows :: [EventProjection] -> [EventProjection]
repairProjectionRows rows =
  zipWith3 repair rows (reverse (fmap (^. #event_id) rows)) (reverse (fmap (^. #source) rows))
  where
    repair row eventId sourceName =
      row
        & #event_id
        .~ eventId
        & #source
        .~ sourceName

countEvents :: Connection -> IO UInt64
countEvents conn = do
  rows <- concat <$> select countSelect conn pure
  case rows of
    CountRow n : _ -> pure n
    [] -> pure 0

projectionSelect :: Select ProjectionColumns EventProjection
projectionSelect =
  unsafeMkSelect $ \_ ->
    "SELECT event_id, CAST(event_name, 'String') AS event_name, CAST(source, 'String') AS source, account_id, user_id FROM events_raw"

countSelect :: Select CountColumns CountRow
countSelect =
  unsafeMkSelect $ \_ ->
    "SELECT count() AS count FROM events_raw"
