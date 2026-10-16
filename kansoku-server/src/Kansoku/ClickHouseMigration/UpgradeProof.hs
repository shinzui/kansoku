-- | Test-only compiled upgrade, never selected by the production executable.
module Kansoku.ClickHouseMigration.UpgradeProof (plan, changedPlan, survivingPlan) where

import ClickHouseMigrate.Definition
import ClickHouseMigrate.Error (PlanError)
import ClickHouseMigrate.Plan
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Set qualified as Set
import Kansoku.ClickHouseMigrations qualified as Baseline

plan :: Either PlanError MigrationPlan
plan = buildPlan False False

changedPlan :: Either PlanError MigrationPlan
changedPlan = buildPlan True False

survivingPlan :: Either PlanError MigrationPlan
survivingPlan = buildPlan False True

buildPlan :: Bool -> Bool -> Either PlanError MigrationPlan
buildPlan changed surviving = do
  baseline <- Baseline.plan
  -- Reconstruct unchanged definitions exclusively through public constructors.
  -- Description is diagnostic and does not participate in checksum identity.
  migrations <- either (const (error "Invalid compiled baseline")) Right $ traverse rebuild (NE.toList (inspectSchedule baseline))
  let next =
        if surviving
          then do
            update <- sqlStep "update" "ALTER TABLE analytics.__native_survivor UPDATE value=value+1 WHERE id=1"
            sqlMigration "0026_native_survivor_proof" (update :| [])
          else do
            create <- sqlStep "create-probe" "CREATE TABLE analytics.__native_upgrade_probe (id UInt8) ENGINE=MergeTree ORDER BY id"
            insert <- sqlStep "insert-probe" "INSERT INTO analytics.__native_upgrade_probe VALUES (7)"
            finish <- sqlStep "finish-probe" "ALTER TABLE analytics.__native_upgrade_probe ADD COLUMN finished UInt8"
            sqlMigration "0026_native_upgrade_proof" (create :| [insert, finish])
  appended <- either (const (error "Invalid compiled upgrade")) Right next
  component <- either (const (error "Invalid compiled upgrade component")) Right (migrationComponent "kansoku" Set.empty (NE.fromList (migrations ++ [appended])))
  migrationPlan (component :| [])
  where
    rebuild migration = do
      steps <- traverse (\step -> sqlStep (stepNameText (stepViewName step)) (stepSql step <> if changed && migrationNameText (migrationIdName (migrationId migration)) == "0001_events_raw" && stepNameText (stepViewName step) == "statement-01" then "\n-- changed applied definition proof\n" else "")) (migrationSteps migration)
      sqlMigration (migrationNameText (migrationIdName (migrationId migration))) steps
