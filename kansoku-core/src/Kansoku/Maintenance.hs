-- | A persisted global fence plus shared session locks across complete operations.
module Kansoku.Maintenance
  ( MaintenancePool,
    MaintenanceUnavailable (..),
    newMaintenancePool,
    closeMaintenancePool,
    withTraffic,
    rewriteQueuedEvents,
  )
where

import Control.Exception (Exception, SomeException, mask, onException, throwIO, try)
import Data.Aeson qualified as A
import Data.Aeson.Types qualified as A
import Data.Pool qualified as Pool
import Database.PostgreSQL.LibPQ qualified as PQ
import Kansoku.Exception (catchSynchronous, trySynchronous)
import Kansoku.Ingest.QueuedEvent (QueuedEvent)
import Kansoku.Postgres.Direct
import Kansoku.Prelude
import System.Timeout (timeout)

newtype MaintenancePool = MaintenancePool (Pool.Pool PQ.Connection)

data MaintenanceUnavailable = MaintenanceUnavailable
  deriving stock (Show)
  deriving anyclass (Exception)

coordination :: IO a -> IO a
coordination action = catchSynchronous action (const (throwIO MaintenanceUnavailable))

newMaintenancePool :: Text -> IO MaintenancePool
newMaintenancePool settings =
  MaintenancePool
    <$> Pool.newPool
      (Pool.setNumStripes (Just 1) $ Pool.defaultPoolConfig (coordination (openPostgres settings)) closePostgres 60 20)

closeMaintenancePool :: MaintenancePool -> IO ()
closeMaintenancePool (MaintenancePool pool) = Pool.destroyAllResources pool

-- | Pool admission is fail-fast; lock/status queries have a 500ms bound. Holding
-- this connection until the whole action ends closes the check-then-mutate race.
withTraffic :: MaintenancePool -> (PQ.Connection -> IO a) -> IO a
withTraffic (MaintenancePool pool) action = mask $ \restore -> do
  admitted <- Pool.tryTakeResource pool
  (connection, local) <- maybe (throwIO MaintenanceUnavailable) pure admitted
  let destroy = Pool.destroyResource pool local connection
  result <- try $ restore $ do
    locked <- coordination $ timeout 500_000 (pg connection "SELECT to_jsonb(pg_try_advisory_lock_shared(726401,1)) WHERE $1 IS NOT NULL" A.Null)
    unless (locked == Just (A.Bool True)) (throwIO MaintenanceUnavailable)
    ready <- coordination $ timeout 500_000 (pg connection "SELECT to_jsonb(active_job IS NULL) FROM kansoku.maintenance_fence WHERE singleton AND $1 IS NOT NULL" A.Null)
    unless (ready == Just (A.Bool True)) (throwIO MaintenanceUnavailable)
    action connection
  case result of
    Left (err :: SomeException) -> destroy >> throwIO err
    Right value -> do
      -- The action may already have sent its HTTP response. Failed cleanup
      -- disposes the session; it must never attempt a second response.
      unlocked <- trySynchronous (timeout 500_000 (pg connection "SELECT to_jsonb(pg_advisory_unlock_shared(726401,1)) WHERE $1 IS NOT NULL" A.Null)) `onException` destroy
      case unlocked of
        Right (Just (A.Bool True)) -> Pool.putResource local connection
        _ -> destroy
      pure value

-- | Re-evaluate persisted dispositions on EVERY insert attempt, including a
-- pre-fence batch held by storage recovery. Policies contain IDs/flags, no saved signals.
rewriteQueuedEvents :: PQ.Connection -> [QueuedEvent] -> IO [QueuedEvent]
rewriteQueuedEvents connection events = do
  result <-
    pg
      connection
      "SELECT coalesce(jsonb_agg(kansoku.apply_event_disposition(e.value,d.scrub_identity,d.scrub_traits,p.fingerprint_cutoff IS NOT NULL AND (e.value#>>'{event,occurredAt}')::timestamptz<p.fingerprint_cutoff) ORDER BY e.ordinality) FILTER (WHERE NOT coalesce(d.delete_event,false) AND (p.cutoff IS NULL OR (e.value#>>'{event,occurredAt}')::timestamptz>=p.cutoff)), '[]'::jsonb) FROM jsonb_array_elements($1) WITH ORDINALITY e(value,ordinality) CROSS JOIN kansoku.retention_policy p LEFT JOIN kansoku.event_dispositions d ON d.account_id=e.value#>>'{event,accountId}' AND d.event_id=e.value#>>'{event,eventId}'"
      (A.toJSON events)
  either (const (fail "invalid rewritten queue envelope")) pure (A.parseEither A.parseJSON result)
