module Kansoku.ReplicaTopologySpec (spec) where

import Data.Either (isLeft)
import Data.Text qualified as Text
import Kansoku.ClickHouse.Consistency (Role (..), roleSettings)
import Kansoku.ClickHouse.Topology
import Test.Hspec

spec :: Spec
spec = describe "Replica topology" $ do
  let a = "11111111-1111-4111-8111-111111111111"
      b = "22222222-2222-4222-8222-222222222222"
  it "defaults to direct only when both selectors are absent" $
    parseTopology Nothing Nothing `shouldBe` Right Direct
  it "canonicalizes configured identities independently of discovery" $
    parseTopology (Just "fixture") (Just (" " <> b <> ", " <> a)) `shouldBe` Right (Replicated "fixture" [a, b])
  it "rejects partial, empty, malformed and duplicate inventories" $
    mapM_
      (\(c, r) -> parseTopology c r `shouldSatisfy` isLeft)
      [(Just "fixture", Nothing), (Nothing, Just a), (Just "", Just a), (Just "Fixture", Just a), (Just "x;SELECT", Just a), (Just "fixture", Just ""), (Just "fixture", Just (a <> ",")), (Just "fixture", Just (a <> "," <> a)), (Just "fixture", Just "bad"), (Just "fixture", Just (Text.replicate 65 (a <> ",") <> b))]
  it "preserves a stable job identity for a reordered inventory" $
    fmap topologyIdentity (parseTopology (Just "fixture") (Just (b <> "," <> a))) `shouldBe` fmap topologyIdentity (parseTopology (Just "fixture") (Just (a <> "," <> b)))

  it "keeps direct writers synchronous without changing their deduplication contract" $
    roleSettings Direct Writer `shouldBe` [("async_insert", "0")]
  it "requires every expected replica on every replicated writer connection" $ do
    let settings = roleSettings (Replicated "fixture" [a, b]) Writer
    lookup "insert_quorum" settings `shouldBe` Just "2"
    lookup "insert_quorum_parallel" settings `shouldBe` Just "0"
    lookup "insert_quorum_timeout" settings `shouldBe` Just "20000"
    lookup "deduplicate_blocks_in_dependent_materialized_views" settings `shouldBe` Just "1"
  it "bounds maintenance waits and independently initializes read-back" $ do
    lookup "mutations_sync" (roleSettings (Replicated "fixture" [a, b]) Maintenance) `shouldBe` Just "2"
    lookup "alter_sync" (roleSettings (Replicated "fixture" [a, b]) Maintenance) `shouldBe` Just "2"
    lookup "select_sequential_consistency" (roleSettings (Replicated "fixture" [a, b]) Readback) `shouldBe` Just "1"
