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
  cohorts <- sqlMigration "0005-cohorts" cohortsSql
  definitions <- sqlMigration "0006-metric-definitions" metricDefinitionsSql
  administration <- sqlMigration "0007-clickhouse-administration" clickhouseAdministrationSql
  replicatedAdministration <- sqlMigration "0008-clickhouse-replicated-administration" replicatedAdministrationSql
  replicatedJobs <- sqlMigration "0009-clickhouse-replicated-jobs" replicatedJobsSql
  analyses <- sqlMigration "0010-saved-analyses" analysesSql
  drainAttempts <- sqlMigration "0011-maintenance-drain-attempts" drainAttemptsSql
  drainAudit <- sqlMigration "0012-maintenance-drain-audit" drainAuditSql
  migrationAudit <- sqlMigration "0013-clickhouse-entry-audit" migrationAuditSql
  drainFreshness <- sqlMigration "0014-maintenance-drain-freshness" drainFreshnessSql
  migrationComponent "kansoku" (Set.singleton "pgmq") (apiKeys :| [rejections, acceptance, maintenance, cohorts, definitions, administration, replicatedAdministration, replicatedJobs, analyses, drainAttempts, drainAudit, migrationAudit, drainFreshness])

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
  CREATE FUNCTION kansoku.require_traffic_lock() RETURNS void LANGUAGE plpgsql AS $$
  BEGIN
    IF NOT pg_try_advisory_xact_lock_shared(726401,1)
       OR EXISTS(SELECT 1 FROM kansoku.maintenance_fence WHERE active_job IS NOT NULL) THEN
      RAISE EXCEPTION 'analytics maintenance is active' USING ERRCODE='55000';
    END IF;
  END $$;
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

cohortsSql :: ByteString
cohortsSql =
  """
  CREATE TABLE kansoku.cohorts (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(), account_id text NOT NULL,
    name text NOT NULL, kind text NOT NULL CHECK(kind IN ('behavioural','static')),
    definition jsonb NOT NULL, created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(), UNIQUE(account_id,name)
  );
  CREATE INDEX cohorts_account_id ON kansoku.cohorts(account_id,id);
  """

metricDefinitionsSql :: ByteString
metricDefinitionsSql =
  """
  CREATE TABLE kansoku.metric_definitions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(), account_id text NOT NULL,
    name text NOT NULL, definition jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE(account_id,name)
  );
  CREATE INDEX metric_definitions_account_id ON kansoku.metric_definitions(account_id,id);
  """

-- Separate identity: a migration session is not a data-maintenance job.
clickhouseAdministrationSql :: ByteString
clickhouseAdministrationSql =
  """
  CREATE TABLE kansoku.clickhouse_migration_sessions (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    target_key text NOT NULL, server_id uuid NOT NULL, ledger_id uuid NOT NULL,
    entry bigint NOT NULL DEFAULT 0, pending_entry text NOT NULL DEFAULT 'pre-session-drain',
    audit jsonb NOT NULL, quiescence jsonb,
    outcome text NOT NULL DEFAULT 'pre-session', pending_receipts jsonb NOT NULL DEFAULT '[]',
    created_at timestamptz NOT NULL DEFAULT now(), completed_at timestamptz
  );
  CREATE UNIQUE INDEX clickhouse_single_active_session
    ON kansoku.clickhouse_migration_sessions ((true)) WHERE completed_at IS NULL;
  ALTER TABLE kansoku.maintenance_fence ADD COLUMN active_migration_session uuid
    REFERENCES kansoku.clickhouse_migration_sessions(id);
  ALTER TABLE kansoku.maintenance_fence ADD CONSTRAINT one_administrator_kind
    CHECK (active_job IS NULL OR active_migration_session IS NULL);
  CREATE OR REPLACE FUNCTION kansoku.require_traffic_lock() RETURNS void LANGUAGE plpgsql AS $$
  BEGIN
    IF NOT pg_try_advisory_xact_lock_shared(726401,1)
       OR EXISTS(SELECT 1 FROM kansoku.maintenance_fence
                 WHERE active_job IS NOT NULL OR active_migration_session IS NOT NULL) THEN
      RAISE EXCEPTION 'analytics maintenance is active' USING ERRCODE='55000';
    END IF;
  END $$;
  """

-- Additive: existing fences, receipts, counters and direct UUIDs survive.
replicatedAdministrationSql :: ByteString
replicatedAdministrationSql =
  """
  CREATE FUNCTION kansoku.canonical_replica_ids(ids uuid[]) RETURNS boolean
    LANGUAGE sql IMMUTABLE STRICT AS $$
    SELECT ids = ARRAY(SELECT DISTINCT x FROM unnest(ids) AS x WHERE x IS NOT NULL ORDER BY x)
    $$;
  ALTER TABLE kansoku.clickhouse_migration_sessions
    ALTER COLUMN server_id DROP NOT NULL,
    ADD COLUMN topology text NOT NULL DEFAULT 'direct',
    ADD COLUMN cluster_name text,
    ADD COLUMN replica_ids uuid[] NOT NULL DEFAULT '{}',
    ADD CONSTRAINT clickhouse_session_topology CHECK (
      (topology='direct' AND server_id IS NOT NULL AND cluster_name IS NULL AND replica_ids='{}') OR
      (topology='replicated' AND server_id IS NULL AND cluster_name IS NOT NULL AND length(cluster_name)>0
       AND cardinality(replica_ids)>0 AND kansoku.canonical_replica_ids(replica_ids))
    );
  """

-- Historical jobs retain their direct-only identity. Never adopt a discovered
-- replica subset or silently upgrade an unfinished direct job on resume.
replicatedJobsSql :: ByteString
replicatedJobsSql =
  """
  ALTER TABLE kansoku.maintenance_jobs
    ADD COLUMN target_identity jsonb NOT NULL DEFAULT '{"topology":"direct","cluster":null,"replicas":[]}',
    ADD CONSTRAINT maintenance_job_target_identity CHECK (
      coalesce(jsonb_typeof(target_identity)='object' AND (
        target_identity='{"topology":"direct","cluster":null,"replicas":[]}'::jsonb OR (
          target_identity->>'topology'='replicated'
          AND jsonb_typeof(target_identity->'cluster')='string'
          AND target_identity->>'cluster' ~ '^[a-z_][a-z0-9_-]{0,127}$'
          AND jsonb_typeof(target_identity->'replicas')='array'
          AND jsonb_array_length(target_identity->'replicas') BETWEEN 1 AND 64
        )
      ),false)
    );
  """

analysesSql :: ByteString
analysesSql =
  """
  CREATE TABLE kansoku.analyses (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id text NOT NULL,
    name text NOT NULL CHECK (char_length(name) BETWEEN 1 AND 120),
    description text CHECK (char_length(description) <= 500),
    kind text NOT NULL CHECK (kind IN ('trends','funnel','retention')),
    document_version numeric NOT NULL CHECK (document_version > 0 AND document_version = trunc(document_version) AND document_version <> 'Infinity'::numeric),
    document_text text NOT NULL CHECK (octet_length(document_text) <= 32768),
    revision bigint NOT NULL DEFAULT 1 CHECK (revision > 0),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp()
  );
  CREATE INDEX analyses_account_updated ON kansoku.analyses(account_id,updated_at DESC,id ASC);
  CREATE INDEX analyses_account_kind_updated ON kansoku.analyses(account_id,kind,updated_at DESC,id ASC);
  """

-- Append-only preparation/attempt identity for externally produced evidence.
drainAttemptsSql :: ByteString
drainAttemptsSql =
  """
  ALTER TABLE kansoku.maintenance_jobs
    ADD COLUMN native_attempt bigint NOT NULL DEFAULT 0 CHECK (native_attempt >= 0),
    ADD COLUMN drain_evidence jsonb;
  """

-- Retain accepted proofs per attempt; never overwrite an earlier attempt audit.
drainAuditSql :: ByteString
drainAuditSql =
  """
  CREATE TABLE kansoku.maintenance_drain_attempts (
    job_id uuid NOT NULL REFERENCES kansoku.maintenance_jobs(id),
    attempt bigint NOT NULL CHECK (attempt > 0),
    evidence jsonb NOT NULL,
    evidence_sha256 text NOT NULL CHECK (evidence_sha256 ~ '^[0-9a-f]{64}$'),
    observations jsonb NOT NULL DEFAULT '[]',
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (job_id, attempt)
  );
  """

-- The session row is a current-state view; each consumed proof is retained here.
migrationAuditSql :: ByteString
migrationAuditSql =
  """
  CREATE TABLE kansoku.clickhouse_migration_entry_audit (
    session_id uuid NOT NULL REFERENCES kansoku.clickhouse_migration_sessions(id),
    entry bigint NOT NULL CHECK (entry > 0),
    command text NOT NULL,
    evidence jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (session_id, entry)
  );
  """

-- Each predecessor establishes a new lower bound, including rejected attempts.
drainFreshnessSql :: ByteString
drainFreshnessSql =
  """
  ALTER TABLE kansoku.maintenance_jobs
    ADD COLUMN last_attempt_at timestamptz NOT NULL DEFAULT clock_timestamp();
  ALTER TABLE kansoku.clickhouse_migration_sessions
    ADD COLUMN last_entry_at timestamptz NOT NULL DEFAULT clock_timestamp();
  """
