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
  acceptance <- sqlMigration "0003-accepted-events" acceptanceSql
  maintenance <- sqlMigration "0004-maintenance" maintenanceSql
  migrationComponent "kansoku" (Set.singleton "pgmq") (apiKeys :| [rejections, acceptance, maintenance])

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

acceptanceSql :: ByteString
acceptanceSql =
  """
  CREATE TABLE kansoku.accepted_events
  (
      account_id text NOT NULL,
      event_id text NOT NULL,
      producer_payload_hash text NOT NULL CHECK (length(producer_payload_hash) = 64),
      first_accepted_at timestamptz NOT NULL DEFAULT now(),
      erased_at timestamptz,
      PRIMARY KEY (account_id, event_id)
  );
  """

maintenanceSql :: ByteString
maintenanceSql =
  """
  CREATE TABLE kansoku.maintenance_jobs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(), revision bigserial UNIQUE,
    kind text NOT NULL CHECK(kind IN ('erase-user','retention')),
    scope jsonb NOT NULL, discovery jsonb NOT NULL DEFAULT '{}',
    stage text NOT NULL DEFAULT 'created', created_at timestamptz NOT NULL DEFAULT now(),
    completed_at timestamptz
  );
  CREATE TABLE kansoku.maintenance_fence (
    singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),
    active_job uuid REFERENCES kansoku.maintenance_jobs(id)
  );
  INSERT INTO kansoku.maintenance_fence VALUES(true,NULL);
  CREATE TABLE kansoku.retention_policy (
    singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),
    days integer NOT NULL DEFAULT 0 CHECK(days>=0), cutoff timestamptz, fingerprint_cutoff timestamptz, revision bigint NOT NULL DEFAULT 0
  );
  INSERT INTO kansoku.retention_policy(singleton) VALUES(true);
  CREATE TABLE kansoku.event_dispositions (
    account_id text NOT NULL, event_id text NOT NULL,
    delete_event boolean NOT NULL DEFAULT false,
    scrub_identity boolean NOT NULL DEFAULT false,
    scrub_traits boolean NOT NULL DEFAULT false,
    PRIMARY KEY(account_id,event_id)
  );
  CREATE TABLE kansoku.archive_replays (
    queue_name text NOT NULL, archive_id bigint NOT NULL, message_id bigint NOT NULL,
    replayed_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY(queue_name,archive_id)
  );
  CREATE FUNCTION kansoku.apply_event_disposition(body jsonb, scrub_identity boolean, scrub_traits boolean, drop_fingerprint boolean DEFAULT false)
  RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $$
  DECLARE wrapped boolean := body ? 'queueVersion' AND jsonb_typeof(body->'event')='object';
          event jsonb := CASE WHEN wrapped THEN body->'event' ELSE body END;
  BEGIN
    IF coalesce(scrub_identity,false) THEN
      event := event - 'anonymousId' - 'identifiers' - 'sessionId';
      IF event->>'eventName'='alias' THEN
        event := jsonb_set(event,'{properties}',coalesce(event->'properties','{}')-'previousId'-'newId');
      END IF;
    END IF;
    IF coalesce(scrub_traits,false) AND event->>'eventName' IN ('identify','identify_once') THEN
      event := jsonb_set(event,'{properties}','{}');
      IF wrapped AND body->>'queueVersion'='2' THEN body := jsonb_set(body,'{traitsEligible}','false'); END IF;
    END IF;
    IF coalesce(drop_fingerprint,false) AND jsonb_typeof(event->'identifiers')='object' THEN
      event := jsonb_set(event,'{identifiers}',(event->'identifiers')-'fingerprint');
    END IF;
    RETURN CASE WHEN wrapped THEN jsonb_set(body,'{event}',event) ELSE event END;
  END $$;
  CREATE FUNCTION kansoku.event_body(body jsonb) RETURNS jsonb
  LANGUAGE sql IMMUTABLE AS $$ SELECT CASE WHEN body ? 'queueVersion' AND jsonb_typeof(body->'event')='object' THEN body->'event' ELSE body END $$;
  CREATE FUNCTION kansoku.event_time(body jsonb) RETURNS timestamptz LANGUAGE plpgsql STABLE AS $$
  BEGIN RETURN (kansoku.event_body(body)->>'occurredAt')::timestamptz;
  EXCEPTION WHEN OTHERS THEN RETURN NULL; END $$;
  CREATE FUNCTION kansoku.matches_erasure(body jsonb, scope jsonb) RETURNS boolean
  LANGUAGE sql IMMUTABLE AS $$
    SELECT coalesce(e->>'accountId','')=scope->>'account' AND (
      e->>'userId'=scope->>'user' OR (coalesce(e->>'userId','')='' AND (
        (coalesce(e->>'anonymousId','')<>'' AND coalesce(scope->'cookies','[]') ? (e->>'anonymousId'))
        OR (coalesce(e->>'sessionId','')<>'' AND coalesce(scope->'sessions','[]') @> jsonb_build_array(jsonb_build_array(coalesce(e->>'sourceService',''),e->>'sessionId')))
        OR EXISTS (SELECT 1 FROM jsonb_each_text(CASE WHEN jsonb_typeof(e->'identifiers')='object' THEN e->'identifiers' ELSE '{}' END) kv
          WHERE coalesce(scope->'signals','[]') @> jsonb_build_array(jsonb_build_array(kv.key,kv.value)))
      ))) FROM (SELECT kansoku.event_body(body) e) source;
  $$;
  """
