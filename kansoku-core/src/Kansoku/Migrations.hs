-- | The PostgreSQL migration plan owned by Kansoku.
module Kansoku.Migrations
  ( MigrationPlanError (..),
    kansokuMigrationPlan,
  )
where

import Data.Bifunctor (first)
import Database.PostgreSQL.Migrate
  ( DefinitionError,
    MigrationPlan,
    PlanError,
    migrationPlan,
  )
import Kansoku.Prelude
import Pgmq.Migration qualified as Pgmq

-- | A failure to construct the application plan before connecting to PostgreSQL.
data MigrationPlanError
  = PgmqMigrationDefinitionError !DefinitionError
  | KansokuMigrationPlanError !PlanError
  deriving stock (Eq, Show)

-- | Kansoku currently owns only the PGMQ schema component.
kansokuMigrationPlan :: Either MigrationPlanError MigrationPlan
kansokuMigrationPlan = do
  pgmq <- first PgmqMigrationDefinitionError Pgmq.pgmqMigrations
  first KansokuMigrationPlanError (migrationPlan (pgmq :| []))
