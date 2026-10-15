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
  rejections <- sqlMigration "0002-ingest-rejections" rejectionsSql
  migrationComponent "kansoku" (Set.singleton "pgmq") (apiKeys :| [rejections])

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

rejectionsSql :: ByteString
rejectionsSql =
  """
  CREATE TABLE kansoku.ingest_rejections
  (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      account_id text NOT NULL,
      received_at timestamptz NOT NULL,
      event_name text NOT NULL,
      schema_version bigint,
      reason_codes jsonb NOT NULL,
      payload jsonb NOT NULL,
      transport text NOT NULL CHECK (transport IN ('single', 'batch', 'beacon')),
      payload_truncated boolean NOT NULL,
      original_payload_bytes bigint NOT NULL
  );
  CREATE INDEX ingest_rejections_account_received_idx
      ON kansoku.ingest_rejections (account_id, received_at, id);
  """
