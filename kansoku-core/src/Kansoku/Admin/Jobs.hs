-- | Resumable, fenced cross-store jobs. PostgreSQL is the authoritative journal.
module Kansoku.Admin.Jobs (runJob, resumeJob, writePrivate) where

import ClickHaskell (Connection, closeConnection)
import Control.Exception (bracket, bracketOnError)
import Control.Monad (forM, forM_)
import Data.Aeson qualified as A
import Data.ByteString.Lazy qualified as LBS
import Data.List (elemIndex, nub)
import Data.Text qualified as Text
import Data.UUID qualified as UUID
import Data.UUID.V4 (nextRandom)
import Database.PostgreSQL.LibPQ qualified as PQ
import Kansoku.Admin.ClickHouse
import Kansoku.Admin.Store
import Kansoku.Auth.Token (Token (..), hashToken)
import Kansoku.ClickHouse (clickHouseConfigFromConfig, openClickHouse)
import Kansoku.Config (Config)
import Kansoku.Event (AccountId (..), UserId (..))
import Kansoku.PersonProperties (TraitErasureMode (..), eraseUserTraits)
import Kansoku.Postgres.Direct (pgScript)
import Kansoku.Prelude
import System.Environment (lookupEnv)
import System.IO (hClose, hPutStrLn, stderr)
import System.Posix.Files (setFdMode)
import System.Posix.IO (OpenFileFlags (..), OpenMode (WriteOnly), closeFd, defaultFileFlags, fdToHandle, openFd)

writePrivate :: Maybe FilePath -> A.Value -> IO FilePath
writePrivate requested value = do
  random <- UUID.toString <$> nextRandom
  directory <- fromMaybe "/tmp" <$> lookupEnv "TMPDIR"
  let path = fromMaybe (directory <> "/kansoku-admin-" <> random <> ".json") requested
  bracket
    (bracketOnError (openFd path WriteOnly defaultFileFlags {creat = Just 0o600, exclusive = True, nofollow = True, cloexec = True, sync = True}) closeFd (\fd -> setFdMode fd 0o600 >> fdToHandle fd))
    hClose
    (\handle -> LBS.hPut handle (A.encode value))
  pure path

merge :: A.Value -> A.Value -> A.Value
merge (A.Object left) (A.Object right) = A.Object (right <> left)
merge left _ = left

withNative :: Config -> (Connection -> IO a) -> IO a
withNative config action = bracket (openClickHouse (clickHouseConfigFromConfig config)) closeConnection $ \connection -> do
  chCommand connection A.Null ("SET max_execution_time=" <> Text.pack (show (max 60 (config ^. #metricsMaxExecutionSec))))
  chCommand connection A.Null ("SET max_memory_usage=" <> Text.pack (show (config ^. #metricsMaxMemoryBytes)))
  action connection

runJob :: Config -> PQ.Connection -> Text -> A.Value -> Bool -> Maybe FilePath -> IO A.Value
runJob config connection kind requestedScope confirm output = do
  scope <- if kind == "retention" then query connection "SELECT $1||jsonb_build_object('fingerprint_cutoff',greatest(($1->>'fingerprint_cutoff')::timestamptz,fingerprint_cutoff)) FROM kansoku.retention_policy WHERE singleton" requestedScope else pure requestedScope
  tables <- queueTables connection (config ^. #eventsQueueName)
  if not confirm
    then do
      admitMaintenanceTraffic connection
      withNative config $ \native -> previewJob native connection tables kind scope
    else do
      administrativeLock connection
      pgScript connection "BEGIN"
      active <- query connection "SELECT to_jsonb(active_job) FROM kansoku.maintenance_fence WHERE singleton AND $1 IS NOT NULL FOR UPDATE" A.Null
      unless (active == A.Null) (fail "an unfinished maintenance job must be resumed")
      job <- query connection "WITH created AS (INSERT INTO kansoku.maintenance_jobs(kind,scope) VALUES($1->>'kind',$1->'scope') RETURNING *) SELECT to_jsonb(created) FROM created" (A.object ["kind" A..= kind, "scope" A..= scope])
      void $ query connection "UPDATE kansoku.maintenance_fence SET active_job=($1->>'id')::uuid WHERE singleton" job
      pgScript connection "COMMIT"
      executeJob config connection tables job output

resumeJob :: Config -> PQ.Connection -> A.Value -> Bool -> Maybe FilePath -> IO A.Value
resumeJob config connection parameters confirm output = do
  job <- query connection "SELECT to_jsonb(j) FROM kansoku.maintenance_jobs j WHERE id=($1->>'id')::uuid" parameters
  when (job == A.Null) (fail "unknown maintenance job")
  if not confirm || field "stage" job == A.String "complete"
    then pure (receipt job)
    else do
      administrativeLock connection
      active <- query connection "SELECT to_jsonb(active_job) FROM kansoku.maintenance_fence WHERE singleton AND $1 IS NOT NULL" A.Null
      unless (active == field "id" job) (fail "maintenance fence ownership differs from resumed job")
      tables <- queueTables connection (config ^. #eventsQueueName)
      executeJob config connection tables job output

administrativeLock :: PQ.Connection -> IO ()
administrativeLock connection = do
  admitted <- query connection "SELECT to_jsonb(pg_try_advisory_lock(726401,2)) WHERE $1 IS NOT NULL" A.Null
  unless (admitted == A.Bool True) (fail "another administrator is active")

executeJob :: Config -> PQ.Connection -> [Text] -> A.Value -> Maybe FilePath -> IO A.Value
executeJob config connection tables initial output = do
  identifier <- decodeValue (field "id" initial) :: IO Text
  hPutStrLn stderr ("maintenance job " <> Text.unpack identifier <> "; persisted fence active")
  -- New traffic already observes the persisted fence. Wait for all admitted
  -- requests/inserts/replays to finish before touching either store.
  pgScript connection "SELECT to_jsonb(pg_advisory_lock(726401,1))"
  withNative config $ \native -> do
    quiesceRawWrites native
    let kind = field "kind" initial
        original = field "scope" initial
    discovered <-
      if field "stage" initial == A.String "created"
        then do
          details <- if kind == A.String "erase-user" then discovery native connection tables original else pure (A.object [])
          query connection "UPDATE kansoku.maintenance_jobs SET discovery=$1->'discovery',stage='discovered' WHERE id=($1->>'id')::uuid RETURNING to_jsonb(maintenance_jobs)" (merge initial (A.object ["discovery" A..= details]))
        else pure initial
    let discoveredCount key = case field key (field "discovery" discovered) of A.Array values -> length values; _ -> 0
        digest = hashToken (Token (case field "user" original of A.String value -> value; _ -> ""))
    snapshot <- writePrivate output (merge (receipt discovered) (A.object ["account" A..= field "account" original, "user_digest" A..= digest, "signal_count" A..= discoveredCount "signals", "session_count" A..= discoveredCount "sessions", "notice" A..= ("PostgreSQL retains full discovery while unfinished; this redacted receipt identifies the resumable job." :: Text)]))
    let scope = merge original (field "discovery" discovered)
        stages = ["created", "discovered", "disposed", "sources-scrubbed", "raw-mutated", "rebuilt", "verified", "complete"]
        before stage = fromMaybe 0 (elemIndex (field "stage" discovered) (map A.String stages)) < fromMaybe 0 (elemIndex (A.String stage) (map A.String stages))
        checkpoint stage = void $ query connection "UPDATE kansoku.maintenance_jobs SET stage=$1->>'stage' WHERE id=($1->>'id')::uuid" (merge initial (A.object ["stage" A..= (stage :: Text)]))
    when (before "disposed") $ do
      if kind == A.String "erase-user"
        then do
          raw <- chJSON native scope ("SELECT toJSONString(tuple(event_id,toBool(user_id=JSONExtractString({admin_scope:String},'user')))) AS value FROM analytics.events_canonical WHERE " <> affected)
          policies <- forM raw $ \row -> do
            (eventId, explicit) <- decodeValue row :: IO (Text, Bool)
            pure (A.object ["account_id" A..= field "account" scope, "event_id" A..= eventId, "delete_event" A..= (field "delete" scope == A.Bool True && explicit), "scrub_identity" A..= True, "scrub_traits" A..= explicit])
          pending <- queuedDispositions connection tables scope
          saveDispositions connection (policies <> pending)
        else do
          reserveExpiredNative native connection scope
          void $ query connection "UPDATE kansoku.retention_policy SET days=($1->>'days')::integer,cutoff=CASE WHEN ($1->>'days')::integer=0 THEN NULL ELSE ($1->>'cutoff')::timestamptz END,fingerprint_cutoff=greatest(fingerprint_cutoff,($1->>'fingerprint_cutoff')::timestamptz),revision=($1->>'revision')::bigint WHERE singleton" (merge scope (A.object ["revision" A..= field "revision" initial]))
      checkpoint "disposed"
    when (before "sources-scrubbed") $ do
      if kind == A.String "erase-user" then scrubSources connection tables scope else expireSources connection tables scope >> scrubFingerprintSources connection tables scope
      checkpoint "sources-scrubbed"
    when (before "raw-mutated") $ do
      if kind == A.String "erase-user" then eraseNative native scope else retainNative native (merge scope (A.object ["revision" A..= field "revision" initial]))
      checkpoint "raw-mutated"
    when (before "rebuilt") $ rebuildDerived native >> checkpoint "rebuilt"
    when (before "verified") $ do
      verifyMutations native
      if kind == A.String "erase-user"
        then do
          verifySources connection tables scope
          remaining <- chJSON native scope ("SELECT toJSONString(count()) AS value FROM analytics.identity_signals FINAL WHERE " <> explicitSubject)
          traits <- chJSON native scope ("SELECT toJSONString(count()) AS value FROM analytics.user_traits WHERE " <> explicitSubject)
          cohortMembers <- chJSON native scope ("SELECT toJSONString(count()) AS value FROM analytics.cohort_members WHERE " <> explicitSubject)
          unless (remaining == [A.Number 0] && traits == [A.Number 0] && cohortMembers == [A.Number 0]) (fail "erased evidence or current traits survived rebuild")
          when (field "delete" scope == A.Bool True) $ do
            explicit <- chJSON native scope ("SELECT toJSONString(count()) AS value FROM analytics.events_canonical WHERE " <> explicitSubject)
            unless (explicit == [A.Number 0]) (fail "explicit-user facts survived deletion")
        else do
          old <- chJSON native scope "SELECT toJSONString(count()) AS value FROM analytics.events_canonical WHERE occurred_at<parseDateTime64BestEffort(JSONExtractString({admin_scope:String},'cutoff'),3,'UTC')"
          unless (old == [A.Number 0]) (fail "expired facts survived retention")
          fingerprints <- chJSON native scope "SELECT toJSONString(count()) AS value FROM analytics.events_raw WHERE occurred_at<parseDateTime64BestEffort(JSONExtractString({admin_scope:String},'fingerprint_cutoff'),3,'UTC') AND JSONHas(identifiers,'fingerprint')"
          unless (fingerprints == [A.Number 0]) (fail "expired raw fingerprints survived retention")
      checkpoint "verified"
    -- No failed stage clears the fence. Final journal reduction and release are atomic.
    let reduced = A.object ["account" A..= field "account" original, "delete" A..= field "delete" original, "days" A..= field "days" original, "cutoff" A..= field "cutoff" original, "fingerprint_cutoff" A..= field "fingerprint_cutoff" original, "user_digest" A..= hashToken (Token (case field "user" original of A.String value -> value; _ -> ""))]
    pgScript connection "BEGIN"
    finished <- query connection "UPDATE kansoku.maintenance_jobs SET stage='complete',completed_at=now(),discovery='{}',scope=$1->'scope' WHERE id=($1->>'id')::uuid RETURNING to_jsonb(maintenance_jobs)" (merge initial (A.object ["scope" A..= reduced]))
    void $ query connection "UPDATE kansoku.maintenance_fence SET active_job=NULL WHERE singleton AND active_job=($1->>'id')::uuid" initial
    pgScript connection "COMMIT"
    pure (merge (receipt finished) (A.object ["snapshot" A..= snapshot]))

receipt :: A.Value -> A.Value
receipt job = A.object ["job_id" A..= field "id" job, "kind" A..= field "kind" job, "stage" A..= field "stage" job, "completed_at" A..= field "completed_at" job]

discovery :: Connection -> PQ.Connection -> [Text] -> A.Value -> IO A.Value
discovery native connection tables scope = do
  current <- discoverIdentity native scope
  queued <- discoverQueued connection tables scope
  signals <- nub <$> ((<>) <$> (decodeValue (field "signals" current) :: IO [(Text, Text)]) <*> decodeValue (field "signals" queued))
  sessions <- nub <$> ((<>) <$> (decodeValue (field "sessions" current) :: IO [(Text, Text)]) <*> decodeValue (field "sessions" queued))
  pure (A.object ["signals" A..= signals, "sessions" A..= sessions, "cookies" A..= [value | (kind, value) <- signals, kind == "cookie", not (Text.null value)]])

previewJob :: Connection -> PQ.Connection -> [Text] -> Text -> A.Value -> IO A.Value
previewJob native connection tables kind scope = do
  let predicate = if kind == "erase-user" then explicitSubject else "occurred_at<parseDateTime64BestEffort(JSONExtractString({admin_scope:String},'cutoff'),3,'UTC')"
  values <- chJSON native scope ("SELECT toJSONString(count()) AS value FROM analytics.events_canonical WHERE " <> predicate)
  count <- case values of [value] -> pure value; _ -> fail "invalid preview count"
  extra <-
    if kind == "erase-user"
      then do
        details <- discovery native connection tables scope
        affectedRows <- chJSON native (merge scope details) ("SELECT toJSONString(count()) AS value FROM analytics.events_canonical WHERE " <> affected)
        messages <- forM tables $ \table -> query connection ("SELECT jsonb_build_object('store',$1->>'store','matching',count(*)) FROM " <> table <> " WHERE kansoku.matches_erasure(message,$1)") (merge (merge scope details) (A.object ["store" A..= (if "pgmq.\"q_" `Text.isPrefixOf` table then "queue" else "archive" :: Text)]))
        affectedCount <- case affectedRows of [value] -> pure value; _ -> fail "invalid affected preview count"
        diagnostics <- query connection "SELECT to_jsonb(count(*)) FROM kansoku.ingest_rejections WHERE account_id=$1->>'account' AND kansoku.matches_erasure(jsonb_build_object('queueVersion',2,'event',jsonb_set(payload,'{accountId}',to_jsonb(account_id))),$1)" (merge scope details)
        pure (A.object ["user" A..= field "user" scope, "affected_facts" A..= affectedCount, "replayable_sources" A..= messages, "quarantine_payloads" A..= diagnostics])
      else do
        fp <- chJSON native scope "SELECT toJSONString(count()) AS value FROM analytics.events_canonical WHERE occurred_at<parseDateTime64BestEffort(JSONExtractString({admin_scope:String},'fingerprint_cutoff'),3,'UTC') AND JSONHas(identifiers,'fingerprint')"
        fpCount <- case fp of [value] -> pure value; _ -> fail "invalid fingerprint preview count"
        messages <- forM tables $ \table -> query connection ("SELECT jsonb_build_object('store',$1->>'store','expired_payloads',count(*) FILTER (WHERE coalesce(kansoku.event_time(message),enqueued_at)<($1->>'cutoff')::timestamptz),'fingerprint_payloads',count(*) FILTER (WHERE coalesce(kansoku.event_time(message),enqueued_at)<($1->>'fingerprint_cutoff')::timestamptz AND (kansoku.event_body(message)->'identifiers') ? 'fingerprint')) FROM " <> table) (merge scope (A.object ["store" A..= (if "pgmq.\"q_" `Text.isPrefixOf` table then "queue" else "archive" :: Text)]))
        pure (A.object ["days" A..= field "days" scope, "cutoff" A..= field "cutoff" scope, "fingerprint_cutoff" A..= field "fingerprint_cutoff" scope, "fingerprint_rows_in_scope" A..= fpCount, "replayable_sources" A..= messages])
  pure (merge (A.object ["preview" A..= True, "operation" A..= (if kind == "retention" then "applied_retention" else if field "delete" scope == A.Bool True then "explicit_event_deletion" else "identity_unlinking" :: Text), "account" A..= field "account" scope, "explicit_or_expired_facts" A..= count]) extra)

eraseNative :: Connection -> A.Value -> IO ()
eraseNative native scope = do
  account <- AccountId <$> decodeValue (field "account" scope)
  user <- UserId <$> decodeValue (field "user" scope)
  let deleting = field "delete" scope == A.Bool True
  chCommand native scope ("ALTER TABLE analytics.cohort_members DELETE WHERE " <> explicitSubject <> " SETTINGS mutations_sync=2")
  eraseUserTraits native account user (if deleting then DeleteTraitEvents else ScrubTraitEvents)
  when deleting $ chCommand native scope ("ALTER TABLE analytics.events_raw DELETE WHERE " <> explicitSubject <> " SETTINGS mutations_sync=2")
  chCommand native scope ("ALTER TABLE analytics.events_raw UPDATE identifiers='{}',anonymous_id='',session_id='',properties=if(event_name IN ('identify','identify_once','alias'),'{}',properties),governed_traits_valid=if(event_name IN ('identify','identify_once'),false,governed_traits_valid) WHERE " <> affected <> " SETTINGS mutations_sync=2")
  forM_ ["properties_json", "identity_context_key", "context_json"] $ \column -> chCommand native A.Null ("ALTER TABLE analytics.events_raw MATERIALIZE COLUMN " <> column <> " SETTINGS mutations_sync=2")

retainNative :: Connection -> A.Value -> IO ()
retainNative native scope = do
  chCommand native scope "INSERT INTO analytics.retention_policy SELECT 1,toUInt64(JSONExtractInt({admin_scope:String},'revision')),parseDateTime64BestEffort(JSONExtractString({admin_scope:String},'cutoff'),3,'UTC')"
  chCommand native scope "ALTER TABLE analytics.events_raw DELETE WHERE occurred_at<parseDateTime64BestEffort(JSONExtractString({admin_scope:String},'cutoff'),3,'UTC') SETTINGS mutations_sync=2"
  chCommand native scope "ALTER TABLE analytics.events_raw UPDATE identifiers=toJSONString(mapFromArrays(arrayMap(kv -> kv.1,arrayFilter(kv -> kv.1!='fingerprint',JSONExtractKeysAndValues(identifiers,'String'))),arrayMap(kv -> kv.2,arrayFilter(kv -> kv.1!='fingerprint',JSONExtractKeysAndValues(identifiers,'String'))))) WHERE occurred_at<parseDateTime64BestEffort(JSONExtractString({admin_scope:String},'fingerprint_cutoff'),3,'UTC') AND JSONHas(identifiers,'fingerprint') SETTINGS mutations_sync=2"
  chCommand native A.Null "ALTER TABLE analytics.events_raw MATERIALIZE COLUMN identity_context_key SETTINGS mutations_sync=2"
  chCommand native scope "ALTER TABLE analytics.events_raw MODIFY TTL toDateTime(occurred_at) DELETE WHERE occurred_at<parseDateTime64BestEffort(JSONExtractString({admin_scope:String},'cutoff'),3,'UTC')"

reserveExpiredNative :: Connection -> PQ.Connection -> A.Value -> IO ()
reserveExpiredNative native connection scope = page "" ""
  where
    page cursorAccount cursorEvent = do
      let parameters = merge scope (A.object ["cursor_account" A..= (cursorAccount :: Text), "cursor_event" A..= (cursorEvent :: Text)])
      values <- chJSON native parameters "SELECT toJSONString(tuple(account_id,event_id)) AS value FROM analytics.events_raw FINAL WHERE occurred_at<parseDateTime64BestEffort(JSONExtractString({admin_scope:String},'cutoff'),3,'UTC') AND tuple(account_id,event_id)>tuple(JSONExtractString({admin_scope:String},'cursor_account'),JSONExtractString({admin_scope:String},'cursor_event')) ORDER BY account_id,event_id LIMIT 1000"
      identities <- traverse decodeValue values :: IO [(Text, Text)]
      unless (null identities) $ do
        saveDispositions connection [A.object ["account_id" A..= account, "event_id" A..= eventId, "delete_event" A..= True, "scrub_identity" A..= False, "scrub_traits" A..= False] | (account, eventId) <- identities]
        let (nextAccount, nextEvent) = last identities
        page nextAccount nextEvent
