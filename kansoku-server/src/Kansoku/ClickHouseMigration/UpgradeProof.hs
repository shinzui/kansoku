-- | Test-only compiled upgrade, never selected by the production executable.
module Kansoku.ClickHouseMigration.UpgradeProof (plan, changedPlan, survivingPlan, replicatedPlan, replicatedChangedPlan, tinyPlan, historicalPlan) where

import ClickHouseMigrate.Definition
import ClickHouseMigrate.Error (PlanError)
import ClickHouseMigrate.Plan
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Set qualified as Set
import Kansoku.ClickHouseMigrations qualified as Baseline
import Kansoku.ClickHouseReplicatedMigrations qualified as Replicated

plan :: Either PlanError MigrationPlan
plan = buildPlan False False False

changedPlan :: Either PlanError MigrationPlan
changedPlan = buildPlan False True False

survivingPlan :: Either PlanError MigrationPlan
survivingPlan = buildPlan False False True

replicatedPlan :: Either PlanError MigrationPlan
replicatedPlan = buildPlan True False False

replicatedChangedPlan :: Either PlanError MigrationPlan
replicatedChangedPlan = buildPlan True True False

tinyPlan :: Either PlanError MigrationPlan
tinyPlan = do
  let definition = do
        step <- sqlStep "create" "CREATE TABLE analytics.__tiny (id UInt8) ENGINE=ReplicatedMergeTree ORDER BY id"
        migration <- sqlMigration "tiny" (step :| [])
        migrationComponent "kansoku_tiny" Set.empty (migration :| [])
  component <- either (const (error "Invalid tiny proof")) Right definition
  migrationPlan (component :| [])

buildPlan :: Bool -> Bool -> Bool -> Either PlanError MigrationPlan
buildPlan replicated changed surviving = do
  baseline <- if replicated then Replicated.plan else Baseline.plan
  -- Reconstruct unchanged definitions exclusively through public constructors.
  -- Description is diagnostic and does not participate in checksum identity.
  migrations <- either (const (error "Invalid compiled baseline")) Right $ traverse rebuild (NE.toList (inspectSchedule baseline))
  let next =
        if surviving
          then do
            update <- sqlStep "update" "ALTER TABLE analytics.__native_survivor UPDATE value=value+1 WHERE id=1"
            sqlMigration "0027_native_survivor_proof" (update :| [])
          else do
            create <- sqlStep "create-probe" ("CREATE TABLE analytics.__native_upgrade_probe (id UInt8) ENGINE=" <> (if replicated then "ReplicatedMergeTree" else "MergeTree") <> " ORDER BY id")
            insert <- sqlStep "insert-probe" "INSERT INTO analytics.__native_upgrade_probe VALUES (7)"
            finish <- sqlStep "finish-probe" "ALTER TABLE analytics.__native_upgrade_probe ADD COLUMN finished UInt8"
            sqlMigration "0027_native_upgrade_proof" (create :| [insert, finish])
  appended <- either (const (error "Invalid compiled upgrade")) Right next
  component <- either (const (error "Invalid compiled upgrade component")) Right (migrationComponent (if replicated then "kansoku_replicated" else "kansoku") Set.empty (NE.fromList (migrations ++ [appended])))
  migrationPlan (component :| [])
  where
    rebuild migration = do
      steps <- traverse (\step -> sqlStep (stepNameText (stepViewName step)) (stepSql step <> if changed && migrationNameText (migrationIdName (migrationId migration)) == "0001_events_raw" && stepNameText (stepViewName step) == (if replicated then "statement-02" else "statement-01") then "\n-- changed applied definition proof\n" else "")) (migrationSteps migration)
      sqlMigration (migrationNameText (migrationIdName (migrationId migration))) steps

-- Retain the exact converted prefix to seed real pre-upgrade data and ledger.
historicalPlan :: Bool -> Either PlanError MigrationPlan
historicalPlan replicated = do
  baseline <- if replicated then Replicated.plan else Baseline.plan
  let definition = do
        migrations <-
          traverse
            ( \migration -> do
                steps <- traverse (\step -> sqlStep (stepNameText (stepViewName step)) (stepSql step)) (migrationSteps migration)
                sqlMigration (migrationNameText (migrationIdName (migrationId migration))) steps
            )
            (take 25 (NE.toList (inspectSchedule baseline)))
        migrationComponent (if replicated then "kansoku_replicated" else "kansoku") Set.empty (NE.fromList migrations)
  component <- either (const (error "Invalid historical prefix")) Right definition
  migrationPlan (component :| [])
