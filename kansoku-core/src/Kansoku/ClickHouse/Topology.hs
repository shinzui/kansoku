-- | Shared runtime/migration selectors. Inventories describe configured expected
-- identities, never just the subset of servers which happened to answer.
module Kansoku.ClickHouse.Topology
  ( Topology (..),
    parseTopology,
    validServerId,
    topologyIdentity,
  )
where

import Data.Aeson qualified as A
import Data.Char (isAsciiLower)
import Data.List (sort)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text

data Topology = Direct | Replicated !Text ![Text]
  deriving stock (Eq, Show)

-- Keep the canonical lower-case UUID spelling used by the migration ledger.
validServerId :: Text -> Bool
validServerId value =
  map Text.length (Text.splitOn "-" value) == [8, 4, 4, 4, 12]
    && Text.all (\c -> c == '-' || digit c || (c >= 'a' && c <= 'f')) value

digit :: Char -> Bool
digit c = c >= '0' && c <= '9'

parseTopology :: Maybe Text -> Maybe Text -> Either Text Topology
parseTopology Nothing Nothing = Right Direct
parseTopology (Just cluster) (Just csv)
  | not validCluster = Left "Invalid KANSOKU_CH_MIGRATION_CLUSTER"
  | null ids || length ids > 64 || not (all validServerId ids) = Left "Invalid KANSOKU_CH_MIGRATION_REPLICA_IDS: expected 1 to 64 canonical UUIDs"
  | Set.size (Set.fromList ids) /= length ids = Left "Invalid replica inventory: duplicate UUIDs"
  | otherwise = Right (Replicated cluster (sort ids))
  where
    ids = map Text.strip (Text.splitOn "," csv)
    validCluster =
      not (Text.null cluster)
        && Text.length cluster <= 128
        && Text.all (\c -> isAsciiLower c || digit c || c `elem` ("_-" :: String)) cluster
        && maybe False (\(c, _) -> isAsciiLower c || c == '_') (Text.uncons cluster)
parseTopology _ _ = Left "Set both KANSOKU_CH_MIGRATION_CLUSTER and KANSOKU_CH_MIGRATION_REPLICA_IDS"

-- Data jobs retain the same topology/cluster/canonical inventory encoding as
-- migration sessions. Historical jobs without an identity are direct-only.
topologyIdentity :: Topology -> A.Value
topologyIdentity topology = case topology of
  Direct -> A.object ["topology" A..= ("direct" :: Text), "cluster" A..= A.Null, "replicas" A..= ([] :: [Text])]
  Replicated cluster ids -> A.object ["topology" A..= ("replicated" :: Text), "cluster" A..= cluster, "replicas" A..= ids]
