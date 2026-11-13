-- | Resumable, fenced cross-store jobs. PostgreSQL is the authoritative journal.
module Kansoku.Admin.Jobs (runJob, runPreparedJob, resumeJob, writePrivate) where

import ClickHaskell (Connection)
import Control.Exception (bracket, bracketOnError)
import Control.Monad (forM, forM_)
import Data.Aeson qualified as A
import Data.ByteString.Lazy qualified as LBS
import Data.List (elemIndex, nub, sort)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Data.UUID qualified as UUID
import Data.UUID.V4 (nextRandom)
import Database.PostgreSQL.LibPQ qualified as PQ
import Kansoku.Admin.ClickHouse
import Kansoku.Admin.DrainEvidence qualified as Drain
import Kansoku.Admin.Store
import Kansoku.Auth.Token (Token (..), hashToken)
import Kansoku.ClickHouse (clickHouseConfigFromConfig, openClickHouse)
import Kansoku.ClickHouse.Consistency
import Kansoku.ClickHouse.Native (failConsistency)
import Kansoku.ClickHouse.Topology (Topology (..), topologyIdentity)
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

withNative :: Config -> (ReplicaConnections -> IO a) -> IO a
withNative config action = withReplicaConnections (config ^. #clickHouseTopology) (openClickHouse (clickHouseConfigFromConfig config)) $ \replicas -> do
  forM_ (replicaConnections replicas) $ \(_, connection) -> do
    initializeRole (config ^. #clickHouseTopology) Maintenance connection
    chCommand connection A.Null ("SET max_execution_time=" <> Text.pack (show (case config ^. #clickHouseTopology of Direct -> max 60 (config ^. #metricsMaxExecutionSec); _ -> 55)))
    chCommand connection A.Null ("SET max_memory_usage=" <> Text.pack (show (config ^. #metricsMaxMemoryBytes)))
  action replicas

runJob :: Config -> PQ.Connection -> Text -> A.Value -> Bool -> Maybe FilePath -> IO A.Value
runJob config connection kind requestedScope confirm output = runPreparedJob config connection kind requestedScope confirm False output

-- Preparation retains the same immutable scope and fence as confirmation but
-- returns before opening ClickHouse or discovering any application data.
runPreparedJob :: Config -> PQ.Connection -> Text -> A.Value -> Bool -> Bool -> Maybe FilePath -> IO A.Value
runPreparedJob config connection kind requestedScope confirm prepare _output = do
  scope <- if kind == "retention" then query connection "SELECT $1||jsonb_build_object('fingerprint_cutoff',greatest(($1->>'fingerprint_cutoff')::timestamptz,fingerprint_cutoff)) FROM kansoku.retention_policy WHERE singleton" requestedScope else pure requestedScope
  tables <- queueTables connection (config ^. #eventsQueueName)
  if not confirm && not prepare
    then do
      admitMaintenanceTraffic connection
      withNative config $ \replicas -> previewJob (coordinator replicas) connection tables kind scope
    else do
      administrativeLock connection
      requireNoMigrationSession connection
      pgScript connection "BEGIN"
      active <- query connection "SELECT to_jsonb(active_job) FROM kansoku.maintenance_fence WHERE singleton AND $1 IS NOT NULL FOR UPDATE" A.Null
      unless (active == A.Null) (fail "an unfinished maintenance job must be resumed")
      job <- query connection "WITH created AS (INSERT INTO kansoku.maintenance_jobs(kind,scope,target_identity) VALUES($1->>'kind',$1->'scope',$1->'identity') RETURNING *) SELECT to_jsonb(created) FROM created" (A.object ["kind" A..= kind, "scope" A..= scope, "identity" A..= topologyIdentity (config ^. #clickHouseTopology)])
      void $ query connection "UPDATE kansoku.maintenance_fence SET active_job=($1->>'id')::uuid WHERE singleton" job
      pgScript connection "COMMIT"
      if prepare
        then pure (receipt job)
        else do
          identifier <- decodeValue (field "id" job) :: IO Text
          failConsistency ("maintenance job " <> Text.unpack identifier <> " prepared with fence retained; inspect job-status, establish external drain, then resume-job --confirm --drain-evidence FILE")

resumeJob :: Config -> PQ.Connection -> A.Value -> Bool -> Maybe FilePath -> IO A.Value
resumeJob config connection parameters confirm output = do
  job <- query connection "SELECT to_jsonb(j) FROM kansoku.maintenance_jobs j WHERE id=($1->>'id')::uuid" parameters
  when (job == A.Null) (fail "unknown maintenance job")
  unless (field "target_identity" job == topologyIdentity (config ^. #clickHouseTopology)) (failConsistency "maintenance job topology, cluster or expected replica UUID set mismatch; fence retained")
  if not confirm || field "stage" job == A.String "complete"
    then pure (receipt job)
    else do
      administrativeLock connection
      requireNoMigrationSession connection
      active <- query connection "SELECT to_jsonb(active_job) FROM kansoku.maintenance_fence WHERE singleton AND $1 IS NOT NULL" A.Null
      unless (active == field "id" job) (fail "maintenance fence ownership differs from resumed job")
      tables <- queueTables connection (config ^. #eventsQueueName)
      executeJobWithEvidence config connection tables job output (case field "drain-evidence" parameters of A.String path -> Just (Text.unpack path); _ -> Nothing)

administrativeLock :: PQ.Connection -> IO ()
administrativeLock connection = do
  admitted <- query connection "SELECT to_jsonb(pg_try_advisory_lock(726401,2)) WHERE $1 IS NOT NULL" A.Null
  unless (admitted == A.Bool True) (fail "another administrator is active")

executeJobWithEvidence :: Config -> PQ.Connection -> [Text] -> A.Value -> Maybe FilePath -> Maybe FilePath -> IO A.Value
executeJobWithEvidence config connection tables originalJob output evidencePath = do
  initial <- query connection "UPDATE kansoku.maintenance_jobs SET native_attempt=native_attempt+1,last_attempt_at=clock_timestamp() WHERE id=($1->>'id')::uuid RETURNING to_jsonb(maintenance_jobs)" originalJob
  path <- maybe (failConsistency "owner-bound --drain-evidence FILE required before discovery or mutation; inspect job-status for the next attempt; fence retained") pure evidencePath
  accepted <- jobDrainEvidence config originalJob initial path
  void $ query connection "UPDATE kansoku.maintenance_jobs SET drain_evidence=$1->'evidence' WHERE id=($1->>'id')::uuid" (A.object ["id" A..= field "id" initial, "evidence" A..= Drain.acceptedDocument accepted])
  void $ query connection "INSERT INTO kansoku.maintenance_drain_attempts(job_id,attempt,evidence,evidence_sha256) VALUES(($1->>'id')::uuid,($1->>'attempt')::bigint,$1->'evidence',$1->>'digest')" (A.object ["id" A..= field "id" initial, "attempt" A..= field "native_attempt" initial, "evidence" A..= Drain.acceptedDocument accepted, "digest" A..= Drain.acceptedDigest accepted])
  identifier <- decodeValue (field "id" initial) :: IO Text
  hPutStrLn stderr ("maintenance job " <> Text.unpack identifier <> "; persisted fence active")
  -- New traffic already observes the persisted fence. Wait for all admitted
  -- requests/inserts/replays to finish before touching either store.
  pgScript connection "SELECT to_jsonb(pg_advisory_lock(726401,1))"
  withNative config $ \replicas -> do
    expectedServers <- lookupEnv "KANSOKU_CH_DRAIN_SERVERS" >>= maybe (fail "Missing trusted drain server inventory") (either (const (fail "Invalid trusted drain server inventory")) pure . A.eitherDecodeStrict' . Encoding.encodeUtf8 . Text.pack)
    observed <- forM (replicaConnections replicas) $ \(_, nativeConnection) -> do
      rows <- chJSON nativeConnection A.Null "SELECT toJSONString(toString(serverUUID())) AS value"
      case rows of
        [A.String sid] -> pure sid
        _ -> fail "Invalid native drain server identity"
    unless (sort observed == sort (expectedServers :: [Text])) (fail "Native drain server inventory differs from trusted evidence binding")
    let requireFresh = getCurrentTime >>= \now -> either (fail . Text.unpack) pure (Drain.checkDrainCurrent now accepted)
    requireFresh
    let native = coordinator replicas
    -- A rejected native query can leave unread protocol frames. Never run
    -- optional diagnostics on connections used for subsequent maintenance.
    observations <- withNative config observeReplicaWrites
    void $ query connection "UPDATE kansoku.maintenance_drain_attempts SET observations=$1->'observations' WHERE job_id=($1->>'id')::uuid AND attempt=($1->>'attempt')::bigint" (A.object ["id" A..= field "id" initial, "attempt" A..= field "native_attempt" initial, "observations" A..= [A.object ["server" A..= sid, "result" A..= show observation] | (sid, observation) <- observations]])
    when (any ((== VisibleWrites) . snd) observations) (fail "Visible native writes remain active; external drain attestation is insufficient; fence retained")
    requireFresh
    synchronizeSchema replicas
    synchronizeTables replicas maintenanceTables
    verifyReplicaMutations replicas
    let kind = field "kind" initial
        original = field "scope" initial
    discovered <-
      if field "stage" initial == A.String "created"
        then do
          requireFresh
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
      requireFresh
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
      requireFresh
      if kind == A.String "erase-user" then scrubSources connection tables scope else expireSources connection tables scope >> scrubFingerprintSources connection tables scope
      checkpoint "sources-scrubbed"
    when (before "raw-mutated") $ do
      requireFresh
      if kind == A.String "erase-user" then eraseNative native scope else retainNative native (merge scope (A.object ["revision" A..= field "revision" initial]))
      checkpoint "raw-mutated"
    when (before "rebuilt") $ requireFresh >> rebuildReplicas replicas >> checkpoint "rebuilt"
    -- Repeat final barriers and predicates even after a saved verified stage.
    synchronizeSchema replicas
    verifyReplicaMutations replicas
    verifyReplicaPopulations replicas
    forM_ (replicaConnections replicas) $ \(sid, observedNative) -> withinBudget ("final predicates replica " <> sid) $ do
      if kind == A.String "erase-user"
        then do
          verifySources connection tables scope
          remaining <- chJSON observedNative scope ("SELECT toJSONString(count()) AS value FROM analytics.identity_signals FINAL WHERE " <> explicitSubject)
          traits <- chJSON observedNative scope ("SELECT toJSONString(count()) AS value FROM analytics.user_traits WHERE " <> explicitSubject)
          cohortMembers <- chJSON observedNative scope ("SELECT toJSONString(count()) AS value FROM analytics.cohort_members WHERE " <> explicitSubject)
          unless (remaining == [A.Number 0] && traits == [A.Number 0] && cohortMembers == [A.Number 0]) (fail "erased evidence or current traits survived rebuild")
          rawEvidence <- chJSON observedNative scope ("SELECT toJSONString(count()) AS value FROM analytics.events_raw WHERE (" <> affected <> ") AND (identifiers!='{}' OR anonymous_id!='' OR session_id!='' OR (event_name IN ('identify','identify_once','alias') AND properties!='{}'))")
          unless (rawEvidence == [A.Number 0]) (fail "raw identity evidence survived erasure")
          when (field "delete" scope == A.Bool True) $ do
            explicit <- chJSON observedNative scope ("SELECT toJSONString(count()) AS value FROM analytics.events_canonical WHERE " <> explicitSubject)
            unless (explicit == [A.Number 0]) (fail "explicit-user facts survived deletion")
        else do
          old <- chJSON observedNative scope "SELECT toJSONString(count()) AS value FROM analytics.events_canonical WHERE occurred_at<parseDateTime64BestEffort(JSONExtractString({admin_scope:String},'cutoff'),3,'UTC')"
          unless (old == [A.Number 0]) (fail "expired facts survived retention")
          fingerprints <- chJSON observedNative scope "SELECT toJSONString(count()) AS value FROM analytics.events_raw WHERE occurred_at<parseDateTime64BestEffort(JSONExtractString({admin_scope:String},'fingerprint_cutoff'),3,'UTC') AND JSONHas(identifiers,'fingerprint')"
          unless (fingerprints == [A.Number 0]) (fail "expired raw fingerprints survived retention")
    checkIdentities replicas
    requireFresh
    checkpoint "verified"
    checkIdentities replicas
    -- No failed stage clears the fence. Final journal reduction and release are atomic.
    let reduced = A.object ["account" A..= field "account" original, "delete" A..= field "delete" original, "days" A..= field "days" original, "cutoff" A..= field "cutoff" original, "fingerprint_cutoff" A..= field "fingerprint_cutoff" original, "user_digest" A..= hashToken (Token (case field "user" original of A.String value -> value; _ -> ""))]
    requireFresh
    pgScript connection "BEGIN"
    finished <- query connection "UPDATE kansoku.maintenance_jobs SET stage='complete',completed_at=now(),discovery='{}',scope=$1->'scope' WHERE id=($1->>'id')::uuid RETURNING to_jsonb(maintenance_jobs)" (merge initial (A.object ["scope" A..= reduced]))
    void $ query connection "UPDATE kansoku.maintenance_fence SET active_job=NULL WHERE singleton AND active_job=($1->>'id')::uuid" initial
    pgScript connection "COMMIT"
    pure (merge (receipt finished) (A.object ["snapshot" A..= snapshot]))

receipt :: A.Value -> A.Value
receipt job = A.object ["job_id" A..= field "id" job, "next_attempt" A..= (case field "native_attempt" job of A.Number n -> A.Number (n + 1); _ -> A.Null), "kind" A..= field "kind" job, "stage" A..= field "stage" job, "completed_at" A..= field "completed_at" job]

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
  maintenanceCommand native scope ("ALTER TABLE analytics.cohort_members DELETE WHERE " <> explicitSubject <> " SETTINGS mutations_sync=2")
  eraseUserTraits native account user (if deleting then DeleteTraitEvents else ScrubTraitEvents)
  when deleting $ maintenanceCommand native scope ("ALTER TABLE analytics.events_raw DELETE WHERE " <> explicitSubject <> " SETTINGS mutations_sync=2")
  maintenanceCommand native scope ("ALTER TABLE analytics.events_raw UPDATE identifiers='{}',anonymous_id='',session_id='',properties=if(event_name IN ('identify','identify_once','alias'),'{}',properties),governed_traits_valid=if(event_name IN ('identify','identify_once'),false,governed_traits_valid) WHERE " <> affected <> " SETTINGS mutations_sync=2")
  forM_ ["properties_json", "identity_context_key", "context_json"] $ \column -> maintenanceCommand native A.Null ("ALTER TABLE analytics.events_raw MATERIALIZE COLUMN " <> column <> " SETTINGS mutations_sync=2")

retainNative :: Connection -> A.Value -> IO ()
retainNative native scope = do
  maintenanceCommand native scope "INSERT INTO analytics.retention_policy SELECT 1,toUInt64(JSONExtractInt({admin_scope:String},'revision')),parseDateTime64BestEffort(JSONExtractString({admin_scope:String},'cutoff'),3,'UTC')"
  maintenanceCommand native scope "ALTER TABLE analytics.events_raw DELETE WHERE occurred_at<parseDateTime64BestEffort(JSONExtractString({admin_scope:String},'cutoff'),3,'UTC') SETTINGS mutations_sync=2"
  maintenanceCommand native scope "ALTER TABLE analytics.events_raw UPDATE identifiers=toJSONString(mapFromArrays(arrayMap(kv -> kv.1,arrayFilter(kv -> kv.1!='fingerprint',JSONExtractKeysAndValues(identifiers,'String'))),arrayMap(kv -> kv.2,arrayFilter(kv -> kv.1!='fingerprint',JSONExtractKeysAndValues(identifiers,'String'))))) WHERE occurred_at<parseDateTime64BestEffort(JSONExtractString({admin_scope:String},'fingerprint_cutoff'),3,'UTC') AND JSONHas(identifiers,'fingerprint') SETTINGS mutations_sync=2"
  maintenanceCommand native A.Null "ALTER TABLE analytics.events_raw MATERIALIZE COLUMN identity_context_key SETTINGS mutations_sync=2"
  maintenanceCommand native scope "ALTER TABLE analytics.events_raw MODIFY TTL toDateTime(occurred_at) DELETE WHERE occurred_at<parseDateTime64BestEffort(JSONExtractString({admin_scope:String},'cutoff'),3,'UTC')"

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

requireNoMigrationSession :: PQ.Connection -> IO ()
requireNoMigrationSession connection = do
  ready <- query connection "SELECT to_jsonb(active_migration_session IS NULL) FROM kansoku.maintenance_fence WHERE singleton AND $1 IS NOT NULL" A.Null
  unless (ready == A.Bool True) (fail "unfinished ClickHouse migration session owns the maintenance fence")

maintenanceCommand :: Connection -> A.Value -> Text -> IO ()
maintenanceCommand native scope sql = withinBudget "native maintenance statement" (chCommand native scope sql)

-- Resolve trusted job binding independently of the operator's envelope. The
-- observed native UUID is checked again after opening each physical connection.
jobDrainEvidence :: Config -> A.Value -> A.Value -> FilePath -> IO Drain.AcceptedDrain
jobDrainEvidence config original current path = do
  target <- required "KANSOKU_CH_MIGRATION_TARGET"
  ledger <- required "KANSOKU_CH_MIGRATION_LEDGER_ID"
  servers <- jsonEnvironment "KANSOKU_CH_DRAIN_SERVERS"
  submitters <- jsonEnvironment "KANSOKU_CH_DRAIN_SUBMITTERS"
  available <- jsonEnvironment "KANSOKU_CH_DRAIN_AVAILABLE_PRINCIPALS"
  ident <- decodeValue (field "id" current)
  attempt <- decodeValue (field "native_attempt" current)
  created <- decodeValue (field "last_attempt_at" original)
  now <- getCurrentTime
  let expected = Drain.DrainRequirement target servers (Just ledger) ["analytics", "kansoku_migration_ledger"] (Text.pack (config ^. #clickHouseUser) : submitters) (Text.pack (config ^. #clickHouseUser) : available) (Drain.DataJob ident attempt) created
  Drain.readDrainEvidence now expected path >>= either (fail . Text.unpack) pure
  where
    required name = lookupEnv name >>= maybe (fail ("Missing trusted drain configuration: " <> name)) (pure . Text.pack)
    jsonEnvironment name =
      required name >>= \raw -> case A.eitherDecodeStrict' (Encoding.encodeUtf8 raw) of
        Left _ -> fail ("Invalid trusted drain inventory: " <> name)
        Right values -> pure values
