-- | PostgreSQL queue/ledger maintenance. Dynamic identifiers are server-resolved.
module Kansoku.Admin.Store
  ( query,
    field,
    decodeValue,
    queueTables,
    discoverQueued,
    queuedDispositions,
    saveDispositions,
    scrubSources,
    verifySources,
    expireSources,
    scrubFingerprintSources,
    quotePG,
    admitMaintenanceTraffic,
  )
where

import Control.Monad (forM, forM_)
import Data.Aeson qualified as A
import Data.Aeson.Key qualified as K
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types qualified as A
import Data.Maybe (catMaybes)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Database.PostgreSQL.LibPQ qualified as PQ
import Kansoku.Postgres.Direct (pg)
import Kansoku.Prelude

query :: PQ.Connection -> Text -> A.Value -> IO A.Value
query connection sql = pg connection (Text.encodeUtf8 sql)

field :: Text -> A.Value -> A.Value
field name (A.Object values) = fromMaybe A.Null (KM.lookup (K.fromText name) values)
field _ _ = A.Null

decodeValue :: (A.FromJSON a) => A.Value -> IO a
decodeValue = either (const (fail "invalid administrative database result")) pure . A.parseEither A.parseJSON

quotePG :: Text -> Text
quotePG value = "\"" <> Text.replace "\"" "\"\"" value <> "\""

admitMaintenanceTraffic :: PQ.Connection -> IO ()
admitMaintenanceTraffic connection = do
  locked <- query connection "SELECT to_jsonb(pg_try_advisory_lock_shared(726401,1)) WHERE $1 IS NOT NULL" A.Null
  unless (locked == A.Bool True) (fail "maintenance fence active")
  ready <- query connection "SELECT to_jsonb(active_job IS NULL) FROM kansoku.maintenance_fence WHERE $1 IS NOT NULL" A.Null
  unless (ready == A.Bool True) (fail "maintenance fence active")

queueTables :: PQ.Connection -> Text -> IO [Text]
queueTables connection name = do
  candidates <- forM ["q", "a"] $ \prefix -> do
    physical <- query connection "SELECT to_jsonb(pgmq.format_table_name($1->>'queue',$1->>'prefix'))" (A.object ["queue" A..= name, "prefix" A..= (prefix :: Text)]) >>= decodeValue
    exists <- query connection "SELECT to_jsonb(to_regclass('pgmq.'||quote_ident($1->>'table')) IS NOT NULL)" (A.object ["table" A..= (physical :: Text)])
    pure (if exists == A.Bool True then Just ("pgmq." <> quotePG physical) else Nothing)
  pure (catMaybes candidates)

sources :: [Text] -> Text
sources tables =
  Text.intercalate
    " UNION ALL "
    ( ["SELECT kansoku.event_body(message) AS e FROM " <> table | table <- tables]
        <> ["SELECT '{}'::jsonb AS e WHERE false"]
    )

discoverQueued :: PQ.Connection -> [Text] -> A.Value -> IO A.Value
discoverQueued connection tables =
  query connection $
    "WITH explicit AS (SELECT e FROM ("
      <> sources tables
      <> ") sources WHERE e->>'accountId'=$1->>'account' AND e->>'userId'=$1->>'user'), "
      <> "signals AS (SELECT kv.key AS kind,kv.value FROM explicit CROSS JOIN LATERAL jsonb_each_text(CASE WHEN jsonb_typeof(e->'identifiers')='object' THEN e->'identifiers' ELSE '{}' END) kv WHERE kv.value<>'' "
      <> "UNION SELECT 'cookie',e->>'anonymousId' FROM explicit WHERE e->>'eventName' IN ('identify','identify_once','alias') AND coalesce(e->>'anonymousId','')<>'') "
      <> "SELECT jsonb_build_object('signals',coalesce((SELECT jsonb_agg(DISTINCT jsonb_build_array(kind,value)) FROM signals),'[]'),"
      <> "'sessions',coalesce((SELECT jsonb_agg(DISTINCT jsonb_build_array(coalesce(e->>'sourceService',''),e->>'sessionId')) FROM explicit WHERE coalesce(e->>'sessionId','')<>''),'[]'))"

queuedDispositions :: PQ.Connection -> [Text] -> A.Value -> IO [A.Value]
queuedDispositions connection tables scope =
  query
    connection
    ( "SELECT coalesce(jsonb_agg(DISTINCT jsonb_build_object('account_id',e->>'accountId','event_id',e->>'eventId',"
        <> "'delete_event',coalesce(($1->>'delete')::boolean,false) AND coalesce(e->>'userId'=$1->>'user',false),'scrub_identity',true,'scrub_traits',coalesce(e->>'userId'=$1->>'user',false))),'[]') "
        <> "FROM ("
        <> sources tables
        <> ") sources WHERE kansoku.matches_erasure(e,$1) AND jsonb_typeof(e->'eventId')='string' AND e->>'eventId'<>''"
    )
    scope
    >>= decodeValue

saveDispositions :: PQ.Connection -> [A.Value] -> IO ()
saveDispositions connection = chunks $ \rows ->
  void $
    query
      connection
      "WITH saved AS (INSERT INTO kansoku.event_dispositions SELECT account_id,event_id,bool_or(delete_event),bool_or(scrub_identity),bool_or(scrub_traits) FROM jsonb_to_recordset($1) AS r(account_id text,event_id text,delete_event boolean,scrub_identity boolean,scrub_traits boolean) GROUP BY account_id,event_id ON CONFLICT(account_id,event_id) DO UPDATE SET delete_event=kansoku.event_dispositions.delete_event OR excluded.delete_event,scrub_identity=kansoku.event_dispositions.scrub_identity OR excluded.scrub_identity,scrub_traits=kansoku.event_dispositions.scrub_traits OR excluded.scrub_traits RETURNING account_id,event_id) UPDATE kansoku.accepted_events a SET erased_at=coalesce(erased_at,now()) FROM saved s WHERE a.account_id=s.account_id AND a.event_id=s.event_id"
      (A.toJSON rows)

chunks :: ([a] -> IO ()) -> [a] -> IO ()
chunks action rows = unless (null rows) $ do
  let (page, rest) = splitAt 1000 rows
  action page
  chunks action rest

-- Repeated bounded pages terminate on actual changed rows, never OFFSET.
repeatPages :: PQ.Connection -> Text -> A.Value -> IO ()
repeatPages connection sql parameters = do
  count <- query connection sql parameters
  unless (count == A.Number 0) (repeatPages connection sql parameters)

joinDisposition :: Text
joinDisposition = "d.account_id=kansoku.event_body(q.message)->>'accountId' AND d.event_id=kansoku.event_body(q.message)->>'eventId'"

scrubSources :: PQ.Connection -> [Text] -> A.Value -> IO ()
scrubSources connection tables scope = do
  forM_ tables $ \table -> do
    repeatPages connection ("WITH selected AS (SELECT q.msg_id FROM " <> table <> " q JOIN kansoku.event_dispositions d ON " <> joinDisposition <> " WHERE d.delete_event AND $1 IS NOT NULL ORDER BY q.msg_id LIMIT 1000), removed AS (DELETE FROM " <> table <> " q USING selected s WHERE q.msg_id=s.msg_id RETURNING q.msg_id) SELECT to_jsonb(count(*)) FROM removed") scope
    repeatPages connection ("WITH selected AS (SELECT q.msg_id,kansoku.apply_event_disposition(q.message,d.scrub_identity,d.scrub_traits) AS body FROM " <> table <> " q JOIN kansoku.event_dispositions d ON " <> joinDisposition <> " WHERE q.message IS DISTINCT FROM kansoku.apply_event_disposition(q.message,d.scrub_identity,d.scrub_traits) AND $1 IS NOT NULL ORDER BY q.msg_id LIMIT 1000), changed AS (UPDATE " <> table <> " q SET message=s.body FROM selected s WHERE q.msg_id=s.msg_id RETURNING q.msg_id) SELECT to_jsonb(count(*)) FROM changed") scope
  repeatPages connection "WITH selected AS (SELECT id FROM kansoku.ingest_rejections WHERE account_id=$1->>'account' AND kansoku.matches_erasure(jsonb_build_object('queueVersion',2,'event',jsonb_set(payload,'{accountId}',to_jsonb(account_id))),$1) ORDER BY received_at,id LIMIT 1000), removed AS (DELETE FROM kansoku.ingest_rejections q USING selected s WHERE q.id=s.id RETURNING q.id) SELECT to_jsonb(count(*)) FROM removed" scope

verifySources :: PQ.Connection -> [Text] -> A.Value -> IO ()
verifySources connection tables scope = do
  forM_ tables $ \table -> do
    invalid <- query connection ("SELECT to_jsonb(count(*)) FROM " <> table <> " q JOIN kansoku.event_dispositions d ON " <> joinDisposition <> " WHERE (d.delete_event OR q.message IS DISTINCT FROM kansoku.apply_event_disposition(q.message,d.scrub_identity,d.scrub_traits)) AND $1 IS NOT NULL") scope
    unless (invalid == A.Number 0) (fail "replayable source verification failed; fence retained")
  remaining <- query connection "SELECT to_jsonb(count(*)) FROM kansoku.ingest_rejections WHERE account_id=$1->>'account' AND kansoku.matches_erasure(jsonb_build_object('queueVersion',2,'event',jsonb_set(payload,'{accountId}',to_jsonb(account_id))),$1)" scope
  unless (remaining == A.Number 0) (fail "quarantine erasure verification failed; fence retained")

expireSources :: PQ.Connection -> [Text] -> A.Value -> IO ()
expireSources connection tables scope = do
  forM_ tables $ \table ->
    repeatPages
      connection
      ("WITH selected AS MATERIALIZED (SELECT msg_id,kansoku.event_body(message) AS e FROM " <> table <> " WHERE coalesce(kansoku.event_time(message),enqueued_at)<($1->>'cutoff')::timestamptz ORDER BY msg_id LIMIT 1000 FOR UPDATE), identities AS (INSERT INTO kansoku.event_dispositions(account_id,event_id,delete_event) SELECT e->>'accountId',e->>'eventId',true FROM selected WHERE coalesce(e->>'accountId','')<>'' AND coalesce(e->>'eventId','')<>'' GROUP BY e->>'accountId',e->>'eventId' ON CONFLICT(account_id,event_id) DO UPDATE SET delete_event=true RETURNING account_id,event_id), marked AS (UPDATE kansoku.accepted_events a SET erased_at=coalesce(erased_at,now()) FROM identities i WHERE a.account_id=i.account_id AND a.event_id=i.event_id RETURNING a.event_id), removed AS (DELETE FROM " <> table <> " q USING selected s WHERE q.msg_id=s.msg_id AND (SELECT count(*) FROM identities)>=0 AND (SELECT count(*) FROM marked)>=0 RETURNING q.msg_id) SELECT to_jsonb(count(*)) FROM removed")
      scope
  repeatPages connection "WITH selected AS (SELECT id FROM kansoku.ingest_rejections WHERE coalesce(kansoku.event_time(jsonb_build_object('queueVersion',2,'event',payload)),received_at)<($1->>'cutoff')::timestamptz ORDER BY received_at,id LIMIT 1000), removed AS (DELETE FROM kansoku.ingest_rejections q USING selected s WHERE q.id=s.id RETURNING q.id) SELECT to_jsonb(count(*)) FROM removed" scope

scrubFingerprintSources :: PQ.Connection -> [Text] -> A.Value -> IO ()
scrubFingerprintSources connection tables scope = do
  forM_ tables $ \table ->
    repeatPages
      connection
      ("WITH selected AS (SELECT msg_id,kansoku.apply_event_disposition(message,false,false,true) AS body FROM " <> table <> " WHERE coalesce(kansoku.event_time(message),enqueued_at)<($1->>'fingerprint_cutoff')::timestamptz AND message IS DISTINCT FROM kansoku.apply_event_disposition(message,false,false,true) ORDER BY msg_id LIMIT 1000), changed AS (UPDATE " <> table <> " q SET message=s.body FROM selected s WHERE q.msg_id=s.msg_id RETURNING q.msg_id) SELECT to_jsonb(count(*)) FROM changed")
      scope
  repeatPages connection "WITH selected AS (SELECT id,kansoku.apply_event_disposition(jsonb_build_object('queueVersion',2,'event',payload),false,false,true)->'event' AS body FROM kansoku.ingest_rejections WHERE coalesce(kansoku.event_time(jsonb_build_object('queueVersion',2,'event',payload)),received_at)<($1->>'fingerprint_cutoff')::timestamptz AND payload IS DISTINCT FROM (kansoku.apply_event_disposition(jsonb_build_object('queueVersion',2,'event',payload),false,false,true)->'event') ORDER BY received_at,id LIMIT 1000), changed AS (UPDATE kansoku.ingest_rejections q SET payload=s.body FROM selected s WHERE q.id=s.id RETURNING q.id) SELECT to_jsonb(count(*)) FROM changed" scope
