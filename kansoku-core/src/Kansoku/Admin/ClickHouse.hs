-- | Native, parameterized maintenance over the currently installed projections.
module Kansoku.Admin.ClickHouse
  ( chJSON,
    chCommand,
    discoverIdentity,
    affected,
    explicitSubject,
    rebuildDerived,
    verifyMutations,
    quiesceRawWrites,
    scopeText,
    quoteName,
  )
where

import ClickHaskell (ChString, ClickHaskell, Column, Connection, Select, ToChType (toChType), addParameter, command, passParameters, select, unsafeMkSelect)
import Control.Concurrent (threadDelay)
import Control.Monad (forM, forM_)
import Data.Aeson qualified as A
import Data.Aeson.Types qualified as A
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.String (fromString)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Kansoku.Prelude
import System.Timeout (timeout)

newtype JsonRow = JsonRow {value :: BS.ByteString}
  deriving stock (Generic)
  deriving anyclass (ClickHaskell '[Column "value" ChString])

scopeText :: A.Value -> BS.ByteString
scopeText = LBS.toStrict . A.encode

chCommand :: Connection -> A.Value -> Text -> IO ()
chCommand connection scope sql =
  command connection $
    passParameters (addParameter "admin_scope" (toChType (scopeText scope) :: ChString)) (fromString (Text.unpack sql))

chJSON :: Connection -> A.Value -> Text -> IO [A.Value]
chJSON connection scope sql = do
  let statement =
        passParameters
          (addParameter "admin_scope" (toChType (scopeText scope) :: ChString))
          (unsafeMkSelect (const (Text.encodeUtf8Builder sql)) :: Select '[Column "value" ChString] JsonRow)
  rows <- concat . reverse <$> select statement connection pure
  traverse (\(JsonRow bytes) -> either (const (fail "invalid maintenance native result")) pure (A.eitherDecodeStrict' bytes)) rows

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
rebuildDerived connection = do
  definitions <- forM projections $ \(viewName, target) -> do
    rows <- chJSON connection A.Null ("SELECT toJSONString(as_select) AS value FROM system.tables WHERE database='analytics' AND name='" <> viewName <> "' AND engine='MaterializedView'")
    source <- case rows of
      [A.String sql] | "SELECT" `Text.isPrefixOf` sql -> pure sql
      _ -> fail "required current maintenance projection is absent"
    cols <- chJSON connection A.Null ("SELECT toJSONString(name) AS value FROM system.columns WHERE database='analytics' AND table='" <> target <> "' ORDER BY position")
    names <- traverse (either (const (fail "invalid current projection column")) pure . A.parseEither A.parseJSON) cols
    when (null names) (fail "current maintenance target has no columns")
    let canonical = Text.replace "analytics.events_raw" "analytics.events_canonical" source
    unless
      ("analytics.events_canonical" `Text.isInfixOf` canonical || "analytics.identity_signals" `Text.isInfixOf` canonical)
      (fail "unsupported current projection source; maintenance fence retained")
    pure (target, Text.intercalate "," (map quoteName names), canonical)
  forM_ definitions $ \(target, _, _) -> chCommand connection A.Null ("TRUNCATE TABLE analytics." <> target)
  forM_ definitions $ \(target, columns, source) ->
    chCommand connection A.Null ("INSERT INTO analytics." <> target <> " (" <> columns <> ") SELECT " <> columns <> " FROM (" <> source <> ")")
  verifyMutations connection
  -- Canonical raw facts and the frozen public projection must retain all rows.
  values <- chJSON connection A.Null "SELECT toJSONString(count()) AS value FROM analytics.events_canonical"
  public <- chJSON connection A.Null "SELECT toJSONString(count()) AS value FROM analytics.events_resolved"
  unless (values == public) (fail "public projection lost canonical facts during maintenance")

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
verifyMutations connection = do
  failed <- chJSON connection A.Null "SELECT toJSONString(count()) AS value FROM system.mutations WHERE database='analytics' AND (NOT is_done OR latest_fail_reason!='')"
  unless (failed == [A.Number 0]) (fail "unfinished or failed native mutation; maintenance fence retained")

quoteName :: Text -> Text
quoteName name = "`" <> Text.replace "`" "``" name <> "`"

-- A cancelled native client can leave its server insert completing. Native
-- INSERT negotiates a sample block before sending rows, so any write that can
-- still commit data is already registered in system.processes. Async inserts
-- are explicitly disabled on the writer's physical connections.
quiesceRawWrites :: Connection -> IO ()
quiesceRawWrites connection = do
  result <- timeout 60_000_000 loop
  unless (result == Just ()) (fail "native raw writes did not quiesce; maintenance fence retained")
  where
    loop = do
      active <- chJSON connection A.Null "SELECT toJSONString(count()) AS value FROM system.processes WHERE lower(query_kind)='insert' AND position(query,'events_raw')>0 AND (current_database='analytics' OR position(query,'analytics.events_raw')>0 OR position(query,'`analytics`.`events_raw`')>0)"
      unless (active == [A.Number 0]) (threadDelay 100_000 >> loop)
