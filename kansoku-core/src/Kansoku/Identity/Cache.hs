-- | Physical-query-connection-owned exact evidence snapshots. Every use checks
-- current part/table identities; changed parts invalidate before the query.
module Kansoku.Identity.Cache
  ( prepareIdentityCache,
    identityCacheSql,
    identityCacheRevisionSQL,
    IdentityCacheState,
  )
where

import ClickHaskell (ChString, ClickHaskell, Column, Connection, Select, ToChType (toChType), addParameter, command, passParameters, select, unsafeMkSelect)
import Data.Aeson (eitherDecodeStrict')
import Data.ByteString (ByteString)
import Data.IORef (IORef, readIORef, writeIORef)
import Data.Int (Int64)
import Data.String (fromString)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Kansoku.Prelude (Generic, unless)

newtype RevisionRow = RevisionRow {revision :: ByteString}
  deriving stock (Generic)
  deriving anyclass (ClickHaskell '[Column "revision" ChString])

type IdentityCacheState = Maybe (Text.Text, Text.Text, Text.Text, Text.Text, Int64)

prepareIdentityCache :: Text.Text -> Text.Text -> Text.Text -> Connection -> IORef IdentityCacheState -> IO ()
prepareIdentityCache account fromDay toDay connection state = do
  rows <- concat <$> select revisionSelect connection pure
  (current, now) <- case rows of
    [RevisionRow value] -> either fail pure (eitherDecodeStrict' value :: Either String (Text.Text, Int64))
    _ -> fail "identity evidence metadata unavailable"
  previous <- readIORef state
  unless (case previous of Just (cachedAccount, cachedFrom, cachedTo, revision, deadline) -> cachedAccount == account && cachedFrom == fromDay && cachedTo == toDay && revision == current && now < deadline; Nothing -> False) $ do
    mapM_ (command connection . passParameters (addParameter "cache_account" (toChType (Text.unpack account) :: ChString) . addParameter "cache_from" (toChType (Text.unpack fromDay) :: ChString) . addParameter "cache_to" (toChType (Text.unpack toDay) :: ChString)) . fromString . Text.unpack) identityCacheSql
    deadlines <- concat <$> select deadlineSelect connection pure
    (deadline, finished) <- case deadlines of
      [RevisionRow value] -> either fail pure (eitherDecodeStrict' value :: Either String (Int64, Int64))
      _ -> fail "identity fingerprint expiry metadata unavailable"
    -- Keep the before-build revision and clock. Concurrent changes force the
    -- next refresh; expiry during construction must never serve a stale answer.
    writeIORef state (Just (account, fromDay, toDay, current, deadline))
    if finished >= deadline then fail "identity snapshot expired during construction" else pure ()

deadlineSelect :: Select '[Column "revision" ChString] RevisionRow
deadlineSelect = unsafeMkSelect (const "SELECT toJSONString(tuple(joinGet('kansoku_identity_clock','deadline',toUInt8(0)),toUnixTimestamp64Milli(now64(3)))) AS revision")

revisionSelect :: Select '[Column "revision" ChString] RevisionRow
revisionSelect = unsafeMkSelect (const (Text.encodeUtf8Builder identityCacheRevisionSQL))

-- Include empty-table UUIDs and require all three tables; missing evidence must not
-- produce a plausible empty answer. Part names change for inserts, merges and
-- mutations. Table UUIDs also distinguish rebuild swaps/recreation.
identityCacheRevisionSQL :: Text.Text
identityCacheRevisionSQL =
  """
  SELECT toJSONString(tuple(toJSONString(arraySort(groupArray(tuple(name,uuid,parts)))),toUnixTimestamp64Milli(now64(3)))) AS revision
  FROM
  (
    SELECT t.name AS name,t.uuid AS uuid,arraySort(groupArrayIf(p.name,p.active=1)) AS parts
    FROM system.tables AS t
    LEFT JOIN system.parts AS p ON p.database=t.database AND p.table=t.name
    WHERE t.database='analytics' AND t.name IN ('identity_signal_users','identity_session_users','identity_context_signals')
    GROUP BY t.name,t.uuid
  )
  HAVING count()=3
  """

-- These are session-local Join tables, not durable schema or shared mutable
-- caches. Connection disposal destroys them. All keys include the account;
-- observation timestamps establish the next expiry deadline, checked per query.
-- Throw on bounded cache construction rather than accepting a partial lookup.
identityCacheSql :: [Text.Text]
identityCacheSql =
  [ "DROP TEMPORARY TABLE IF EXISTS kansoku_signal_cache",
    "DROP TEMPORARY TABLE IF EXISTS kansoku_session_cache",
    "DROP TEMPORARY TABLE IF EXISTS kansoku_context_cache",
    "DROP TEMPORARY TABLE IF EXISTS kansoku_identity_clock",
    """
    CREATE TEMPORARY TABLE kansoku_identity_clock ENGINE=Join(ANY,LEFT,cache_key) AS
    SELECT toUInt8(0) AS cache_key,if(count()=0,toInt64(9223372036854775807),min(expiry)) AS deadline
    FROM (SELECT toUnixTimestamp64Milli(observed_at+INTERVAL 180 DAY)+1 AS expiry
          FROM analytics.identity_signal_users
          WHERE account_id={cache_account:String} AND signal_kind='fingerprint' AND expiry>toUnixTimestamp64Milli(now64(3)))
    """,
    """
    CREATE TEMPORARY TABLE kansoku_signal_cache
    ENGINE=Join(ANY,LEFT,account_id,signal_kind,signal_value)
    SETTINGS max_bytes_in_join=67108864,join_overflow_mode='throw'
    AS SELECT account_id,CAST(signal_kind,'String') AS signal_kind,signal_value,
              groupArray(tuple(user_id,CAST(observed_at,'DateTime64(3, \\'UTC\\')'))) AS observations
    FROM analytics.identity_signal_users WHERE account_id={cache_account:String} GROUP BY account_id,signal_kind,signal_value
    SETTINGS max_memory_usage=268435456
    """,
    """
    CREATE TEMPORARY TABLE kansoku_session_cache
    ENGINE=Join(ANY,LEFT,account_id,source_service,session_id,signal_value)
    SETTINGS max_bytes_in_join=67108864,join_overflow_mode='throw'
    AS SELECT account_id,source_service,session_id,signal_value,groupUniqArray(user_id) AS users
    FROM analytics.identity_session_users WHERE account_id={cache_account:String} GROUP BY account_id,source_service,session_id,signal_value
    SETTINGS max_memory_usage=268435456
    """,
    """
    CREATE TEMPORARY TABLE kansoku_context_cache
    ENGINE=Join(ANY,LEFT,identity_context_key)
    SETTINGS max_bytes_in_join=134217728,join_overflow_mode='throw'
    AS SELECT concat(toString(length(account_id)),':',account_id,toString(length(source_service)),':',source_service,toString(length(session_id)),':',session_id,toString(length(anonymous_id)),':',anonymous_id,toString(length(identifiers)),':',identifiers) AS identity_context_key,if(stitched_user!='',concat('user:',stitched_user),if(anonymous_id!='',concat('anonymous:',anonymous_id),'')) AS canonical_user
    FROM analytics.identity_context_resolution(scope_all_accounts=0,scope_account={cache_account:String},scope_from=toDate({cache_from:String}),scope_to=toDate({cache_to:String}))
    SETTINGS enable_analyzer=1,max_memory_usage=268435456
    """
  ]
