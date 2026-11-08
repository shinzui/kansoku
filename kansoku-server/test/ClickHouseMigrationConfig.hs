module Main (main) where

import ClickHouseMigrate.Target qualified as T
import Control.Monad (forM_, unless)
import Data.Either (isLeft)
import Data.List.NonEmpty qualified as NE
import Kansoku.ClickHouseMigration.Config (parseTopology)

main :: IO ()
main = do
  let a = "11111111-1111-4111-8111-111111111111"
      b = "22222222-2222-4222-8222-222222222222"
      invalid = [(Nothing, Nothing, Nothing), (Just "fixture", Nothing, Nothing), (Nothing, Just a, Nothing), (Just "", Just a, Nothing), (Just "fixture", Just "", Nothing), (Just "fixture", Just (a <> ","), Nothing), (Just "fixture", Just (a <> "," <> a), Nothing), (Just "fixture", Just "bad", Nothing), (Just "fixture", Just a, Just ""), (Just "fixture", Just a, Just b), (Nothing, Nothing, Just "")]
  forM_ invalid $ \(c, r, d) -> unless (isLeft (parseTopology c r d)) (fail "Invalid topology accepted")
  case parseTopology Nothing Nothing (Just a) of
    Right (T.DirectServer sid) -> unless (T.serverIdText sid == a) (fail "Direct identity changed")
    _ -> fail "Direct topology refused"
  case parseTopology (Just "fixture") (Just (" " <> b <> ", " <> a <> " ")) Nothing of
    Right (T.ReplicatedCluster c ids) -> unless (T.clusterNameText c == "fixture" && map T.serverIdText (NE.toList ids) == [a, b]) (fail "Replica inventory is not canonical")
    _ -> fail "Replicated topology refused"
  putStrLn "13 configuration cases passed without network access"
