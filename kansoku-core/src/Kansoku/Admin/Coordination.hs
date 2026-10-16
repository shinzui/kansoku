-- | Target-wide administrative leases and persistent migration fences. Closing
-- a backend releases locks, never a fence or predecessor-quiescence requirement.
module Kansoku.Admin.Coordination
  ( SessionIdentity (..),
    beginSession,
    withSessionLease,
    leaseAlive,
    finishSession,
    sessionStatus,
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

data SessionIdentity = SessionIdentity
  {sessionId :: !Text, targetKey :: !Text, serverId :: !Text, ledgerId :: !Text}

parameters :: SessionIdentity -> A.Value
parameters s = A.object ["id" A..= sessionId s, "target" A..= targetKey s, "server" A..= serverId s, "ledger" A..= ledgerId s]

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

beginSession :: Text -> Text -> Text -> Text -> A.Value -> IO A.Value
beginSession settings target server ledger audit = withAdministrator settings $ \c -> do
  administratorLock c
  pgScript c "BEGIN"
  ready <- query c "SELECT to_jsonb(active_job IS NULL AND active_migration_session IS NULL) FROM kansoku.maintenance_fence WHERE singleton AND $1 IS NOT NULL FOR UPDATE" A.Null
  unless (ready == A.Bool True) (fail "unfinished administrator owns the fence")
  created <- query c "INSERT INTO kansoku.clickhouse_migration_sessions(target_key,server_id,ledger_id,audit) VALUES($1->>'target',($1->>'server')::uuid,($1->>'ledger')::uuid,$1->'audit') RETURNING to_jsonb(clickhouse_migration_sessions)" (A.object ["target" A..= target, "server" A..= server, "ledger" A..= ledger, "audit" A..= audit])
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
  row <- query c "SELECT to_jsonb(s) FROM kansoku.clickhouse_migration_sessions s JOIN kansoku.maintenance_fence f ON f.active_migration_session=s.id WHERE s.id=($1->>'id')::uuid AND s.target_key=$1->>'target' AND s.server_id=($1->>'server')::uuid AND s.ledger_id=($1->>'ledger')::uuid AND s.completed_at IS NULL" (parameters identity)
  when (row == A.Null) (fail "migration session identity or fence mismatch")
  trafficLock c
  case mutation of
    Nothing -> pure ()
    Just (predecessor, entryName, evidence) -> do
      unless (field "entry" row == A.toJSON predecessor) (fail "stale predecessor-quiescence evidence")
      when (entryName `elem` ["up", "maintenance-finish"]) $ unless (field "outcome" row `elem` [A.String "pre-session", A.String "acknowledged"]) (fail "previous native entry requires explicit repair or reconciliation")
      unless (evidence /= A.Null) (fail "explicit predecessor-quiescence evidence required")
      void $ query c "UPDATE kansoku.clickhouse_migration_sessions SET entry=entry+1,pending_entry=$1->>'command',quiescence=$1->'evidence',outcome='submitted' WHERE id=($1->>'id')::uuid" (A.object ["id" A..= sessionId identity, "command" A..= entryName, "evidence" A..= evidence])
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
  query c "SELECT to_jsonb(s) FROM kansoku.clickhouse_migration_sessions s WHERE (s.id=nullif($1->>'id','')::uuid OR ($1->>'id'='' AND s.completed_at IS NULL)) AND s.target_key=$1->>'target' AND s.server_id=($1->>'server')::uuid AND s.ledger_id=($1->>'ledger')::uuid" (parameters identity)

-- Preserve exact receipt strings before releasing exclusion or reporting success.
-- Process loss before this update still leaves the pre-submission marker.
recordNativeOutcome :: PQ.Connection -> SessionIdentity -> Bool -> [Text] -> IO ()
recordNativeOutcome c identity success receipts = do
  void $ query c "UPDATE kansoku.clickhouse_migration_sessions SET outcome=CASE WHEN ($1->>'success')::boolean THEN 'acknowledged' ELSE 'failed' END,pending_receipts=CASE WHEN ($1->>'success')::boolean THEN '[]'::jsonb ELSE pending_receipts||($1->'receipts') END WHERE id=($1->>'id')::uuid AND completed_at IS NULL" (A.object ["id" A..= sessionId identity, "success" A..= success, "receipts" A..= receipts])

requireReceipts :: PQ.Connection -> SessionIdentity -> [Text] -> IO ()
requireReceipts c identity supplied = do
  row <- query c "SELECT to_jsonb(pending_receipts <@ ($1->'receipts')) FROM kansoku.clickhouse_migration_sessions WHERE id=($1->>'id')::uuid" (A.object ["id" A..= sessionId identity, "receipts" A..= supplied])
  unless (row == A.Bool True) (fail "all retained pending append receipts are required")
