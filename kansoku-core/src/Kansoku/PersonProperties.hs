-- | Fenced trait lifecycle primitives consumed by administrative maintenance.
-- The caller must fence ingest, writer and metric readers for the affected
-- account before mutations/rebuilds; a multi-statement rebuild is not atomic.
module Kansoku.PersonProperties
  ( TraitErasureMode (..),
    eraseUserTraits,
    rebuildUserTraits,
  )
where

import ClickHaskell (ChString, Connection, ToChType (toChType), addParameter, command, passParameters)
import Control.Monad (forM_)
import Data.String (fromString)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Kansoku.Event (AccountId (..), UserId (..))
import Kansoku.Prelude

data TraitErasureMode = DeleteTraitEvents | ScrubTraitEvents
  deriving stock (Generic, Eq, Show)

-- | Reserve erased immutable IDs before changing sources. Replaying an old raw
-- event cannot repopulate a trait state, including after a later rebuild.
-- EP-37 also cleans queue/archive/acceptance inputs before releasing its fence.
eraseUserTraits :: Connection -> AccountId -> UserId -> TraitErasureMode -> IO ()
eraseUserTraits connection account user mode = do
  execute connection account user $ "INSERT INTO analytics.trait_event_erasures SELECT account_id,event_id FROM analytics.events_canonical WHERE " <> subject <> " AND " <> operation
  execute connection account user $ case mode of
    DeleteTraitEvents -> "ALTER TABLE analytics.events_raw DELETE WHERE " <> subject <> " AND " <> operation <> synchronous
    ScrubTraitEvents -> "ALTER TABLE analytics.events_raw UPDATE properties='{}' WHERE " <> subject <> " AND " <> operation <> synchronous
  rebuildUserTraits connection account user

-- | Rebuild only the affected account/user from retained eligible facts. Both
-- states must be cleared: replaying argMax alone cannot remove an erased winner.
rebuildUserTraits :: Connection -> AccountId -> UserId -> IO ()
rebuildUserTraits connection account user = do
  forM_ [("user_properties", "argMax", "identify"), ("user_properties_once", "argMin", "identify_once")] $ \(table, aggregate, eventName) -> do
    execute connection account user $ "ALTER TABLE analytics." <> table <> " DELETE WHERE " <> subject <> synchronous
    execute connection account user $ "INSERT INTO analytics." <> table <> " SELECT account_id,user_id,name," <> aggregate <> "State(tuple(trait_type,text_value,number_value),tuple(occurred_at,received_at,event_id)) FROM analytics.user_trait_events WHERE " <> subject <> " AND event_name='" <> eventName <> "' GROUP BY account_id,user_id,name"

subject :: Text
subject = "account_id={trait_account:String} AND user_id={trait_user:String}"

operation :: Text
operation = "((event_name='identify' AND schema_version=2) OR (event_name='identify_once' AND schema_version=1))"

synchronous :: Text
synchronous = " SETTINGS mutations_sync=2"

execute :: Connection -> AccountId -> UserId -> Text -> IO ()
execute connection (AccountId account) (UserId user) sql =
  command connection $
    passParameters
      (addParameter "trait_account" (toChType (Text.encodeUtf8 account) :: ChString) . addParameter "trait_user" (toChType (Text.encodeUtf8 user) :: ChString))
      (fromString (Text.unpack sql))
