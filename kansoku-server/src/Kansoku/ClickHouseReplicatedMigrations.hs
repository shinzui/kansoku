{-# LANGUAGE TemplateHaskell #-}

-- | Immutable application-owned baseline. Append migrations; never edit applied steps.
module Kansoku.ClickHouseReplicatedMigrations (component, plan) where

import ClickHouseMigrate.Definition (MigrationComponent)
import ClickHouseMigrate.Embed (embedComponent)
import ClickHouseMigrate.Error (PlanError)
import ClickHouseMigrate.Plan (MigrationPlan, migrationPlan)
import Data.List.NonEmpty (NonEmpty (..))

component :: MigrationComponent
component = $(embedComponent "migrations/clickhouse-replicated/manifest.json")

plan :: Either PlanError MigrationPlan
plan = migrationPlan (component :| [])
