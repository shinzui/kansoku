-- | Administrative command entry point. Preview is the default for mutations.
module Kansoku.Admin (runAdmin) where

import Control.Monad (forM_)
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as K
import Data.ByteString.Lazy.Char8 qualified as LBS
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Time (addUTCTime)
import Data.UUID qualified as UUID
import Database.PostgreSQL.LibPQ qualified as PQ
import Kansoku.Admin.Jobs (resumeJob, runJob, writePrivate)
import Kansoku.Admin.Keys (runIssueKey)
import Kansoku.Admin.Store
import Kansoku.Config (Config, loadConfig)
import Kansoku.Exception (trySynchronous)
import Kansoku.Postgres.Direct
import Kansoku.Prelude
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import Text.Read (readMaybe)

runAdmin :: [String] -> IO ()
runAdmin ("issue-key" : args) = runIssueKey args
runAdmin [] = putStrLn help
runAdmin ["--help"] = putStrLn help
runAdmin (command : args) = do
  options <- either invalid pure (parseOptions command args)
  config <- loadConfig >>= either (const (invalid "invalid service configuration")) pure
  parameters <- commandParameters config command options
  outcome <- trySynchronous $ withPostgres (config ^. #pgConnectionString) $ \connection ->
    case command of
      "erase-user" -> runJob config connection "erase-user" parameters (flag "confirm" options) (option "out" options)
      "apply-retention" -> runJob config connection "retention" parameters (flag "confirm" options) (option "out" options)
      "resume-job" -> resumeJob config connection parameters (flag "confirm" options) (option "out" options)
      _ -> ordinary config connection command options parameters
  case outcome of
    Left _ -> do
      hPutStrLn stderr "administration failed; the replay ledger and any persisted maintenance fence remain authoritative. Inspect job-status/list-jobs and resume unfinished jobs after resolving the failure."
      exitFailure
    Right answer -> LBS.putStrLn (A.encode answer)
  where
    invalid message = hPutStrLn stderr message >> exitFailure

type AdminOptions = Map.Map Text Text

flag :: Text -> AdminOptions -> Bool
flag name = Map.member name

option :: Text -> AdminOptions -> Maybe FilePath
option name = fmap Text.unpack . Map.lookup name

parseOptions :: String -> [String] -> Either String AdminOptions
parseOptions command = go Map.empty
  where
    allowed = case command of
      "list-keys" -> ["account", "limit"]
      "revoke-key" -> ["id", "account", "confirm"]
      "erase-user" -> ["account", "user", "delete-events", "confirm", "out"]
      "apply-retention" -> ["confirm", "out"]
      "resume-job" -> ["id", "confirm", "out"]
      "job-status" -> ["id"]
      "list-jobs" -> ["limit"]
      "replay-archive" -> ["limit", "before", "after", "confirm", "out"]
      "purge-archive" -> ["limit", "before", "confirm"]
      "list-rejections" -> ["limit", "account", "event", "since", "include-payload"]
      "purge-rejections" -> ["limit", "account", "before", "confirm"]
      _ -> []
    switches = ["confirm", "delete-events", "include-payload"]
    go found []
      | null allowed = Left "unknown administrative command; run kansoku-admin --help"
      | otherwise = Right found
    go found (raw : rest) = do
      name <- maybe (Left "expected an administrative option") Right (Text.stripPrefix "--" (Text.pack raw))
      unless (name `elem` allowed && not (Map.member name found)) (Left "unknown or repeated administrative option")
      if name `elem` switches
        then go (Map.insert name "true" found) rest
        else case rest of
          value : remaining | not ("--" `Text.isPrefixOf` Text.pack value) -> go (Map.insert name (Text.pack value) found) remaining
          _ -> Left "missing administrative option value"

commandParameters :: Config -> String -> AdminOptions -> IO A.Value
commandParameters config command options = do
  limit <- case Map.lookup "limit" options of
    Nothing -> pure (100 :: Int)
    Just raw -> maybe (bad "--limit must be in 1..10000") pure (readMaybe (Text.unpack raw) >>= \n -> if n >= 1 && n <= 10000 then Just n else Nothing)
  forM_ ["before", "after", "since"] $ \name -> forM_ (Map.lookup name options) $ \raw ->
    case A.fromJSON (A.String raw) :: A.Result UTCTime of
      A.Error _ -> bad "timestamps must be ISO-8601 UTC instants"
      A.Success _ -> pure ()
  when (command `elem` ["revoke-key", "resume-job", "job-status"]) $
    unless (isJust (Map.lookup "id" options >>= UUID.fromText)) (bad "a valid --id UUID is required")
  when (command == "erase-user") $ forM_ ["account", "user"] $ \name ->
    when (maybe True Text.null (Map.lookup name options)) (bad "erase-user requires nonempty --account and --user")
  when (command == "purge-archive" && not (Map.member "before" options)) (bad "purge-archive requires --before")
  days <-
    if command == "apply-retention"
      then do
        configured <- lookupEnv "KANSOKU_EVENTS_RETENTION_DAYS"
        maybe (pure 0) (\raw -> maybe (bad "KANSOKU_EVENTS_RETENTION_DAYS must be nonnegative") pure (readMaybe raw >>= \n -> if n >= 0 && n <= 36500 then Just n else Nothing)) configured
      else pure (0 :: Int)
  now <- getCurrentTime
  let retentionCutoff = max (read "1970-01-01 00:00:00 UTC") (addUTCTime (negate (fromIntegral days * 86400)) now)
      rejectionCutoff = addUTCTime (negate (fromIntegral (config ^. #quarantineRetentionDays) * 86400)) now
  pure
    ( A.object
        ( [K.fromText name A..= value | (name, value) <- Map.toList (Map.delete "limit" options)]
            <> [ "limit" A..= limit,
                 "delete" A..= flag "delete-events" options,
                 "days" A..= days,
                 "cutoff" A..= (if days == 0 then read "1970-01-01 00:00:00 UTC" else retentionCutoff :: UTCTime),
                 "fingerprint_cutoff" A..= addUTCTime (negate (180 * 86400)) now,
                 "rejection_cutoff" A..= rejectionCutoff
               ]
        )
    )
  where
    bad message = hPutStrLn stderr message >> exitFailure

ordinary :: Config -> PQ.Connection -> String -> AdminOptions -> A.Value -> IO A.Value
ordinary config connection command options parameters = case command of
  "list-keys" -> query connection "SELECT coalesce(jsonb_agg(to_jsonb(k)),'[]') FROM (SELECT id,kind,account_id,description,created_at,revoked_at FROM kansoku.api_keys WHERE ($1->>'account' IS NULL OR account_id=$1->>'account') ORDER BY created_at,id LIMIT ($1->>'limit')::integer) k" parameters
  "revoke-key" -> do
    result <- query connection "SELECT to_jsonb(k) FROM (SELECT id,kind,account_id,description,created_at,revoked_at FROM kansoku.api_keys WHERE id=($1->>'id')::uuid AND ($1->>'account' IS NULL OR account_id=$1->>'account')) k" parameters
    when (result == A.Null) (fail "unknown credential ID")
    if flag "confirm" options then query connection "WITH changed AS (UPDATE kansoku.api_keys SET revoked_at=coalesce(revoked_at,now()) WHERE id=($1->>'id')::uuid RETURNING id,kind,account_id,description,created_at,revoked_at) SELECT to_jsonb(changed) FROM changed" parameters else pure (A.object ["preview" A..= True, "key" A..= result])
  "list-jobs" -> query connection "SELECT coalesce(jsonb_agg(to_jsonb(j)),'[]') FROM (SELECT id,kind,stage,created_at,completed_at,scope->>'account' AS account FROM kansoku.maintenance_jobs ORDER BY revision DESC LIMIT ($1->>'limit')::integer) j" parameters
  "job-status" -> query connection "SELECT jsonb_build_object('id',id,'kind',kind,'stage',stage,'created_at',created_at,'completed_at',completed_at,'fenced',id=(SELECT active_job FROM kansoku.maintenance_fence)) FROM kansoku.maintenance_jobs WHERE id=($1->>'id')::uuid" parameters
  "list-rejections" -> query connection ("SELECT coalesce(jsonb_agg(to_jsonb(r)),'[]') FROM (SELECT id,account_id,received_at,event_name,schema_version,reason_codes,transport,payload_truncated,original_payload_bytes" <> (if flag "include-payload" options then ",payload" else "") <> " FROM kansoku.ingest_rejections WHERE ($1->>'account' IS NULL OR account_id=$1->>'account') AND ($1->>'event' IS NULL OR event_name=$1->>'event') AND ($1->>'since' IS NULL OR received_at>=($1->>'since')::timestamptz) ORDER BY received_at,id LIMIT ($1->>'limit')::integer) r") parameters
  "purge-rejections" -> do
    let predicate = "($1->>'account' IS NULL OR account_id=$1->>'account') AND received_at<coalesce(($1->>'before')::timestamptz,($1->>'rejection_cutoff')::timestamptz)"
    if flag "confirm" options
      then do
        admitMaintenanceTraffic connection
        limitedPurge connection parameters ("WITH selected AS (SELECT id FROM kansoku.ingest_rejections WHERE " <> predicate <> " ORDER BY received_at,id LIMIT ($1->>'limit')::integer), removed AS (DELETE FROM kansoku.ingest_rejections q USING selected s WHERE q.id=s.id RETURNING q.id) SELECT jsonb_build_object('purged',count(*)) FROM removed")
      else query connection ("SELECT jsonb_build_object('preview',true,'matching',count(*),'maximum',($1->>'limit')::integer) FROM kansoku.ingest_rejections WHERE " <> predicate) parameters
  _ -> archive config connection command options parameters

archive :: Config -> PQ.Connection -> String -> AdminOptions -> A.Value -> IO A.Value
archive config connection command options parameters = do
  tables <- queueTables connection (config ^. #eventsQueueName)
  let archives = filter (Text.isPrefixOf "pgmq.\"a_") tables
  table <- case archives of [name] -> pure name; _ -> fail "configured archive is absent"
  let range = "($1->>'before' IS NULL OR archived_at<($1->>'before')::timestamptz) AND ($1->>'after' IS NULL OR archived_at>=($1->>'after')::timestamptz)"
      replayable = range <> " AND NOT EXISTS (SELECT 1 FROM kansoku.archive_replays r WHERE r.queue_name=$1->>'ledger_queue' AND r.archive_id=q.msg_id) AND NOT EXISTS (SELECT 1 FROM kansoku.event_dispositions d WHERE d.account_id=kansoku.event_body(q.message)->>'accountId' AND d.event_id=kansoku.event_body(q.message)->>'eventId' AND d.delete_event) AND (p.cutoff IS NULL OR kansoku.event_time(q.message)>=p.cutoff)"
      params = merge parameters (A.object ["queue" A..= (config ^. #eventsQueueName), "ledger_queue" A..= table])
  if not (flag "confirm" options)
    then query connection ("SELECT jsonb_build_object('preview',true,'matching',count(*),'maximum',($1->>'limit')::integer) FROM " <> table <> " q CROSS JOIN kansoku.retention_policy p WHERE " <> (if command == "replay-archive" then replayable else range)) params
    else do
      -- Same shared session lock as HTTP/writer prevents maintenance crossing this transaction.
      admitMaintenanceTraffic connection
      when (command == "replay-archive") (pgScript connection "BEGIN")
      result <-
        if command == "replay-archive"
          then
            query
              connection
              ("WITH selected AS MATERIALIZED (SELECT q.msg_id,q.message FROM " <> table <> " q CROSS JOIN kansoku.retention_policy p WHERE " <> replayable <> " ORDER BY q.msg_id LIMIT ($1->>'limit')::integer FOR UPDATE OF q SKIP LOCKED), sent AS MATERIALIZED (SELECT msg_id,pgmq.send($1->>'queue',message,0) AS new_id FROM selected), recorded AS (INSERT INTO kansoku.archive_replays(queue_name,archive_id,message_id) SELECT $1->>'ledger_queue',msg_id,new_id FROM sent RETURNING archive_id,message_id) SELECT jsonb_build_object('replayed',count(*),'messages',coalesce(jsonb_agg(to_jsonb(recorded)),'[]')) FROM recorded")
              params
          else limitedPurge connection params ("WITH selected AS (SELECT q.msg_id FROM " <> table <> " q WHERE " <> range <> " ORDER BY q.msg_id LIMIT ($1->>'limit')::integer FOR UPDATE SKIP LOCKED), removed AS (DELETE FROM " <> table <> " q USING selected s WHERE q.msg_id=s.msg_id RETURNING q.msg_id) SELECT jsonb_build_object('purged',count(*)) FROM removed")
      when (command == "replay-archive") (pgScript connection "COMMIT")
      forM_ (option "out" options) (\path -> void (writePrivate (Just path) result))
      pure result

limitedPurge :: PQ.Connection -> A.Value -> Text -> IO A.Value
limitedPurge connection parameters sql = do
  requested <- decodeValue (field "limit" parameters) :: IO Int
  loop requested 0
  where
    loop remaining total
      | remaining <= 0 = pure (A.object ["purged" A..= total])
      | otherwise = do
          result <- query connection sql (merge parameters (A.object ["limit" A..= min 1000 remaining]))
          removed <- decodeValue (field "purged" result) :: IO Int
          unless (removed >= 0 && removed <= min 1000 remaining) (fail "invalid bounded purge result")
          if removed == 0 then pure (A.object ["purged" A..= total]) else loop (remaining - removed) (total + removed)

merge :: A.Value -> A.Value -> A.Value
merge (A.Object left) (A.Object right) = A.Object (right <> left)
merge left _ = left

help :: String
help =
  unlines
    [ "kansoku-admin issue-key --kind write|service --account ID [--description TEXT]",
      "list-keys [--account ID] [--limit 1..10000] | revoke-key --id UUID [--account ID] [--confirm]",
      "erase-user --account ID --user ID [--delete-events] [--out PATH] [--confirm]",
      "apply-retention [--out PATH] [--confirm] (KANSOKU_EVENTS_RETENTION_DAYS; 0/unset unlimited)",
      "resume-job --id UUID --confirm [--out PATH] | job-status --id UUID | list-jobs [--limit N]",
      "replay-archive [--limit N] [--before UTC] [--after UTC] [--out PATH] [--confirm]",
      "purge-archive --before UTC [--limit N] [--confirm]",
      "list-rejections [--account ID] [--event NAME] [--since UTC] [--limit N] [--include-payload]",
      "purge-rejections [--account ID] [--before UTC] [--limit N] [--confirm]",
      "Destructive/data-maintenance commands preview without --confirm. Output files are created exclusively with mode 0600."
    ]
