-- | Target-wide administrative leases and persistent migration fences. Closing
-- a backend releases locks, never a fence or predecessor-quiescence requirement.
module Kansoku.Admin.Coordination
  ( SessionIdentity (..),
    SessionTarget (..),
    beginSession,
    withSessionLease,
    leaseAlive,
    finishSession,
    sessionStatus,
    recoveryContext,
    predecessorState,
    findRecoverySet,
    retainRecoverySet,
    newRecoveryId,
    withRebindLease,
    recordNativeOutcome,
    requireReceipts,
  )
where

import Control.Exception (bracket)
import Data.Aeson qualified as A
import Database.PostgreSQL.LibPQ qualified as PQ
import Kansoku.Admin.Store (field, query)
import Kansoku.Postgres.Direct
import Kansoku.Prelude
import System.Timeout (timeout)

data SessionTarget = DirectTarget !Text | ReplicatedTarget !Text ![Text]

data SessionIdentity = SessionIdentity
  {sessionId :: !Text, targetKey :: !Text, sessionTarget :: !SessionTarget, ledgerId :: !Text}

parameters :: SessionIdentity -> A.Value
parameters s =
  A.object
    ( ["id" A..= sessionId s, "target" A..= targetKey s, "ledger" A..= ledgerId s] ++ case sessionTarget s of
        DirectTarget sid -> ["topology" A..= ("direct" :: Text), "server" A..= sid, "cluster" A..= A.Null, "replicas" A..= ([] :: [Text])]
        ReplicatedTarget name ids -> ["topology" A..= ("replicated" :: Text), "server" A..= A.Null, "cluster" A..= name, "replicas" A..= ids]
    )

-- Shared exact identity predicate for both lease acquisition and diagnosis.
identityPredicate :: Text
identityPredicate = "s.target_key=$1->>'target' AND s.server_id IS NOT DISTINCT FROM ($1->>'server')::uuid AND s.ledger_id=($1->>'ledger')::uuid AND s.topology=$1->>'topology' AND s.cluster_name IS NOT DISTINCT FROM ($1->>'cluster') AND s.replica_ids=ARRAY(SELECT jsonb_array_elements_text($1->'replicas')::uuid ORDER BY 1)"

-- Own a dedicated backend; no pooled connection may transfer the lease.
withAdministrator :: Text -> (PQ.Connection -> IO a) -> IO a
withAdministrator settings = bracket acquire closePostgres
  where
    acquire = do
      c <- openPostgres settings
      -- bracket protects even cancellation between acquiring and testing locks.
      pure c

administratorLock :: PQ.Connection -> IO ()
administratorLock c = do
  pgScript c "SET statement_timeout='3s'"
  locked <- query c "SELECT to_jsonb(pg_try_advisory_lock(726401,2)) WHERE $1 IS NOT NULL" A.Null
  unless (locked == A.Bool True) (fail "another administrator is active")

trafficLock :: PQ.Connection -> IO ()
trafficLock c = do
  -- The persistent fence has already stopped new admission. A bounded wait
  -- drains cooperating scopes, but does not prove native request quiescence.
  pgScript c "SET statement_timeout='30s'"
  pgScript c "SELECT to_jsonb(pg_advisory_lock(726401,1))"
  pgScript c "SET statement_timeout='3s'"

beginSession :: Text -> Text -> SessionTarget -> Text -> A.Value -> IO A.Value
beginSession settings target server ledger audit = withAdministrator settings $ \c -> do
  administratorLock c
  pgScript c "BEGIN"
  ready <- query c "SELECT to_jsonb(active_job IS NULL AND active_migration_session IS NULL) FROM kansoku.maintenance_fence WHERE singleton AND $1 IS NOT NULL FOR UPDATE" A.Null
  unless (ready == A.Bool True) (fail "unfinished administrator owns the fence")
  let payload = case parameters (SessionIdentity "" target server ledger) of
        A.Object values -> A.Object (values <> case A.object ["audit" A..= audit] of A.Object extra -> extra; _ -> mempty)
        other -> other
  created <- query c "INSERT INTO kansoku.clickhouse_migration_sessions(target_key,server_id,ledger_id,audit,topology,cluster_name,replica_ids) VALUES($1->>'target',($1->>'server')::uuid,($1->>'ledger')::uuid,$1->'audit',$1->>'topology',$1->>'cluster',ARRAY(SELECT jsonb_array_elements_text($1->'replicas')::uuid ORDER BY 1)) RETURNING to_jsonb(clickhouse_migration_sessions)" payload
  void $ query c "UPDATE kansoku.maintenance_fence SET active_migration_session=($1->>'id')::uuid WHERE singleton" created
  pgScript c "COMMIT"
  trafficLock c
  pure created

-- The expected predecessor counter binds external evidence to this session and
-- its latest entry. Persist the next marker BEFORE any native submission. Both
-- clean release and failure leave it pending for a future explicit drain.
withSessionLease :: Text -> SessionIdentity -> Maybe (Integer, Text, A.Value) -> (PQ.Connection -> IO a) -> IO a
withSessionLease settings identity mutation action = withAdministrator settings $ \c -> do
  administratorLock c
  row <- query c ("SELECT to_jsonb(s) FROM kansoku.clickhouse_migration_sessions s JOIN kansoku.maintenance_fence f ON f.active_migration_session=s.id WHERE s.id=($1->>'id')::uuid AND s.completed_at IS NULL AND " <> identityPredicate) (parameters identity)
  when (row == A.Null) (fail "migration session identity or fence mismatch")
  trafficLock c
  case mutation of
    Nothing -> pure ()
    Just (predecessor, entryName, evidence) -> do
      unless (field "entry" row == A.toJSON predecessor) (fail "stale predecessor-quiescence evidence")
      when (entryName `elem` ["up", "maintenance-finish"]) $ unless (field "outcome" row `elem` [A.String "pre-session", A.String "acknowledged"]) (fail "previous native entry requires explicit repair or reconciliation")
      unless (evidence /= A.Null) (fail "explicit predecessor-quiescence evidence required")
      -- One PostgreSQL statement retains the proof and advances its counter.
      -- An audit failure rolls back the marker before any native action runs.
      void $ query c "WITH submitted AS (UPDATE kansoku.clickhouse_migration_sessions SET entry=entry+1,last_entry_at=clock_timestamp(),pending_entry=$1->>'command',quiescence=$1->'evidence',outcome='submitted' WHERE id=($1->>'id')::uuid RETURNING id,entry,pending_entry,quiescence) INSERT INTO kansoku.clickhouse_migration_entry_audit(session_id,entry,command,evidence) SELECT id,entry,pending_entry,quiescence FROM submitted" (A.object ["id" A..= sessionId identity, "command" A..= entryName, "evidence" A..= evidence])
  action c

-- Bounded test of the actual retained backend's exclusive session locks. Never
-- treat a disconnected backend or failed exchange as a live lease.
leaseAlive :: PQ.Connection -> IO Bool
leaseAlive c = do
  result <- timeout 500000 $ query c "SELECT to_jsonb(count(*)=2) FROM pg_locks WHERE pid=pg_backend_pid() AND locktype='advisory' AND classid=726401 AND objid IN (1,2) AND objsubid=2 AND mode='ExclusiveLock' AND granted AND $1 IS NOT NULL" A.Null
  pure (result == Just (A.Bool True))

-- Called only after native currentness inspection under this retained lease.
finishSession :: PQ.Connection -> SessionIdentity -> IO ()
finishSession c identity = do
  alive <- leaseAlive c
  unless alive (fail "administrative lease lost")
  pgScript c "BEGIN"
  closed <- query c "UPDATE kansoku.clickhouse_migration_sessions s SET completed_at=now(),pending_entry='complete' FROM kansoku.maintenance_fence f WHERE f.active_migration_session=s.id AND s.id=($1->>'id')::uuid AND s.completed_at IS NULL RETURNING to_jsonb(s.id)" (parameters identity)
  unless (closed == A.String (sessionId identity)) (fail "migration fence ownership changed")
  void $ query c "UPDATE kansoku.maintenance_fence SET active_migration_session=NULL WHERE singleton AND active_migration_session=($1->>'id')::uuid" (parameters identity)
  pgScript c "COMMIT"

-- Unguarded diagnosis is available even while another administrator holds locks.
sessionStatus :: Text -> SessionIdentity -> IO A.Value
sessionStatus settings identity = withPostgres settings $ \c -> do
  pgScript c "SET statement_timeout='3s'"
  query c ("SELECT to_jsonb(s) FROM kansoku.clickhouse_migration_sessions s WHERE (s.id=nullif($1->>'id','')::uuid OR ($1->>'id'='' AND s.completed_at IS NULL)) AND " <> identityPredicate) (parameters identity)

-- Preserve exact receipt strings before releasing exclusion or reporting success.
-- Process loss before this update still leaves the pre-submission marker.
recordNativeOutcome :: PQ.Connection -> SessionIdentity -> Bool -> [Text] -> IO ()
recordNativeOutcome c identity success receipts = do
  void $ query c "UPDATE kansoku.clickhouse_migration_sessions SET outcome=CASE WHEN ($1->>'success')::boolean THEN 'acknowledged' ELSE 'failed' END,pending_receipts=CASE WHEN ($1->>'success')::boolean THEN '[]'::jsonb ELSE pending_receipts||($1->'receipts') END WHERE id=($1->>'id')::uuid AND completed_at IS NULL" (A.object ["id" A..= sessionId identity, "success" A..= success, "receipts" A..= receipts])

requireReceipts :: PQ.Connection -> SessionIdentity -> [Text] -> IO ()
requireReceipts c identity supplied = do
  row <- query c "SELECT to_jsonb(pending_receipts <@ ($1->'receipts')) FROM kansoku.clickhouse_migration_sessions WHERE id=($1->>'id')::uuid" (A.object ["id" A..= sessionId identity, "receipts" A..= supplied])
  unless (row == A.Bool True) (fail "all retained pending append receipts are required")

-- Read-only operator context. The subsequent lease still checks exact ownership
-- and counters; this diagnosis never establishes external quiescence.
recoveryContext :: Text -> SessionIdentity -> IO A.Value
recoveryContext settings identity = withPostgres settings $ \c ->
  query c ("SELECT jsonb_build_object('postgresDatabase',current_database(),'retentionPolicy',(SELECT to_jsonb(p) FROM kansoku.retention_policy p WHERE singleton),'session',to_jsonb(s),'fenced',EXISTS(SELECT 1 FROM kansoku.maintenance_fence f WHERE f.active_migration_session=s.id)) FROM kansoku.clickhouse_migration_sessions s WHERE s.id=($1->>'id')::uuid AND " <> identityPredicate) (parameters identity)

predecessorState :: A.Value -> A.Value
predecessorState row = A.object ["entry" A..= field "entry" row, "outcome" A..= field "outcome" row, "pendingEntry" A..= field "pending_entry" row, "pendingReceipts" A..= field "pending_receipts" row, "lastEntryAt" A..= field "last_entry_at" row]

findRecoverySet :: Text -> SessionIdentity -> Text -> IO A.Value
findRecoverySet settings identity digest = withPostgres settings $ \c ->
  query c "SELECT to_jsonb(r) FROM kansoku.maintenance_recovery_sets r WHERE session_id=($1->>'id')::uuid AND plan_sha256=$1->>'plan' ORDER BY predecessor DESC LIMIT 1" (A.object ["id" A..= sessionId identity, "plan" A..= digest])

-- Called only while this host holds the retained administrator lease. The
-- counter check also prevents an unleased stale acceptance from being retained.
retainRecoverySet :: Text -> SessionIdentity -> Integer -> Text -> Text -> Maybe Text -> Text -> A.Value -> IO ()
retainRecoverySet settings identity predecessor plan kind ident digest document = withPostgres settings $ \c -> do
  let payload = case parameters identity of
        A.Object base -> case A.object ["predecessor" A..= predecessor, "plan" A..= plan, "kind" A..= kind, "recovery" A..= ident, "digest" A..= digest, "document" A..= document] of
          A.Object extra -> A.Object (extra <> base)
          _ -> error "invalid recovery payload"
        _ -> error "invalid identity payload"
  void $ query c ("INSERT INTO kansoku.maintenance_recovery_sets(session_id,recovery_id,predecessor,plan_sha256,kind,document,document_sha256) SELECT s.id,coalesce(($1->>'recovery')::uuid,gen_random_uuid()),($1->>'predecessor')::bigint,$1->>'plan',$1->>'kind',$1->'document',$1->>'digest' FROM kansoku.clickhouse_migration_sessions s JOIN kansoku.maintenance_fence f ON f.active_migration_session=s.id WHERE s.id=($1->>'id')::uuid AND s.entry=($1->>'predecessor')::bigint+1 AND s.completed_at IS NULL AND " <> identityPredicate <> " ON CONFLICT DO NOTHING") payload
  accepted <- query c "SELECT to_jsonb(r) FROM kansoku.maintenance_recovery_sets r WHERE session_id=($1->>'id')::uuid AND ($1->>'recovery' IS NULL OR recovery_id=($1->>'recovery')::uuid) AND predecessor=($1->>'predecessor')::bigint AND plan_sha256=$1->>'plan' AND kind=$1->>'kind' AND document_sha256=$1->>'digest'" payload
  when (accepted == A.Null) (fail "recovery set conflicts with retained owner, boundary or manifest; fence retained")

newRecoveryId :: Text -> IO Text
newRecoveryId settings = withPostgres settings $ \c -> do
  value <- query c "SELECT to_jsonb(gen_random_uuid()) WHERE $1 IS NOT NULL" A.Null
  case value of
    A.String ident -> pure ident
    _ -> fail "Cannot allocate recovery identifier"

-- Recovery owns the ordinary administrator and traffic exclusions, while
-- deliberately addressing the retained OLD identity. The observer executes
-- before the atomic binding/audit transition. Replay returns the retained audit.
withRebindLease :: Text -> SessionIdentity -> Text -> A.Value -> (A.Value -> IO A.Value) -> IO A.Value
withRebindLease settings old newServer request observe = withAdministrator settings $ \c -> do
  administratorLock c
  trafficLock c
  let payload = case parameters old of
        A.Object base -> case A.object ["newServer" A..= newServer, "request" A..= request] of
          A.Object extra -> A.Object (base <> extra)
          _ -> error "invalid rebind request"
        _ -> error "invalid recovery identity"
  previous <- query c "SELECT to_jsonb(a) FROM kansoku.clickhouse_server_rebindings a JOIN kansoku.clickhouse_migration_sessions s ON s.id=a.session_id JOIN kansoku.maintenance_fence f ON f.active_migration_session=s.id WHERE a.session_id=($1->>'id')::uuid AND a.request=$1->'request' AND s.server_id=($1->>'newServer')::uuid AND s.target_key=$1->>'target' AND s.ledger_id=($1->>'ledger')::uuid AND s.topology='direct' AND s.completed_at IS NULL" payload
  if previous /= A.Null
    then pure previous
    else do
      row <- query c ("SELECT to_jsonb(s) FROM kansoku.clickhouse_migration_sessions s JOIN kansoku.maintenance_fence f ON f.active_migration_session=s.id WHERE s.id=($1->>'id')::uuid AND s.completed_at IS NULL AND " <> identityPredicate) payload
      when (row == A.Null) (fail "Original recovery identity or persistent fence mismatch")
      proof <- observe row
      let transition = case payload of
            A.Object base -> case A.object ["oldState" A..= row, "proof" A..= proof] of
              A.Object extra -> A.Object (base <> extra)
              _ -> error "invalid rebind proof"
            _ -> error "invalid rebind payload"
      -- Compare the entire old row, preserving all counters and pending receipts.
      -- Inserting the audit and changing the binding share one SQL statement.
      accepted <- query c "WITH rebound AS (UPDATE kansoku.clickhouse_migration_sessions s SET server_id=($1->>'newServer')::uuid FROM kansoku.maintenance_fence f WHERE f.active_migration_session=s.id AND s.id=($1->>'id')::uuid AND to_jsonb(s)=$1->'oldState' AND s.completed_at IS NULL RETURNING s.id), audited AS (INSERT INTO kansoku.clickhouse_server_rebindings(session_id,old_server_id,new_server_id,request,proof,old_state) SELECT id,($1->>'server')::uuid,($1->>'newServer')::uuid,$1->'request',$1->'proof',$1->'oldState' FROM rebound RETURNING *), retained AS (INSERT INTO kansoku.maintenance_recovery_sets(session_id,recovery_id,predecessor,plan_sha256,kind,document,document_sha256) SELECT session_id,($1->'proof'->'manifest'->>'id')::uuid,($1->'proof'->'manifest'->>'predecessor')::bigint,$1->'proof'->'manifest'->>'planSha256','snapshot',$1->'proof'->'manifest',$1->'request'->>'manifestSha256' FROM audited RETURNING session_id) SELECT to_jsonb(a) FROM audited a JOIN retained r ON r.session_id=a.session_id" transition
      when (accepted == A.Null) (fail "Recovery binding changed before compare-and-set; fence retained")
      pure accepted
