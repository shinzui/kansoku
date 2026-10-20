---
type: Improvement Request
title: Create the ingest queue in migrations so the server runs with a DML-only PostgreSQL role
description: Move PGMQ queue creation from kansoku-server startup into kansoku-migrate, make startup only verify the queue, and document which role each binary uses, so Kansoku runs on a managed PostgreSQL app database whose runtime role has no DDL rights.
generated:
  by: process:claude-code
  at: "2026-10-19T17:02:45Z"
requestId: IR-1
status: withdrawn
resolution: >-
  Withdrawn by the requesting operator on 2026-10-20. The DML-only PostgreSQL runtime was an
  addition of the requesting plan, not an operator requirement, and creating the PGMQ queue
  at startup with provisionQueue is the pattern every project follows. The platform will
  instead let an app declare extra runtime privileges inside its own database
  (mori://shinzui/nagare/okf/improvement-requests/concepts/IR-35); a local PostgreSQL 18.6
  rehearsal showed Kansoku 9127c47's unchanged server creating its queue as the runtime with
  CREATE on schema pgmq. No Kansoku change is needed.
origin: mori://tan/tan-ng-labs/plans/2-deploy-kansoku-to-the-intranet-as-a-shared-analytics-service-for-nagare-apps
dependencies:
  - ref: mori://shinzui/nagare/okf/improvement-requests/concepts/IR-30
    kind: soft
    reason: PGMQ's install grants to pg_monitor are drift on Nagare v0.7.0; IR-30 lets the app database declare them, so Kansoku need not revoke them, but the queue change here is independent.
acceptanceCriteria:
  - id: AC-1
    statement: kansoku-migrate up creates the configured ingest queue, owned by the migration role, and is idempotent.
    verification: Run up twice on an empty database and assert pgmq.meta holds the queue once and its q_ and a_ tables and msg_id sequence are owned by the migration role.
  - id: AC-2
    statement: kansoku-server starts, accepts events, runs the writer, and passes readiness when its role holds only CONNECT and TEMPORARY on the database, USAGE on the kansoku and pgmq schemas, SELECT, INSERT, UPDATE and DELETE on tables, USAGE and SELECT on sequences, and EXECUTE on functions, with no CREATE on any schema.
    verification: Run the acceptance suite with the server connected as such a role, granted only through the migration role's default privileges, and assert ingest, write, metrics and /ready succeed with no permission errors.
  - id: AC-3
    statement: If the queue is missing, startup fails fast with a message naming the queue and kansoku-migrate, rather than attempting DDL.
    verification: Start the server against a migrated database whose queue was dropped and assert it exits non-zero with that message and issued no CREATE statement.
  - id: AC-4
    statement: The operations guide states which PostgreSQL role each binary needs (server, kansoku-migrate, kansoku-admin, kansoku-ch-migrate) and each server process's connection footprint.
    verification: Review docs/guides/operations.md for the role table and pool sizes, matching Config defaults.
reviews:
  - kind: model
    reviewer: process:claude-code
    reviewed_at: "2026-10-19T17:02:45Z"
    document_timestamp: "2026-10-19T17:02:45Z"
    scope: content-and-metadata
    outcome: commented
    provider: anthropic
    model: claude-opus-5-5
    effort: unspecified
    context: >-
      Author review against Kansoku 9127c47 source, pgmq-migration 0.6.1.1 and the live
      permission failure on the tan-ng-labs intranet; no independent verification attestation
      is claimed.
---

# Create the ingest queue in migrations so the server runs with a DML-only PostgreSQL role

**Authored by:** a `claude-code` session implementing
`mori://tan/tan-ng-labs/plans/2-deploy-kansoku-to-the-intranet-as-a-shared-analytics-service-for-nagare-apps`
on the `tan-ng-labs` intranet, running Nagare v0.7.0.
**Addressed to:** `shinzui/kansoku` agents.
**Created:** 2026-10-19.

This is one of a set filed together after a full privilege audit of Kansoku against Nagare
v0.7.0. The set is this request and IR-2 in this bundle, plus
`mori://shinzui/nagare/okf/improvement-requests/concepts/IR-30`,
`mori://shinzui/nagare/okf/improvement-requests/concepts/IR-31` and
`mori://shinzui/nagare/okf/improvement-requests/concepts/IR-32`.


## Why

The labs intranet runs Kansoku on a shared PostgreSQL server as a Nagare *app database*. The
database is owned by a migration role, and the server runs as a separate runtime role. The
runtime role holds only CONNECT and TEMPORARY, USAGE on schemas, and default DML, sequence and
EXECUTE privileges on objects the migration role creates. It has no CREATE on any schema.

`kansoku-migrate up` succeeds under the migration role. But `kansoku-server` calls `pgmq.create`
on every start (`app/Main.hs:67` → `kansoku-core/src/Kansoku/Ingest/Queue.hs:40-45`
`provisionQueue`). That fails live with `permission denied for schema pgmq`.

Granting more does not fix it. `pgmq.create` runs `CREATE TABLE IF NOT EXISTS` and
`CREATE INDEX IF NOT EXISTS`. PostgreSQL checks schema CREATE, and then table ownership, before
it considers `IF NOT EXISTS`. So only the owner of the queue tables can call it repeatedly.
Everything else the server does already fits a DML-only role: acceptance, the writer through
`shibuya-pgmq-adapter`, maintenance gates, cohorts, metric definitions, `pgmq.metrics`, and
archive counts.


## Requested change

- **Create the queue in a migration** run by `kansoku-migrate` as the migration role, so its
  tables and sequence are owned by that role and reach the runtime role through default
  privileges. `KANSOKU_QUEUE_NAME` is configurable today. Either pin it, or have a migration
  step or an admin `provision-queue` command create the configured name, and document which.
- **Replace `provisionQueue` with a read-only existence check**, for example
  `to_regclass('pgmq.' || pgmq.format_table_name(name, 'q'))` or a `pgmq.meta` lookup. It
  fails fast when the queue is missing.
- **Document roles.** State the role each binary uses:
  - `kansoku-server`: runtime;
  - `kansoku-migrate`, `kansoku-admin` and `kansoku-ch-migrate` coordination: migration role,
    because the admin jobs update fences, dispositions and archives and use bigserial
    sequences.

  Also document the server's footprint of about 42 PostgreSQL connections per process.
- **Leave the PGMQ install migration unchanged.** It is immutable and checksummed. Nagare IR-30
  covers the `pg_monitor` grants it creates.
