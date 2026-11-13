-- | One owned identity connection and deadline for all profile components.
module Kansoku.Users.Profile where

import Data.Aeson qualified as A
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Kansoku.ClickHouse (QueryPool, withIdentityQueryConnection)
import Kansoku.Event (AccountId (..), PropertySpec (..), organizationTraits)
import Kansoku.Prelude
import Kansoku.Users.Query
import Kansoku.Users.Types hiding (source)

profile :: QueryPool -> AccountId -> Text -> IO (Maybe UserProfile)
profile pool account ident = bounded pool $ do
  bounds <- retainedBounds pool account
  case bounds of
    Nothing -> pure Nothing
    Just (lo, hi) -> withIdentityQueryConnection pool (unAccountId account) (T.pack (show lo)) (T.pack (show hi)) $ \conn -> do
      let params = scopeParams account lo hi <> [("user_id", ident)]
      totals <- fetch conn params ("SELECT toJSONString(tuple(" <> stamp ("minOrNullIf(occurred_at," <> activity False <> ")") <> "," <> stamp ("maxOrNullIf(occurred_at," <> activity False <> ")") <> ",count(),uniqExactIf(anonymous_id,user_id='' AND anonymous_id!=''))) AS json FROM " <> source <> " WHERE account_id={account_id:String} AND subject_kind='user' AND subject_id={user_id:String} HAVING count()>0") :: IO [(Maybe Text, Maybe Text, Integer, Integer)]
      case totals of
        [] -> pure Nothing
        [(firstAt, lastAt, n, anon)] -> do
          -- Ordering by the operation first makes every set win over set-once;
          -- sign reversal selects the earliest complete tuple for set-once.
          observations <- fetch conn params "SELECT toJSONString(tuple(name,trait_type,text_value,number_value,observed_at,operation)) AS json FROM (SELECT name,trait_type,text_value,number_value,concat(substring(formatDateTime(occurred_at,'%Y-%m-%dT%H:%i:%S.%f','UTC'),1,23),'Z') AS observed_at,if(event_name='identify','set','set_once') AS operation FROM analytics.user_trait_events WHERE account_id={account_id:String} AND user_id={user_id:String} ORDER BY name,event_name='identify' DESC,if(event_name='identify',toUnixTimestamp64Milli(occurred_at),-toUnixTimestamp64Milli(occurred_at)) DESC,if(event_name='identify',toUnixTimestamp64Milli(received_at),-toUnixTimestamp64Milli(received_at)) DESC,if(event_name='identify',event_id,'') DESC,if(event_name='identify_once',event_id,'') ASC LIMIT 1 BY name)" :: IO [(Text, Text, Text, Double, Text, Text)]
          evidence <- fetch conn params "SELECT toJSONString(tuple(signal_kind,uniqExact(signal_value))) AS json FROM analytics.identity_signal_users FINAL WHERE account_id={account_id:String} AND user_id={user_id:String} AND (signal_kind!='fingerprint' OR observed_at>=now64(3)-INTERVAL 180 DAY) GROUP BY signal_kind" :: IO [(Text, Integer)]
          memberships <- fetch conn params "SELECT toJSONString(argMaxMerge(organization_id)) AS json FROM analytics.user_organizations WHERE account_id={account_id:String} AND user_id={user_id:String} HAVING count()>0" :: IO [Text]
          org <- case memberships of
            [orgId] | orgId /= "" -> do
              orgTraits <- fetch conn (params <> [("organization_id", orgId)]) "SELECT toJSONString(tuple(name,trait_type,text_value,number_value)) AS json FROM analytics.organization_traits WHERE account_id={account_id:String} AND organization_id={organization_id:String}" :: IO [(Text, Text, Text, Double)]
              pure (Just (UserOrganization orgId (Map.fromList [(name, if kind == "number" then A.toJSON number else A.String text) | (name, kind, text, number) <- orgTraits, name `elem` [key | PropertySpec {name = key} <- organizationTraits]])))
            _ -> pure Nothing
          let ts = Map.fromList [(name, TraitObservation v at op) | (name, kind, text, number, at, op) <- observations, Just v <- [Map.lookup name (traitMap [(name, kind, text, number)])]]
              counts = Map.fromList [(kind, fromMaybe 0 (lookup kind evidence)) | kind <- ["cookie", "device", "fingerprint", "email_hmac", "email_sha256"]]
          pure (Just (UserProfile ident ts firstAt lastAt n counts anon org))
        _ -> fail "invalid profile projection"
