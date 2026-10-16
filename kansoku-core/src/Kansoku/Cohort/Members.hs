-- | Bounded native member queries and atomic static-list replacements.
module Kansoku.Cohort.Members where

import ClickHaskell (ChString, ClickHaskell, Column, Select, ToChType (toChType), addParameter, command, passParameters, select, unsafeMkSelect)
import ClickHaskell.Protocol (QueryParameters)
import Data.Aeson qualified as A
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Data.String (fromString)
import Data.Text qualified as T
import Data.Text.Encoding qualified as T
import Data.Time (Day)
import Kansoku.ClickHouse (QueryPool, queryDeadlineMicros, withIdentityQueryConnection, withMetricsQueryConnection)
import Kansoku.Cohort.Query
import Kansoku.Cohort.Types (CohortDefinition, kind)
import Kansoku.Event (AccountId (..))
import Kansoku.Prelude
import Relay.Pagination qualified as R
import Relay.Pagination.Hasql qualified as R
import System.Timeout (timeout)

newtype MemberRow = MemberRow {member :: ByteString}
  deriving stock (Generic)
  deriving anyclass (ClickHaskell '[Column "member" ChString])

memberSort :: R.SortSpec Text
memberSort = R.SortSpec (R.KeyColumn "user_id" R.Asc id R.textKey :| [])

memberBoundary :: R.PageRequest -> Either R.CursorError (Maybe Text)
memberBoundary R.PageRequest {cursor} = traverse decode cursor
  where
    decode boundary = do
      payload <- R.decodeCursor (R.sortSpecFingerprint memberSort) boundary
      case R.keys payload of
        [R.KvText key] -> Right key
        keys -> Left (R.KeyCountMismatch 1 (length keys))

memberPopulation :: Text -> Day -> Day -> CohortDefinition -> Either Text (Text, Membership)
memberPopulation ident fromDay toDay def = do
  membership <- compileMembership ident toDay def
  let query =
        if kind def == "static"
          then
            "SELECT user_id FROM analytics.cohort_members WHERE account_id={account_id:String} AND cohort_id={member_cohort:String} GROUP BY user_id HAVING argMax(present,version)=1"
          else "SELECT DISTINCT substring(canonical_user,6) AS user_id FROM " <> source "{member_from:String}" "{member_to:String}" <> " WHERE account_id={account_id:String} AND startsWith(canonical_user,'user:') AND " <> predicate membership
  pure (query, membership {since = min fromDay (since membership)})

memberParameters :: AccountId -> Text -> Day -> Day -> Membership -> [(String, Text)]
memberParameters account ident fromDay toDay membership = [("account_id", unAccountId account), ("member_cohort", ident), ("member_from", T.pack (show fromDay)), ("member_to", T.pack (show toDay))] <> parameters membership

fetchMembers :: QueryPool -> AccountId -> Day -> Day -> [(String, Text)] -> Text -> IO [Text]
fetchMembers pool account fromDay toDay params sql = do
  result <- timeout (queryDeadlineMicros pool) $
    (if "events_resolved_http" `T.isInfixOf` sql then withIdentityQueryConnection pool (unAccountId account) (T.pack (show fromDay)) (T.pack (show toDay)) else withMetricsQueryConnection pool) $ \connection -> do
      rows <- concat . reverse <$> select (passParameters (bind params) (unsafeMkSelect (const (T.encodeUtf8Builder sql)) :: Select '[Column "member" ChString] MemberRow)) connection pure
      traverse (\(MemberRow bytes) -> either (fail . show) pure (T.decodeUtf8' bytes)) rows
  maybe (fail "cohort query resource limit") pure result

bind :: [(String, Text)] -> QueryParameters -> QueryParameters
bind pairs = foldr (\(key, value) rest -> addParameter key (toChType (T.encodeUtf8 value) :: ChString) . rest) id pairs

replaceMembers :: QueryPool -> AccountId -> Text -> [Text] -> IO ()
replaceMembers pool account ident members = do
  let params = [("account_id", unAccountId account), ("member_cohort", ident), ("member_ids", T.decodeUtf8 (LBS.toStrict (A.encode members)))]
      scope = "account_id={account_id:String} AND cohort_id={member_cohort:String}"
      sql = "INSERT INTO analytics.cohort_members SELECT {account_id:String},{member_cohort:String},user_id,(SELECT greatest(now64(3),coalesce(max(version),toDateTime64(0,3,'UTC'))+INTERVAL 1 MILLISECOND) FROM analytics.cohort_members WHERE " <> scope <> "),toUInt8(max(member_present)) FROM (SELECT user_id,toUInt8(0) AS member_present FROM analytics.cohort_members WHERE " <> scope <> " GROUP BY user_id UNION ALL SELECT arrayJoin(JSONExtract({member_ids:String},'Array(String)')) AS user_id,toUInt8(1) AS member_present) GROUP BY user_id"
  result <- timeout (queryDeadlineMicros pool) $ withMetricsQueryConnection pool $ \connection -> command connection (passParameters (bind params) (fromString (T.unpack sql)))
  unless (result == Just ()) (fail "cohort replacement resource limit")
