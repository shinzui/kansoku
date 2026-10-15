-- | ClickHouse connection and raw event table operations.
module Kansoku.ClickHouse
  ( ClickHouseConfig (..),
    EventProjection (..),
    QueryPool,
    WriterConnection,
    clickHouseConfigFromConfig,
    countEvents,
    insertEvents,
    insertQueuedEvents,
    insertWriterEvents,
    newWriterConnection,
    openClickHouse,
    newQueryPool,
    newQueryPoolWithLimits,
    MetricsQueryLimits (..),
    defaultMetricsQueryLimits,
    metricsQueryLimitsFromConfig,
    queryLimits,
    queryDeadlineMicros,
    withMetricsQueryConnection,
    closeQueryPool,
    selectEventProjections,
    withQueryConnection,
    withIdentityQueryConnection,
    queryReachable,
  )
where

import ClickHaskell
  ( Connection,
    ConnectionArgs,
    Select,
    UInt64,
    closeConnection,
    command,
    defaultConnectionArgs,
    insert,
    intoTable,
    openConnection,
    ping,
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
import Data.IORef (IORef, newIORef)
import Data.Int (Int64)
import Data.Pool qualified as Pool
import Data.String (fromString)
import Kansoku.ClickHouse.EventRow
import Kansoku.Config qualified as Config
import Kansoku.Event (AnalyticsEvent)
import Kansoku.Identity.Cache (IdentityCacheState, prepareIdentityCache)
import Kansoku.Ingest.QueuedEvent (QueuedEvent)
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

-- | A dedicated writer cache. Failed operations close the physical connection;
-- the next queue retry opens a fresh handle.
data WriterConnection = WriterConnection !ClickHouseConfig !(MVar (Maybe Connection))

newWriterConnection :: ClickHouseConfig -> IO WriterConnection
newWriterConnection config = WriterConnection config <$> newMVar Nothing

insertWriterEvents :: WriterConnection -> [QueuedEvent] -> IO ()
insertWriterEvents (WriterConnection config connectionCell) events = do
  result <-
    modifyMVar connectionCell $ \cachedConnection -> do
      attempted <- try @SomeException $ do
        connection <- maybe (openClickHouse config) pure cachedConnection
        insertQueuedEvents connection events
        pure connection
      pure $ case attempted of
        Left exception -> (Nothing, Left exception)
        Right connection -> (Just connection, Right ())
  either throwIO pure result

-- | A fixed-size pool of ClickHouse connections for the metrics query path.
-- The writer never uses this; it owns its own dedicated connection.
data QueryConnection = QueryConnection !Connection !(IORef IdentityCacheState)

data MetricsQueryLimits = MetricsQueryLimits
  { queryExecutionSeconds :: !Int,
    queryMemoryBytes :: !Int64
  }
  deriving stock (Generic, Eq, Show)

defaultMetricsQueryLimits :: MetricsQueryLimits
defaultMetricsQueryLimits = MetricsQueryLimits 30 536870912

metricsQueryLimitsFromConfig :: Config.Config -> MetricsQueryLimits
metricsQueryLimitsFromConfig cfg = MetricsQueryLimits (cfg ^. #metricsMaxExecutionSec) (cfg ^. #metricsMaxMemoryBytes)

data QueryPool = QueryPool !MetricsQueryLimits !(Pool.Pool QueryConnection)

queryLimits :: QueryPool -> MetricsQueryLimits
queryLimits (QueryPool limits _) = limits

queryDeadlineMicros :: QueryPool -> Int
queryDeadlineMicros pool = fromInteger (min (toInteger (maxBound :: Int)) (toInteger (queryExecutionSeconds (queryLimits pool)) * 1000000))

newQueryPool :: ClickHouseConfig -> Int -> IO QueryPool
newQueryPool cfg size = newQueryPoolWithLimits cfg size defaultMetricsQueryLimits

newQueryPoolWithLimits :: ClickHouseConfig -> Int -> MetricsQueryLimits -> IO QueryPool
newQueryPoolWithLimits cfg size limits = do
  unless (queryExecutionSeconds limits > 0 && queryMemoryBytes limits > 0) (fail "metric query limits must be positive")
  QueryPool limits
    <$> Pool.newPool
      ( Pool.setNumStripes (Just 1) $
          Pool.defaultPoolConfig (QueryConnection <$> openClickHouse cfg <*> newIORef Nothing) closeQueryConnection queryConnectionIdleSeconds size
      )

-- | Idle physical connections are closed, as are all resources at shutdown.
queryConnectionIdleSeconds :: Double
queryConnectionIdleSeconds = 60

closeQueryPool :: QueryPool -> IO ()
closeQueryPool (QueryPool _ pool) = Pool.destroyAllResources pool

-- | Failures escape the callback: disposal completes before classification.
withQueryConnection :: QueryPool -> (Connection -> IO a) -> IO a
withQueryConnection (QueryPool _ pool) action = Pool.withResource pool $ \(QueryConnection connection _) -> action connection

closeQueryConnection :: QueryConnection -> IO ()
closeQueryConnection (QueryConnection connection _) = closeConnection connection

-- | Refresh exact evidence on this physical connection before any resolved
-- query. Failures escape the pool callback and dispose both socket and caches.
withIdentityQueryConnection :: QueryPool -> Text -> Text -> Text -> (Connection -> IO a) -> IO a
withIdentityQueryConnection (QueryPool limits pool) account fromDay toDay action = Pool.withResource pool $ \(QueryConnection connection revision) -> do
  applyQueryLimits limits connection
  prepareIdentityCache (queryMemoryBytes limits) account fromDay toDay connection revision
  action connection

-- Both SET and preparation execute inside the resource callback. A timeout or
-- native failure disposes the same physical connection before classification.
withMetricsQueryConnection :: QueryPool -> (Connection -> IO a) -> IO a
withMetricsQueryConnection pool action = withQueryConnection pool $ \connection -> do
  applyQueryLimits (queryLimits pool) connection
  action connection

applyQueryLimits :: MetricsQueryLimits -> Connection -> IO ()
applyQueryLimits limits connection =
  command
    connection
    ( fromString
        ( "SET max_execution_time="
            <> show (queryExecutionSeconds limits)
            <> ",max_memory_usage="
            <> show (queryMemoryBytes limits)
            <> ",timeout_overflow_mode='throw',read_overflow_mode='throw',group_by_overflow_mode='throw',join_overflow_mode='throw',result_overflow_mode='throw'"
        )
    )

queryReachable :: QueryPool -> IO Bool
queryReachable pool = withQueryConnection pool (\conn -> ping conn >> pure True)

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

insertQueuedEvents :: Connection -> [QueuedEvent] -> IO ()
insertQueuedEvents conn events =
  insert (intoTable @"events_raw" @EventColumns @EventRow) conn (eventRowFromQueuedEvent <$> events)

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
    "SELECT event_id, CAST(event_name, 'String') AS event_name, CAST(source, 'String') AS source, account_id, user_id FROM events_canonical"

countSelect :: Select CountColumns CountRow
countSelect =
  unsafeMkSelect $ \_ ->
    "SELECT count() AS count FROM events_canonical"
