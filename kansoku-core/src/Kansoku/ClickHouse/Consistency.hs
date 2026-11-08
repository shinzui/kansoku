-- | Bounded native consistency operations. Every retained handle belongs to one
-- expected server; an exception invalidates the entire operation, never silently
-- reconnects one member after a barrier.
module Kansoku.ClickHouse.Consistency
  ( ReplicaConnections,
    replicaConnections,
    directReplicaConnections,
    coordinator,
    withReplicaConnections,
    Role (..),
    roleSettings,
    initializeRole,
    validateSchemaTopology,
    synchronizeTables,
    synchronizeSchema,
    withConsistentReadback,
    withConsistentReadbackOn,
    maintenanceTables,
    withinBudget,
    checkIdentities,
  )
where

import ClickHaskell (Connection, closeConnection)
import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, bracket, fromException, mask, onException, throwIO, try)
import Control.Monad (forM_, unless, when)
import Data.Aeson qualified as A
import Data.IORef
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Kansoku.ClickHouse.Native
import Kansoku.ClickHouse.Topology
import Kansoku.Exception (catchSynchronous)
import System.Timeout (timeout)

data ReplicaConnections = ReplicaConnections !Topology ![(Text, Connection)]

replicaConnections :: ReplicaConnections -> [(Text, Connection)]
replicaConnections (ReplicaConnections _ connections) = connections

-- Only for compatibility with existing direct native consumers.
directReplicaConnections :: Connection -> ReplicaConnections
directReplicaConnections c = ReplicaConnections Direct [("direct", c)]

coordinator :: ReplicaConnections -> Connection
coordinator (ReplicaConnections _ ((_, connection) : _)) = connection
coordinator _ = error "empty verified replica inventory"

data Role = Writer | Maintenance | Readback deriving stock (Eq, Show)

roleSettings :: Topology -> Role -> [(Text, Text)]
roleSettings Direct Writer = [("async_insert", "0")]
roleSettings Direct _ = []
roleSettings (Replicated _ ids) role =
  [("async_insert", "0"), ("select_sequential_consistency", "1"), ("max_result_rows", "0"), ("max_result_bytes", "0"), ("result_overflow_mode", "'throw'"), ("read_overflow_mode", "'throw'")]
    ++ if role == Readback
      then []
      else
        [ ("insert_quorum", Text.pack (show (length ids))),
          ("insert_quorum_parallel", "0"),
          ("insert_quorum_timeout", "20000"),
          ("insert_deduplicate", "1"),
          ("deduplicate_blocks_in_dependent_materialized_views", "1"),
          ("materialized_views_ignore_errors", "0")
        ]
          ++ if role == Maintenance then [("distributed_ddl_output_mode", "'none'"), ("mutations_sync", "2"), ("alter_sync", "2"), ("replication_wait_for_inactive_replica_timeout", "20"), ("receive_timeout", "55"), ("max_execution_time", "55")] else []

initializeRole :: Topology -> Role -> Connection -> IO ()
initializeRole topology role connection = withinBudget "native role initialization" $ do
  let settings = roleSettings topology role
  unless (null settings) $ chCommand connection A.Null ("SET " <> Text.intercalate "," [name <> "=" <> value | (name, value) <- settings])
  case topology of
    Direct -> pure ()
    _ -> forM_ settings $ \(name, expected) -> do
      values <- chJSON connection A.Null ("SELECT toJSONString(value) AS value FROM system.settings WHERE name='" <> name <> "'")
      unless (values == [A.String (Text.filter (/= '\'') expected)]) (failConsistency ("native role setting refused: " <> Text.unpack name))

withinBudget :: Text -> IO a -> IO a
withinBudget stage action =
  catchSynchronous
    (timeout 60_000_000 action >>= maybe (failConsistency "native deadline expired; maintenance fence retained") pure)
    ( \exception -> case fromException exception of
        Just (ConsistencyError reason) -> failConsistency (Text.unpack (stage <> ": " <> reason))
        Nothing -> failConsistency (Text.unpack stage <> ": native exchange failed; details redacted; maintenance fence retained")
    )

identity :: Connection -> IO Text
identity connection =
  chJSON connection A.Null "SELECT toJSONString(toString(serverUUID())) AS value" >>= \case
    [A.String value] | validServerId value -> pure value
    _ -> failConsistency "invalid native replica identity"

validateSchemaTopology :: Topology -> Connection -> IO ()
validateSchemaTopology topology connection = do
  engines <- chJSON connection A.Null "SELECT toJSONString(engine) AS value FROM system.databases WHERE name=currentDatabase()"
  case topology of
    Direct -> do
      replicated <- chJSON connection A.Null "SELECT toJSONString(count()) AS value FROM system.tables WHERE database=currentDatabase() AND startsWith(engine,'Replicated')"
      when (engines == [A.String "Replicated"] || replicated /= [A.Number 0]) (failConsistency "replicated application schema requires explicit cluster and replica IDs")
    Replicated _ ids -> do
      sid <- identity connection
      unless (sid `elem` ids) (failConsistency ("unexpected application replica UUID " <> Text.unpack sid))
      unless (engines == [A.String "Replicated"]) (failConsistency "replicated topology requires a Replicated application database")
      localTables <- chJSON connection A.Null "SELECT toJSONString(count()) AS value FROM system.tables WHERE database=currentDatabase() AND position(engine,'MergeTree')>0 AND NOT startsWith(engine,'Replicated')"
      unless (localTables == [A.Number 0]) (failConsistency "application MergeTree tables must all be replicated")

withReplicaConnections :: Topology -> IO Connection -> (ReplicaConnections -> IO a) -> IO a
withReplicaConnections topology open action = bracket acquire release action
  where
    safeClose c = do
      _ <- try @SomeException (closeConnection c)
      pure ()
    release set = mapM_ (safeClose . snd) (replicaConnections set)
    acquire = mask $ \restore -> do
      retained <- newIORef []
      let cleanup = readIORef retained >>= mapM_ (safeClose . snd)
          attempt expected remaining = do
            connections <- readIORef retained
            if sort (map fst connections) == expected
              then pure ()
              else do
                unless (remaining > (0 :: Int)) (failConsistency ("replica acquisition exhausted; expected=" <> show expected <> "; observed=" <> show (sort (map fst connections))))
                -- Register ownership before restoring asynchronous exceptions.
                connection <- open
                sid <- restore (identity connection) `onException` closeConnection connection
                unless (sid `elem` expected) (closeConnection connection >> failConsistency ("unexpected replica UUID " <> Text.unpack sid))
                if sid `elem` map fst connections
                  then closeConnection connection >> restore (threadDelay 100_000)
                  else modifyIORef' retained ((sid, connection) :)
                attempt expected (remaining - 1)
          run = case topology of
            Direct -> do
              c <- open
              writeIORef retained [("direct", c)]
              restore (validateSchemaTopology topology c)
            Replicated cluster ids -> do
              attempt ids 64
              cs <- readIORef retained
              restore $ forM_ cs $ \(_, c) -> do
                validateSchemaTopology topology c
                inventory <- chJSON c A.Null ("SELECT toJSONString(tuple(toUInt64(uniqExact(shard_num)),toUInt64(count()))) AS value FROM system.clusters WHERE cluster='" <> cluster <> "'")
                unless (inventory == [A.toJSON (1 :: Int, length ids)]) (failConsistency "configured cluster must have one shard and exactly the expected replicas")
                observed <- chJSON c A.Null ("SELECT toJSONString(toString(serverUUID())) AS value FROM clusterAllReplicas('" <> cluster <> "',system.one)")
                unless (sort [s | A.String s <- observed] == ids && length observed == length ids) (failConsistency "configured cluster UUID inventory differs from expected replicas")
      let boundedRun = case topology of
            Direct -> run
            Replicated _ ids -> do
              result <- timeout 35_000_000 run
              case result of
                Just () -> pure ()
                Nothing -> readIORef retained >>= \cs -> failConsistency ("replica acquisition deadline expired; expected=" <> show ids <> "; observed=" <> show (sort (map fst cs)))
      catchSynchronous (boundedRun `onException` cleanup) $ \exception ->
        case fromException exception :: Maybe ConsistencyError of
          Just _ -> throwIO exception
          Nothing -> do
            observed <- map fst <$> readIORef retained
            failConsistency ("native replica acquisition failed; selected=" <> show topology <> "; observed=" <> show (sort observed) <> "; details redacted; fence retained")
      ReplicaConnections topology . reverse <$> readIORef retained

checkIdentities :: ReplicaConnections -> IO ()
checkIdentities (ReplicaConnections Direct _) = pure ()
checkIdentities (ReplicaConnections _ cs) = forM_ cs $ \(expected, c) -> do
  observed <- withinBudget ("replica identity " <> expected) (identity c)
  unless (observed == expected) (failConsistency "native replica identity changed; maintenance fence retained")

synchronizeSchema :: ReplicaConnections -> IO ()
synchronizeSchema set@(ReplicaConnections topology _) = case topology of
  Direct -> pure ()
  _ -> do
    checkIdentities set
    forM_ (replicaConnections set) $ \(sid, c) -> withinBudget ("schema sync " <> sid) (chCommand c A.Null "SYSTEM SYNC DATABASE REPLICA analytics")

synchronizeTables :: ReplicaConnections -> [Text] -> IO ()
synchronizeTables set@(ReplicaConnections topology _) tables = case topology of
  Direct -> pure ()
  _ -> do
    checkIdentities set
    forM_ (replicaConnections set) $ \(sid, c) -> forM_ tables $ \table -> withinBudget ("table sync " <> table <> " replica " <> sid) $ do
      unless (table `elem` maintenanceTables) (failConsistency "unreviewed native synchronization table")
      engines <- chJSON c A.Null ("SELECT toJSONString(engine) AS value FROM system.tables WHERE database='analytics' AND name='" <> table <> "'")
      case engines of
        [A.String engine] | "Replicated" `Text.isPrefixOf` engine -> chCommand c A.Null ("SYSTEM SYNC REPLICA analytics.`" <> table <> "` STRICT")
        _ -> failConsistency ("missing or nonreplicated required table " <> Text.unpack table)

-- Explicit dependency inventory, including chained identity and governed traits.
maintenanceTables :: [Text]
maintenanceTables = ["events_raw", "retention_policy", "trait_event_erasures", "identity_signals", "identity_signal_users", "identity_session_users", "identity_context_signals", "daily_event_counts", "page_views_by_route", "dau", "wau", "experiment_exposures", "sessions", "user_properties", "user_properties_once", "organization_properties", "user_organizations", "cohort_members"]

-- A single acquired physical connection supplies both its barrier and SELECT.
-- Ordinary analytics requests do not call this privileged verification path.
withConsistentReadback :: Topology -> IO Connection -> (Connection -> IO a) -> IO a
withConsistentReadback topology open action = bracket open closeConnection $ \c -> withConsistentReadbackOn topology c action

-- The resource owner must dispose the physical connection if this action fails.
-- QueryPool uses this inside its checked-out resource callback.
withConsistentReadbackOn :: Topology -> Connection -> (Connection -> IO a) -> IO a
withConsistentReadbackOn topology c action = do
  validateSchemaTopology topology c
  sid <- identity c
  case topology of
    Replicated _ ids -> unless (sid `elem` ids) (failConsistency "unexpected read-back replica")
    Direct -> pure ()
  initializeRole topology Readback c
  let set = ReplicaConnections topology [(sid, c)]
  synchronizeSchema set
  synchronizeTables set maintenanceTables
  withinBudget ("read-back " <> sid) (action c)
