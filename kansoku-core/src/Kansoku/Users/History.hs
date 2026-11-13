module Kansoku.Users.History where

import Data.Aeson qualified as A
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as T
import Data.Time (Day)
import Kansoku.ClickHouse (QueryPool, withIdentityQueryConnection)
import Kansoku.Event (AccountId (..), EventName (..))
import Kansoku.Event.Registry qualified as E
import Kansoku.Metrics.Filter qualified as F
import Kansoku.Metrics.Query.Filter qualified as QF
import Kansoku.Prelude
import Kansoku.Users.Query
import Kansoku.Users.Types hiding (source)
import Relay.Pagination qualified as R
import Relay.Pagination.Hasql qualified as R

safeProperties :: E.EventRegistry -> Text -> Int -> A.Value -> Map.Map Text A.Value
safeProperties registry name version raw = case (E.lookupSchemaVersion (EventName name) version registry, raw) of
  (Just E.EventSchema {properties = specs}, A.Object values) ->
    Map.fromList
      [(key, value) | E.PropertySpec {name = key, propertyType = kind} <- specs, permitted key, Just value <- [KM.lookup (Key.fromText key) values], compatible kind value]
  _ -> Map.empty
  where
    permitted key =
      name /= "alias"
        && key `notElem` ["previousId", "newId", "userId", "anonymousId", "identifiers", "email", "email_hmac", "email_sha256", "cookie", "device", "fingerprint", "sessionId", "ip", "ipAddress"]
        && (name `notElem` ["identify", "identify_once"] || isJust (E.lookupTrait key))
        && (name /= "group" || isJust (E.lookupOrganizationTrait key))
    compatible E.PTString (A.String _) = True
    compatible E.PTNumber (A.Number n) = let d = realToFrac n :: Double in not (isInfinite d || isNaN d)
    compatible E.PTBool (A.Bool _) = True
    compatible _ _ = False

historySort :: R.SortSpec UserEvent
historySort = R.SortSpec (R.KeyColumn "occurredAt" R.Desc (\UserEvent {occurredAt} -> occurredAt) R.textKey :| [R.KeyColumn "receivedAt" R.Desc eventReceivedAt R.textKey, R.KeyColumn "eventId" R.Desc (\UserEvent {eventId} -> eventId) R.textKey])

historyBoundary :: R.PageRequest -> Either R.CursorError (Maybe (Text, Text, Text))
historyBoundary R.PageRequest {cursor} = traverse decode cursor
  where
    decode c = do
      payload <- R.decodeCursor (R.sortSpecFingerprint historySort) c
      case R.keys payload of
        [R.KvText a, R.KvText b, R.KvText cKey] -> Right (a, b, cKey)
        keys -> Left (R.KeyCountMismatch 3 (length keys))

history :: QueryPool -> AccountId -> Text -> Maybe Day -> Maybe Day -> Bool -> [F.MetricFilter] -> R.PageRequest -> Maybe (Text, Text, Text) -> IO (Maybe [UserEvent])
history pool account ident selectedFrom selectedTo bots filters page boundary = bounded pool $ do
  bounds <- retainedBounds pool account
  case bounds of
    Nothing -> pure Nothing
    Just (lo, hi) -> withIdentityQueryConnection pool (unAccountId account) (T.pack (show lo)) (T.pack (show hi)) $ \conn -> do
      let params = scopeParams account lo hi <> [("user_id", ident)]
          userWhere = " account_id={account_id:String} AND subject_kind='user' AND subject_id={user_id:String}"
      exists <- fetch conn params ("SELECT toJSONString(toBool(count()>0)) AS json FROM " <> source <> " WHERE " <> userWhere) :: IO [Bool]
      if exists /= [True]
        then pure Nothing
        else do
          compiled <- either (const (fail "invalid history filter")) pure (QF.compileMetricFilters E.defaultRegistry [] filters)
          let cmp = if R.direction page == R.Forward then "<" else ">"
              ordering = if R.direction page == R.Forward then " DESC" else " ASC"
              conditions = QF.predicates compiled <> ["NOT is_bot" | not bots] <> ["occurred_at>=toDateTime64({selected_from:String},3,'UTC')" | isJust selectedFrom] <> ["occurred_at<toDateTime64({selected_to:String},3,'UTC')" | isJust selectedTo] <> ["tuple(" <> stamp "occurred_at" <> "," <> stamp "received_at" <> ",event_id)" <> cmp <> "tuple({cursor_occ:String},{cursor_rec:String},{cursor_id:String})" | isJust boundary]
              sql = "SELECT toJSONString(tuple(event_id,event_name," <> stamp "occurred_at" <> "," <> stamp "received_at" <> ",source,source_service,session_id,nullIf(replaceRegexpOne(lowerUTF8(domain(url)),'[.]+$',''),''),nullIf(path(url),''),toBool(event_name='page_view'),schema_version,properties)) AS json FROM " <> source <> " WHERE " <> userWhere <> T.concat (map (" AND " <>) conditions) <> " ORDER BY occurred_at" <> ordering <> ",received_at" <> ordering <> ",event_id" <> ordering <> " LIMIT {users_limit:UInt64}"
              bound = params <> QF.parameters compiled <> [("users_limit", T.pack (show (R.pageSize page + 1)))] <> maybe [] (\d -> [("selected_from", T.pack (show d))]) selectedFrom <> maybe [] (\d -> [("selected_to", T.pack (show d))]) selectedTo <> maybe [] (\(a, b, c) -> [("cursor_occ", a), ("cursor_rec", b), ("cursor_id", c)]) boundary
          rows <- fetch conn bound sql :: IO [(Text, Text, Text, Text, Text, Text, Text, Maybe Text, Maybe Text, Bool, Int, Text)]
          traverse
            ( \(eid, name, at, received, src, service, session, h, p, pv, version, raw) -> do
                properties <- either (const (fail "invalid private property projection")) pure (A.eitherDecodeStrict' (T.encodeUtf8 raw))
                pure (UserEvent eid name at src service session h p pv (safeProperties E.defaultRegistry name version properties) received)
            )
            rows
            >>= pure . Just
