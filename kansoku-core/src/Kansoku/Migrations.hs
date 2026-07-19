-- | The PostgreSQL migration plan owned by Kansoku.
module Kansoku.Migrations
  ( MigrationPlanError (..),
    kansokuApplicationMigrations,
    kansokuMigrationPlan,
  )
where

import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.Set qualified as Set
import Database.PostgreSQL.Migrate
  ( DefinitionError,
    MigrationComponent,
    MigrationPlan,
    PlanError,
    migrationComponent,
    migrationPlan,
    sqlMigration,
  )
import Kansoku.Prelude
import Pgmq.Migration qualified as Pgmq

-- | A failure to construct the application plan before connecting to PostgreSQL.
data MigrationPlanError
  = PgmqMigrationDefinitionError !DefinitionError
  | KansokuMigrationDefinitionError !DefinitionError
  | KansokuMigrationPlanError !PlanError
  deriving stock (Eq, Show)

-- | Application-owned PostgreSQL schema, ordered after the PGMQ component.
kansokuApplicationMigrations :: Either DefinitionError MigrationComponent
kansokuApplicationMigrations = do
  apiKeys <- sqlMigration "0001-api-keys" apiKeysSql
  migrationComponent "kansoku" (Set.singleton "pgmq") (apiKeys :| [])

apiKeysSql :: ByteString
apiKeysSql =
  """
  CREATE SCHEMA IF NOT EXISTS kansoku;

  CREATE TABLE kansoku.api_keys
  (
      id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      kind        text NOT NULL CHECK (kind IN ('write_key', 'service_token')),
      token_hash  text NOT NULL UNIQUE,
      account_id  text NOT NULL,
      description text NOT NULL DEFAULT '',
      created_at  timestamptz NOT NULL DEFAULT now(),
      revoked_at  timestamptz
  );

  CREATE INDEX api_keys_account_idx
      ON kansoku.api_keys (account_id);
  """

-- | The complete explicit administrative migration plan.
kansokuMigrationPlan :: Either MigrationPlanError MigrationPlan
kansokuMigrationPlan = do
  pgmq <- first PgmqMigrationDefinitionError Pgmq.pgmqMigrations
  application <- first KansokuMigrationDefinitionError kansokuApplicationMigrations
  first KansokuMigrationPlanError (migrationPlan (pgmq :| [application]))
