module Main (main) where

import ClickHouseMigrate.Target qualified as T
import Kansoku.ClickHouseMigration.Command (mainWith)
import Kansoku.ClickHouseMigrations qualified as Direct
import Kansoku.ClickHouseReplicatedMigrations qualified as Replicated

main :: IO ()
main = mainWith (\topology args -> (args, case topology of T.DirectServer _ -> Direct.plan; T.ReplicatedCluster _ _ -> Replicated.plan))
