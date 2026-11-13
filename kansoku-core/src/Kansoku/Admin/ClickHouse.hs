-- | Native, parameterized maintenance over the currently installed projections.
module Kansoku.Admin.ClickHouse
  ( chJSON,
    chCommand,
    discoverIdentity,
    affected,
    explicitSubject,
    rebuildDerived,
    rebuildReplicas,
    verifyReplicaMutations,
    quiesceReplicaWrites,
    WriteObservation (..),
    observeReplicaWrites,
    verifyReplicaPopulations,
    verifyMutations,
    quiesceRawWrites,
    scopeText,
    quoteName,
  )
where

import ClickHaskell (Connection)
import Control.Concurrent (threadDelay)
import Control.Monad (forM, forM_)
import Data.Aeson qualified as A
import Data.Aeson.Types qualified as A
import Data.IORef
import Data.Text qualified as Text
import Kansoku.ClickHouse.Consistency
import Kansoku.ClickHouse.Native
import Kansoku.Exception (trySynchronous)
import Kansoku.Prelude
import System.Timeout (timeout)

account, user :: Text
account = "JSONExtractString({admin_scope:String},'account')"
user = "JSONExtractString({admin_scope:String},'user')"

explicitSubject :: Text
explicitSubject = "account_id=" <> account <> " AND user_id=" <> user

affected :: Text
affected =
  "account_id="
    <> account
    <> " AND (user_id="
    <> user
    <> " OR (user_id='' AND ("
    <> "has(JSONExtract({admin_scope:String},'cookies','Array(String)'),anonymous_id)"
    <> " OR (session_id!='' AND has(JSONExtract({admin_scope:String},'sessions','Array(Tuple(String,String))'),tuple(source_service,session_id)))"
    <> " OR arrayExists(kv -> has(JSONExtract({admin_scope:String},'signals','Array(Tuple(String,String))'),kv),JSONExtractKeysAndValues(identifiers,'String')))))"

discoverIdentity :: Connection -> A.Value -> IO A.Value
discoverIdentity connection scope = do
  signals <- chJSON connection scope ("SELECT toJSONString(tuple(signal_kind,signal_value)) AS value FROM (SELECT signal_kind,signal_value FROM analytics.identity_signals FINAL WHERE " <> explicitSubject <> " UNION ALL SELECT sig.1 AS signal_kind,sig.2 AS signal_value FROM analytics.events_canonical ARRAY JOIN arrayConcat(JSONExtractKeysAndValues(identifiers,'String'),[(if(event_name IN ('identify','identify_once','alias'),'cookie',''),anonymous_id)]) AS sig WHERE " <> explicitSubject <> " AND sig.1!='' AND sig.2!='') GROUP BY signal_kind,signal_value")
  sessions <- chJSON connection scope ("SELECT toJSONString(tuple(source_service,session_id)) AS value FROM analytics.events_canonical WHERE " <> explicitSubject <> " AND session_id!='' GROUP BY source_service,session_id")
  pure (A.object ["signals" A..= signals, "sessions" A..= sessions])

-- | Reuse each CURRENT MV's SELECT and target columns, never replay an old
-- migration that could replace newer rich views. Source reads become canonical.
-- Every affected target is cleared before dependency-ordered replay. Retrying
-- after interruption starts the same complete rebuild under the persisted fence.
rebuildDerived :: Connection -> IO ()
rebuildDerived = rebuildReplicas . directReplicaConnections

rebuildReplicas :: ReplicaConnections -> IO ()
rebuildReplicas replicas = do
  synchronizeSchema replicas
  let connection = coordinator replicas
      readDefinitions c = forM projections $ \(viewName, target) -> do
        rows <- chJSON c A.Null ("SELECT toJSONString(as_select) AS value FROM system.tables WHERE database='analytics' AND name='" <> viewName <> "' AND engine='MaterializedView'")
        source <- case rows of
          [A.String sql] | "SELECT" `Text.isPrefixOf` sql -> pure sql
          _ -> failConsistency "required current maintenance projection is absent"
        cols <- chJSON c A.Null ("SELECT toJSONString(name) AS value FROM system.columns WHERE database='analytics' AND table='" <> target <> "' ORDER BY position")
        names <- traverse (either (const (failConsistency "invalid current projection column")) pure . A.parseEither A.parseJSON) cols
        when (null names) (failConsistency "current maintenance target has no columns")
        let canonical = Text.replace "analytics.events_raw" "analytics.events_canonical" source
        unless ("analytics.events_canonical" `Text.isInfixOf` canonical || "analytics.identity_signals" `Text.isInfixOf` canonical) (failConsistency "unsupported current projection source; maintenance fence retained")
        pure (target, Text.intercalate "," (map quoteName names), canonical)
  definitions <- withinBudget "read coordinator projections" (readDefinitions connection)
  forM_ (replicaConnections replicas) $ \(sid, c) -> do
    installed <- withinBudget ("read projections " <> sid) (readDefinitions c)
    unless (installed == definitions) (failConsistency ("projection definitions differ on replica " <> Text.unpack sid))
  -- Every target is cleared before any replay. Retry starts here again, with
  -- per-statement deduplication disabled so old block IDs cannot suppress rows.
  forM_ definitions $ \(target, _, _) -> do
    withinBudget ("truncate " <> target) (chCommand connection A.Null ("TRUNCATE TABLE analytics." <> target))
    synchronizeSchema replicas
    synchronizeTables replicas [target]
  forM_ definitions $ \(target, columns, source) -> do
    withinBudget ("rebuild " <> target) $ chCommand connection A.Null ("INSERT INTO analytics." <> target <> " (" <> columns <> ") SELECT " <> columns <> " FROM (" <> source <> ") SETTINGS insert_deduplicate=0,deduplicate_blocks_in_dependent_materialized_views=0")
    synchronizeTables replicas [target]
  verifyReplicaMutations replicas
  verifyReplicaPopulations replicas

verifyReplicaPopulations :: ReplicaConnections -> IO ()
verifyReplicaPopulations replicas = do
  synchronizeTables replicas maintenanceTables
  populations <- forM (replicaConnections replicas) $ \(sid, c) -> withinBudget ("verify population " <> sid) $ do
    -- groupArray is bounded by the server memory budget and fails explicitly;
    -- no count-only success can conceal equal-sized different populations.
    canonical <- chJSON c A.Null "SELECT toJSONString(arraySort(groupArray(tuple(account_id,event_id)))) AS value FROM analytics.events_canonical"
    public <- chJSON c A.Null "SELECT toJSONString(arraySort(groupArray(tuple(account_id,event_id)))) AS value FROM analytics.events_resolved"
    unless (canonical == public) (failConsistency ("public projection differs from canonical population on " <> Text.unpack sid))
    pure canonical
  case populations of
    first : rest -> unless (all (== first) rest) (failConsistency "canonical event populations differ across replicas")
    [] -> failConsistency "missing replica population observations"

projections :: [(Text, Text)]
projections =
  [ ("mv_identity_signals", "identity_signals"),
    ("mv_identity_signal_users", "identity_signal_users"),
    ("mv_identity_session_users", "identity_session_users"),
    ("mv_identity_context_signals", "identity_context_signals"),
    ("mv_daily_event_counts", "daily_event_counts"),
    ("mv_page_views_by_route", "page_views_by_route"),
    ("mv_dau", "dau"),
    ("mv_wau", "wau"),
    ("mv_experiment_exposures", "experiment_exposures"),
    ("mv_sessions", "sessions"),
    ("mv_user_properties", "user_properties"),
    ("mv_user_properties_once", "user_properties_once"),
    ("mv_organization_properties", "organization_properties"),
    ("mv_user_organizations", "user_organizations")
  ]

verifyMutations :: Connection -> IO ()
verifyMutations = verifyReplicaMutations . directReplicaConnections

verifyReplicaMutations :: ReplicaConnections -> IO ()
verifyReplicaMutations replicas = do
  -- Consume the replication logs before an empty mutation list can prove absence.
  synchronizeTables replicas maintenanceTables
  forM_ (replicaConnections replicas) $ \(sid, c) ->
    withinBudget ("verify mutations " <> sid) $
      let loop = do
            rows <- chJSON c A.Null "SELECT toJSONString(tuple(table,mutation_id,toBool(is_done),toBool(latest_fail_reason!=''))) AS value FROM system.mutations WHERE database='analytics' AND (NOT is_done OR latest_fail_reason!='') ORDER BY table,mutation_id"
            observations <- traverse (either (const (failConsistency "malformed mutation observation")) pure . A.parseEither A.parseJSON) rows :: IO [(Text, Text, Bool, Bool)]
            forM_ observations $ \(table, mutation, _, failed) -> when failed (failConsistency ("mutation failed on " <> Text.unpack sid <> ": " <> Text.unpack table <> "/" <> Text.unpack mutation <> "; native failure details redacted; fence retained"))
            unless (null observations) (threadDelay 100_000 >> loop)
       in loop

quoteName :: Text -> Text
quoteName name = "`" <> Text.replace "`" "``" name <> "`"

-- A cancelled native client can leave its server insert completing. Native
-- INSERT negotiates a sample block before sending rows, so any write that can
-- still commit data is already registered in system.processes. Async inserts
-- are explicitly disabled on the writer's physical connections.
quiesceRawWrites :: Connection -> IO ()
quiesceRawWrites = quiesceReplicaWrites . directReplicaConnections

quiesceReplicaWrites :: ReplicaConnections -> IO ()
quiesceReplicaWrites replicas = do
  pending <- newIORef (map fst (replicaConnections replicas))
  let loop = do
        checkIdentities replicas
        observations <- forM (replicaConnections replicas) $ \(sid, c) -> do
          active <- withinBudget ("observe raw INSERTs replica " <> sid) $ chJSON c A.Null "SELECT toJSONString(count()) AS value FROM system.processes WHERE lower(query_kind)='insert' AND position(query,'events_raw')>0 AND (current_database='analytics' OR position(query,'analytics.events_raw')>0 OR position(query,'`analytics`.`events_raw`')>0)"
          case active of
            [A.Number n] | n >= 0 && n == fromInteger (floor n :: Integer) -> pure (sid, n == 0)
            _ -> failConsistency ("malformed raw INSERT observation on " <> Text.unpack sid)
        let busy = [sid | (sid, False) <- observations]
        writeIORef pending busy
        unless (null busy) (threadDelay 100_000 >> loop)
  result <- timeout 60_000_000 loop
  case result of
    Just () -> pure ()
    Nothing -> readIORef pending >>= \ids -> failConsistency ("raw INSERT drain deadline expired; pending replicas=" <> show ids <> "; maintenance fence retained")

-- These are supplementary observations, never evidence that old clients cannot
-- submit more work. A hidden/denied view is explicitly unavailable, not zero.
data WriteObservation = ObservationUnavailable | NoVisibleWrites | VisibleWrites
  deriving (Eq, Show)

observeReplicaWrites :: ReplicaConnections -> IO [(Text, WriteObservation)]
observeReplicaWrites replicas = forM (replicaConnections replicas) $ \(sid, c) -> do
  observation <- trySynchronous $ withinBudget ("supplementary raw INSERT observation " <> sid) $ chJSON c A.Null "SELECT toJSONString(count()) AS value FROM system.processes WHERE lower(query_kind)='insert' AND position(query,'events_raw')>0 AND (current_database='analytics' OR position(query,'analytics.events_raw')>0 OR position(query,'`analytics`.`events_raw`')>0)"
  pure
    ( sid,
      case observation of
        Right [A.Number n] | n > 0 -> VisibleWrites
        Right [A.Number 0] -> NoVisibleWrites
        _ -> ObservationUnavailable
    )
