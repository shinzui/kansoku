-- | All candidate facts are resolved on the physical connection owning evidence.
module Kansoku.Users.Query where

import ClickHaskell (ChString, ClickHaskell, Column, Connection, Select, passParameters, select, unsafeMkSelect)
import Data.Aeson qualified as A
import Data.ByteString (ByteString)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as T
import Data.Time (Day)
import Kansoku.ClickHouse (QueryPool, queryDeadlineMicros, withIdentityQueryConnection, withMetricsQueryConnection)
import Kansoku.Cohort.Members (bind)
import Kansoku.Cohort.Query qualified as C
import Kansoku.Event (AccountId (..), PropertySpec (..), defaultRegistry, governedTraits)
import Kansoku.Metrics.Filter qualified as F
import Kansoku.Metrics.Query (activityPredicate)
import Kansoku.Metrics.Query.Filter qualified as QF
import Kansoku.Metrics.Query.Traits qualified as Traits
import Kansoku.Prelude
import Kansoku.Users.Types hiding (source)
import Relay.Pagination qualified as R
import Relay.Pagination.Hasql qualified as R
import System.Timeout (timeout)

newtype JsonRow = JsonRow {json :: ByteString}
  deriving stock (Generic)
  deriving anyclass (ClickHaskell '[Column "json" ChString])

fetch :: (FromJSON a) => Connection -> [(String, Text)] -> Text -> IO [a]
fetch connection params sql = do
  rows <- concat . reverse <$> select (passParameters (bind params) (unsafeMkSelect (const (T.encodeUtf8Builder (sql <> " SETTINGS output_format_json_quote_64bit_integers=0"))) :: Select '[Column "json" ChString] JsonRow)) connection pure
  traverse (\(JsonRow bytes) -> either (const (fail "invalid users projection")) pure (A.eitherDecodeStrict' bytes)) rows

bounded :: QueryPool -> IO a -> IO a
bounded pool action = timeout (queryDeadlineMicros pool) action >>= maybe (fail "users query resource limit") pure

accountParams :: AccountId -> [(String, Text)]
accountParams account = [("account_id", unAccountId account)]

-- No arbitrary epoch or maximum history length: discover actual retained dates.
retainedBounds :: QueryPool -> AccountId -> IO (Maybe (Day, Day))
retainedBounds pool account = withMetricsQueryConnection pool $ \conn -> do
  rows <- fetch conn (accountParams account) "SELECT toJSONString(tuple(toString(toDate32(min(occurred_at),'UTC')),toString(addDays(toDate32(max(occurred_at),'UTC'),1)))) AS json FROM analytics.events_canonical WHERE account_id={account_id:String} HAVING count()>0"
  case rows of
    [] -> pure Nothing
    [(lo, hi)] -> case (reads (T.unpack lo), reads (T.unpack hi)) of
      ([(l, "")], [(h, "")]) -> pure (Just (l, h))
      _ -> fail "invalid retained bounds"
    _ -> fail "invalid retained bounds"

source :: Text
source = C.source "{users_from:String}" "{users_to:String}"

scopeParams :: AccountId -> Day -> Day -> [(String, Text)]
scopeParams account lo hi = accountParams account <> [("users_from", T.pack (show lo)), ("users_to", T.pack (show hi))]

activity :: Bool -> Text
activity bots = activityPredicate <> if bots then "" else " AND NOT is_bot"

stamp :: Text -> Text
stamp expr = "concat(substring(formatDateTime(" <> expr <> ",'%Y-%m-%dT%H:%i:%S.%f','UTC'),1,23),'Z')"

summarySort :: Text -> R.SortSpec UserSummary
summarySort order = R.SortSpec (R.KeyColumn "null" R.Asc (\u -> if isNothing (chosen u) then "1" else "0") R.textKey :| [R.KeyColumn order R.Desc (fromMaybe "" . chosen) R.textKey, R.KeyColumn "userId" R.Asc (\UserSummary {userId} -> userId) R.textKey])
  where
    chosen UserSummary {firstActivityAt, lastActivityAt} = if order == "firstActivity" then firstActivityAt else lastActivityAt

summaryBoundary :: Text -> R.PageRequest -> Either R.CursorError (Maybe (Text, Text, Text))
summaryBoundary order R.PageRequest {cursor} = traverse decode cursor
  where
    decode c = do
      payload <- R.decodeCursor (R.sortSpecFingerprint (summarySort order)) c
      case R.keys payload of
        [R.KvText n, R.KvText stampKey, R.KvText user] -> Right (n, stampKey, user)
        keys -> Left (R.KeyCountMismatch 3 (length keys))

directoryRows :: QueryPool -> AccountId -> Day -> Maybe Day -> Maybe Day -> Maybe Text -> Text -> Bool -> [F.MetricFilter] -> Maybe (C.Membership, Bool) -> R.PageRequest -> Maybe (Text, Text, Text) -> IO [UserSummary]
directoryRows pool account anchor selectedFrom selectedTo search order bots filters membership page boundary = bounded pool $ do
  bounds <- retainedBounds pool account
  case bounds of
    Nothing -> pure []
    Just (lo, hi) -> do
      let scopeLo = maybe lo (min lo . C.since . fst) membership
          scopeHi = max hi anchor
          userFilters = filter (T.isPrefixOf "user:" . F.dimension) filters
      compiled <- either (const (fail "invalid user filter")) pure (QF.compileMetricFilters defaultRegistry [] userFilters)
      withIdentityQueryConnection pool (unAccountId account) (T.pack (show scopeLo)) (T.pack (show scopeHi)) $ \conn -> do
        let act = activity bots
            window = case (selectedFrom, selectedTo) of
              (Just _, Just _) -> " AND occurred_at>=toDateTime64({selected_from:String},3,'UTC') AND occurred_at<toDateTime64({selected_to:String},3,'UTC')"
              _ -> ""
            grouped = "SELECT subject_id AS user_id,minOrNullIf(occurred_at," <> act <> ") AS first_at,maxOrNullIf(occurred_at," <> act <> ") AS last_at,countIf(" <> act <> window <> ") AS selected FROM " <> source <> " WHERE account_id={account_id:String} AND subject_kind='user' GROUP BY subject_id"
            population = Traits.eventSource (Traits.referencedTraits (map F.dimension userFilters)) ("(SELECT *,concat('user:',user_id) AS canonical_user,user_id AS subject_id,'user' AS subject_kind,{account_id:String} AS account_id FROM (" <> grouped <> "))")
            constraints = QF.predicates compiled <> ["selected>0" | isJust selectedFrom] <> ["positionCaseInsensitiveUTF8(user_id,{search:String})>0" | isJust search] <> maybe [] (\(m, neg) -> [(if neg then "NOT (" else "(") <> C.predicate m <> ")"]) membership
            chosen = if order == "firstActivity" then "first_at" else "last_at"
            n = "toString(isNull(" <> chosen <> "))"
            t = "ifNull(" <> stamp chosen <> ",'')"
            forward = R.direction page == R.Forward
            cmp a b = if forward then a else b
            cursorWhere = maybe [] (const ["(" <> n <> cmp ">" "<" <> "{cursor_null:String} OR (" <> n <> "={cursor_null:String} AND (" <> t <> cmp "<" ">" <> "{cursor_stamp:String} OR (" <> t <> "={cursor_stamp:String} AND user_id" <> cmp ">" "<" <> "{cursor_user:String}))))"]) boundary
            whereSql = if null (constraints <> cursorWhere) then "" else " WHERE " <> T.intercalate " AND " (constraints <> cursorWhere)
            sql = "SELECT toJSONString(tuple(user_id," <> stamp "first_at" <> "," <> stamp "last_at" <> ")) AS json FROM " <> population <> whereSql <> " ORDER BY " <> n <> cmp " ASC," " DESC," <> t <> cmp " DESC," " ASC," <> "user_id" <> cmp " ASC" " DESC" <> " LIMIT {users_limit:UInt64}"
            params = scopeParams account scopeLo scopeHi <> QF.parameters compiled <> maybe [] (C.parameters . fst) membership <> [("users_limit", T.pack (show (R.pageSize page + 1)))] <> maybe [] (\s -> [("search", s)]) search <> maybe [] (\d -> [("selected_from", T.pack (show d))]) selectedFrom <> maybe [] (\d -> [("selected_to", T.pack (show d))]) selectedTo <> maybe [] (\(a, b, c) -> [("cursor_null", a), ("cursor_stamp", b), ("cursor_user", c)]) boundary
        rows <- fetch conn params sql :: IO [(Text, Maybe Text, Maybe Text)]
        traverse
          ( \(ident, firstAt, lastAt) -> do
              ts <- fetch conn (accountParams account <> [("user_id", ident)]) "SELECT toJSONString(tuple(name,trait_type,text_value,number_value)) AS json FROM analytics.user_traits WHERE account_id={account_id:String} AND user_id={user_id:String}"
              pure (UserSummary ident (traitMap ts) firstAt lastAt)
          )
          rows

traitMap :: [(Text, Text, Text, Double)] -> Map.Map Text A.Value
traitMap rows = Map.fromList [(name, if kind == "number" then A.toJSON number else A.String text) | (name, kind, text, number) <- rows, name `elem` [n | PropertySpec {name = n} <- governedTraits]]

countRows :: QueryPool -> AccountId -> Day -> Day -> Bool -> IO UserActivityCounts
countRows pool account lo hi bots = bounded pool $ withIdentityQueryConnection pool (unAccountId account) (T.pack (show lo)) (T.pack (show hi)) $ \conn -> do
  rows <- fetch conn (scopeParams account lo hi) ("SELECT toJSONString(tuple(uniqExactIf(subject_id,subject_kind='user'),uniqExactIf(subject_id,subject_kind='anonymous'))) AS json FROM " <> source <> " WHERE account_id={account_id:String} AND subject_id!='' AND " <> activity bots)
  case rows of [(a, b)] -> pure (UserActivityCounts a b); _ -> fail "invalid activity counts"
