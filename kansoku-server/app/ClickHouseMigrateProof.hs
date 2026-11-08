-- Test-only executable: the production entry point cannot select these plans.
module Main (main) where

import ClickHouseMigrate.Target qualified as T
import Kansoku.ClickHouseMigration.Command (mainWith)
import Kansoku.ClickHouseMigration.UpgradeProof qualified as Migrations

main :: IO ()
main = mainWith $ \topology args ->
  let changed = "--proof-change-applied-step" `elem` args
      tiny = "--proof-tiny" `elem` args
      historical = "--proof-historical-prefix" `elem` args
      replicated = case topology of T.DirectServer _ -> False; T.ReplicatedCluster _ _ -> True
      surviving = "--proof-surviving-mutation" `elem` args
      arguments = filter (`notElem` ["--proof-change-applied-step", "--proof-surviving-mutation", "--proof-tiny", "--proof-historical-prefix"]) args
   in (arguments, if historical then Migrations.historicalPlan replicated else if tiny then Migrations.tinyPlan else if replicated then (if changed then Migrations.replicatedChangedPlan else Migrations.replicatedPlan) else if surviving then Migrations.survivingPlan else if changed then Migrations.changedPlan else Migrations.plan)
