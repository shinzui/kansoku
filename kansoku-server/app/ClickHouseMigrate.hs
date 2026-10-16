module Main (main) where

import Kansoku.ClickHouseMigration.Command (mainWith)
import Kansoku.ClickHouseMigrations qualified as Migrations

main :: IO ()
main = mainWith (\args -> (args, Migrations.plan))
