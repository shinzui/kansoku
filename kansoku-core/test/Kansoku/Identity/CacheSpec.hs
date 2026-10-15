module Kansoku.Identity.CacheSpec (spec) where

import ClickHaskell (ChString, ClickHaskell, Column, Connection, Select, ToChType (toChType), addParameter, command, passParameters, select, unsafeMkSelect)
import Control.Concurrent (threadDelay)
import Control.Exception (bracket, bracket_, finally)
import Data.Aeson qualified as Aeson
import Data.ByteString (ByteString)
import Data.Either (isLeft)
import Data.Generics.Labels ()
import Data.Map.Strict qualified as Map
import Data.Text.Encoding qualified as Text
import Data.Time (addUTCTime, fromGregorian)
import Kansoku.ClickHouse
import Kansoku.ClickHouseTestSupport (requireConfig, withClickHouse)
import Kansoku.Event
import Kansoku.Exception (trySynchronous)
import Kansoku.Metrics.Query (QueryRequest (..), resolvedSource)
import Kansoku.Prelude
import Test.Hspec

newtype PairRow = PairRow {pair :: ByteString}
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ClickHaskell '[Column "pair" ChString])

spec :: Spec
spec = describe "Kansoku.Identity.Cache native" $ do
  it "refreshes on new evidence, mutations and table replacement, fails closed on missing indexes, and recovers its pool" $
    withClickHouse $ \writer -> do
      cfg <- requireConfig
      now <- getCurrentTime
      let account = "native-cache"
          anonymousEvent = event account "cache-pre" now & #anonymousId ?~ AnonymousId "C"
          binding key user = event account key now & #eventName .~ EventName "identify" & #anonymousId ?~ AnonymousId "C" & #userId ?~ UserId user
      insertEvents writer [anonymousEvent, binding "cache-a" "A"]
      bracket (newQueryPool (clickHouseConfigFromConfig cfg) 1) closeQueryPool $ \pool -> do
        subject pool account "cache-pre" `shouldReturn` Just "user:A"
        insertEvents writer [binding "cache-b" "B"]
        subject pool account "cache-pre" `shouldReturn` Just "anonymous:C"
        command writer "ALTER TABLE analytics.identity_signal_users DELETE WHERE account_id='native-cache' AND user_id='B' SETTINGS mutations_sync=2"
        subject pool account "cache-pre" `shouldReturn` Just "user:A"
        command writer "CREATE TABLE analytics.identity_signal_users_cache_swap AS analytics.identity_signal_users"
        ( do
            command writer "EXCHANGE TABLES analytics.identity_signal_users AND analytics.identity_signal_users_cache_swap"
            subject pool account "cache-pre" `shouldReturn` Just "anonymous:C"
          )
          `finally` do
            command writer "EXCHANGE TABLES analytics.identity_signal_users AND analytics.identity_signal_users_cache_swap"
            command writer "DROP TABLE analytics.identity_signal_users_cache_swap"
        subject pool account "cache-pre" `shouldReturn` Just "user:A"
        ( do
            command writer "RENAME TABLE analytics.identity_signal_users TO analytics.identity_signal_users_cache_missing"
            failed <- trySynchronous (subject pool account "cache-pre")
            failed `shouldSatisfy` isLeft
          )
          `finally` command writer "RENAME TABLE analytics.identity_signal_users_cache_missing TO analytics.identity_signal_users"
        subject pool account "cache-pre" `shouldReturn` Just "user:A"
        withQueryConnection pool $ \conn -> command conn "INSERT INTO kansoku_signal_cache SELECT 'native-cache-fp','cookie','cache-marker',[tuple('marker-user',toDateTime64(now64(3),3,'UTC'))]"
        withQueryConnection pool marker `shouldReturn` [PairRow "1"]
        withIdentityQueryConnection pool account "2026-07-02" "2026-07-03" marker `shouldReturn` [PairRow "0"]
        subject pool account "cache-pre" `shouldReturn` Just "user:A"
        -- An empty authenticated account does not select every account.
        subjects pool "" `shouldReturn` Map.empty

  it "refreshes at fingerprint expiry despite unchanged indexes and isolates physical sessions" $
    withClickHouse $ \writer -> do
      cfg <- requireConfig
      now <- getCurrentTime
      let account = "native-cache-fp"
          ids = Map.singleton "fingerprint" "clock-boundary"
          anonymousEvent = event account "fp-pre" now & #anonymousId ?~ AnonymousId "F" & #identifiers ?~ ids
          expiresSoon = event account "fp-evidence" now & #userId ?~ UserId "FP" & #identifiers ?~ ids & #occurredAt .~ addUTCTime (4 - 180 * 86400) now
          stop = do
            command writer "SYSTEM STOP MERGES analytics.identity_signal_users"
            command writer "SYSTEM STOP MERGES analytics.identity_session_users"
            command writer "SYSTEM STOP MERGES analytics.identity_context_signals"
          start = do
            command writer "SYSTEM START MERGES analytics.identity_signal_users"
            command writer "SYSTEM START MERGES analytics.identity_session_users"
            command writer "SYSTEM START MERGES analytics.identity_context_signals"
      bracket_ stop start $ do
        insertEvents writer [anonymousEvent, expiresSoon]
        bracket (newQueryPool (clickHouseConfigFromConfig cfg) 1) closeQueryPool $ \pool -> do
          subject pool account "fp-pre" `shouldReturn` Just "user:FP"
          withQueryConnection pool $ \conn -> command conn "INSERT INTO kansoku_signal_cache SELECT 'native-cache-fp','cookie','cache-marker',[tuple('marker-user',toDateTime64(now64(3),3,'UTC'))]"
          withQueryConnection pool marker `shouldReturn` [PairRow "1"]
          bracket (newQueryPool (clickHouseConfigFromConfig cfg) 1) closeQueryPool $ \other ->
            withIdentityQueryConnection other account "2026-07-01" "2026-07-02" marker `shouldReturn` [PairRow "0"]
          threadDelay 5_000_000
          subject pool account "fp-pre" `shouldReturn` Just "anonymous:F"
          withQueryConnection pool marker `shouldReturn` [PairRow "0"]
          -- A deadline crossing after preparation must fail closed in SELECT.
          withQueryConnection pool $ \conn -> do
            command conn "DROP TEMPORARY TABLE kansoku_identity_clock"
            command conn "CREATE TEMPORARY TABLE kansoku_identity_clock ENGINE=Join(ANY,LEFT,cache_key) AS SELECT toUInt8(0) AS cache_key,toInt64(0) AS deadline"
          subjects pool account `shouldThrow` anyException
          subject pool account "fp-pre" `shouldReturn` Just "anonymous:F"

-- One field carries each complete JSON pair, avoiding the driver's product-row
-- reversal affecting event/subject association in a multirow native result.
subjects :: QueryPool -> Text -> IO (Map.Map Text Text)
subjects pool account = withIdentityQueryConnection pool account "2026-07-01" "2026-07-02" $ \conn -> do
  let req = QueryRequest (AccountId account) (fromGregorian 2026 7 1) (fromGregorian 2026 7 2) Nothing Nothing [] False
      sql = "SELECT toJSONString(tuple(event_id,canonical_user)) AS pair FROM " <> resolvedSource req
      statement :: Select '[Column "pair" ChString] PairRow
      statement = passParameters (addParameter "account_id" (toChType (Text.encodeUtf8 account) :: ChString)) $ unsafeMkSelect $ const (Text.encodeUtf8Builder sql)
  rows <- concat <$> select statement conn pure
  Map.fromList <$> mapM (\(PairRow bytes) -> either fail pure (Aeson.eitherDecodeStrict' bytes)) rows

subject :: QueryPool -> Text -> Text -> IO (Maybe Text)
subject pool account key = Map.lookup key <$> subjects pool account

marker :: Connection -> IO [PairRow]
marker conn = concat <$> select statement conn pure
  where
    statement :: Select '[Column "pair" ChString] PairRow
    statement = unsafeMkSelect (const "SELECT toString(notEmpty(joinGet('kansoku_signal_cache','observations','native-cache-fp','cookie','cache-marker'))) AS pair")

event :: Text -> Text -> UTCTime -> AnalyticsEvent
event account key received = baseEvent (EventId key) (EventName "native_cache_activity") Web (read "2026-07-01 00:00:00 UTC") received & #accountId ?~ AccountId account
