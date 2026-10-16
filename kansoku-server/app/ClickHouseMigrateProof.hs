-- Test-only executable: the production entry point cannot select these plans.
module Main (main) where

import Kansoku.ClickHouseMigration.Command (mainWith)
import Kansoku.ClickHouseMigration.UpgradeProof qualified as Migrations

main :: IO ()
main = mainWith $ \args ->
  let changed = "--proof-change-applied-step" `elem` args
      surviving = "--proof-surviving-mutation" `elem` args
      arguments = filter (`notElem` ["--proof-change-applied-step", "--proof-surviving-mutation"]) args
   in (arguments, if surviving then Migrations.survivingPlan else if changed then Migrations.changedPlan else Migrations.plan)
