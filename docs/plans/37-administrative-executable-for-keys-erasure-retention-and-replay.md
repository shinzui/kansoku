---
id: 37
slug: administrative-executable-for-keys-erasure-retention-and-replay
title: "Administrative executable for keys, erasure, retention, and replay"
kind: exec-plan
created_at: 2026-10-15T13:44:34Z
intention: "intention_01m4zwwdrjesytazp5tb39fe3n"
master_plan: "docs/masterplans/5-act-on-rev-1-close-silent-loss-paths-add-metric-filters-and-enrich-web-analytics.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-15T13:44:34Z
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-15T14:24:22Z
      mode: "update"
      note: "Promote beacon route (EP-39), rejection quarantine (EP-29 M4, EP-37 M5) and person properties (EP-40) into scope after owner discussion."
---

# Administrative executable for keys, erasure, retention, and replay

This ExecPlan is a living document. Update its living sections and durable ADRs as work
proceeds. It is a child of
`docs/masterplans/5-act-on-rev-1-close-silent-loss-paths-add-metric-filters-and-enrich-web-analytics.md`
and acts on findings H1, H2, H3, the replay half of B1, and the purge half of the rejection
quarantine added to EP-29 on 2026-10-15, in
`docs/reviews/2026-10-15-architecture-and-feature-set-against-comparable-products.md`.


## Purpose / Big Picture

An operator will run one executable, `kansoku-admin`, for every administrative task that
today requires a hand-written SQL statement: listing and revoking credentials, erasing a
user's identity data with the runbook's safeguards enforced by the tool, applying a raw-event
retention period, and replaying or purging archived queue messages. Each destructive command
previews its effect and requires an explicit confirmation flag.


## Progress

- [ ] M1: `kansoku-admin issue-key`, `list-keys` and `revoke-key` work against PostgreSQL; `kansoku-server issue-key` remains as a documented alias.
- [ ] M2: `kansoku-admin erase-user` performs the runbook's discovery, writes it to a file, previews the mutations, and executes them only with `--confirm`.
- [ ] M3: `kansoku-admin apply-retention` sets or clears the `events_raw` TTL from `KANSOKU_EVENTS_RETENTION_DAYS` idempotently.
- [ ] M4: `kansoku-admin replay-archive` re-enqueues archived messages and records replayed ids; `purge-archive` deletes archived rows older than a given time with confirmation.
- [ ] M5: `kansoku-admin list-rejections` and `purge-rejections` operate on the EP-29 quarantine, the purge honouring `KANSOKU_REJECTION_RETENTION_DAYS` by default.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: One new executable with optparse-applicative subcommands, in the `kansoku-server`
  package next to `kansoku-migrate`, rather than more positional subcommands on
  `kansoku-server`.
  Rationale: `kansoku-server/app/Migrate.hs` already uses optparse-applicative; the server's
  hand-rolled `issue-key` parser does not scale to flags like `--confirm`. The MasterPlan 4
  exclusion of a new configuration framework is respected: the executable reads the same
  environment variables as the server.
  Date: 2026-10-15
- Decision: Retention is a table TTL applied by an explicit command, not at server startup.
  Rationale: Normal startup never migrates or alters schema (operations guide); an explicit
  command keeps that boundary and is auditable.
  Date: 2026-10-15


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Credentials are issued by `kansoku-server issue-key` (`kansoku-server/app/Main.hs`,
`runIssueKey` and `Kansoku.Auth.Issue`), stored hash-only in `kansoku.api_keys`, and revoked
by setting `revoked_at` through an administrative SQL session (`docs/guides/operations.md`,
"Credentials and accounts"; [ADR 3](../adr/0003-api-key-authentication-and-account-scoped-analytics.md)).
The PostgreSQL migration executable is `kansoku-server/app/Migrate.hs`. Identity erasure is
the manual runbook `docs/runbooks/identity-data-deletion.md`: a read-only discovery query,
three `ALTER TABLE … UPDATE` scrubs, an optional `DELETE`, and signal-row deletion, each with
an account predicate that must never be omitted. Raw events have no retention policy; monthly
partitions (`PARTITION BY toYYYYMM(occurred_at)`) make `TTL` cheap. The queue archive is the
PGMQ table `pgmq.a_kansoku_events`; `pgmq-effectful`
(`mori://shinzui/pgmq-hs/packages/pgmq-effectful`) exposes `peekArchivedMessages`,
`lookupArchivedMessage` and `batchSendMessage`. ClickHouse connections for queries use the
pool in `kansoku-core/src/Kansoku/ClickHouse.hs`; the Postgres pool is in
`kansoku-core/src/Kansoku/Postgres.hs`. CLI conventions for this portfolio are in
`mori://shinzui/haskell-jitsurei/docs/cli-overview`. No cross-repository ADR applies.


## Plan of Work

### M1: Key management

Create `kansoku-server/app/Admin.hs` as executable `kansoku-admin` with subcommands.
`issue-key --kind write|service --account <id> --description <text>` reuses
`Kansoku.Auth.Issue`; `list-keys [--account <id>] [--json]` prints id, kind, account,
description, created and revoked timestamps, never hashes; `revoke-key <uuid>` updates
`revoked_at` where null and reports whether exactly one row changed. Keep `kansoku-server
issue-key` delegating to the same function and mark it as an alias in the guide.

### M2: Erasure

`erase-user --account <id> --user <id> [--delete-events] [--out <file>] [--confirm]` runs the
runbook's discovery, writes the distinct signal kinds and values to `--out` (default
`erase-<account>-<user>-<timestamp>.json`), prints each mutation it will submit with the
literal values substituted, and submits them only with `--confirm`. The account predicate is
constructed by the tool, not typed. Mutations are submitted asynchronously, so the command
prints the mutation ids from `system.mutations` for follow-up. Update the runbook to make the
command the primary path and keep the SQL as the fallback. Once
`docs/plans/40-person-properties-set-and-set-once-user-traits.md` has landed, the same command
also deletes the user's rows from `analytics.user_properties` and
`analytics.user_properties_once`; until then it reports that no trait tables exist.

### M3: Retention

`apply-retention` reads `KANSOKU_EVENTS_RETENTION_DAYS` (0 or unset means none) and issues
`ALTER TABLE analytics.events_raw MODIFY TTL toDateTime(occurred_at) + INTERVAL n DAY` or
`REMOVE TTL`, after printing the current TTL from `system.tables`. Document that rollups are
unaffected (they do not read raw rows after insert), that `identity_signals` keeps its
fingerprint-only TTL, and that the change is recorded outside the migration ledger by design.

### M4: Archive replay and purge

`replay-archive [--limit n] [--before <ts>] [--after <ts>] [--out <file>]` peeks archived
messages in id order, re-sends their bodies with `batchSendMessage`, and appends each
archived message id and new message id to `--out`; it relies on the event-id idempotency of
`events_raw` and says so. `purge-archive --before <ts> --confirm` deletes archived rows older
than the time after printing the count. Add both to the operations guide's "ClickHouse
unavailable" recovery section, next to the archive gauge from
`docs/plans/30-pipeline-backpressure-and-storage-outage-resilience.md`.

### M5: Rejection quarantine commands

`list-rejections [--account <id>] [--event <name>] [--since <ts>] [--limit n] [--json]`
reads `kansoku.ingest_rejections` (created by
`docs/plans/29-correct-client-timestamp-skew-and-count-ingest-rejections.md` M4) and prints
received time, event name, schema version, reasons and the payload, so an operator can diff a
producer release against the catalog. `purge-rejections [--before <ts>] --confirm` deletes
rows older than the given time, defaulting to now minus `KANSOKU_REJECTION_RETENTION_DAYS`,
and prints the count first. Document a daily invocation in the operations guide as the
retention mechanism.


## Concrete Steps

```bash
cabal build kansoku-server:exe:kansoku-admin
cabal run kansoku-admin -- list-keys
cabal run kansoku-admin -- erase-user --account dev --user u-1
cabal run kansoku-admin -- erase-user --account dev --user u-1 --confirm
KANSOKU_EVENTS_RETENTION_DAYS=400 cabal run kansoku-admin -- apply-retention
cabal run kansoku-admin -- replay-archive --limit 100
cabal run kansoku-admin -- list-rejections --limit 20
cabal run kansoku-admin -- purge-rejections --confirm
```

Expected: `list-keys` prints a table without secrets; the first `erase-user` prints the plan
and exits 0 without changing data; the second prints mutation ids; `apply-retention` prints
the TTL before and after; `replay-archive` prints the count re-enqueued.


## Validation and Acceptance

1. M1: issuing then revoking a key makes the next authenticated request return 401; revoking
   again reports zero rows and exits non-zero.
2. M2: after erasure on a fixture user, the runbook's discovery query returns no rows and the
   user's events carry empty `identifiers` and `anonymous_id`; without `--confirm` nothing
   changes.
3. M3: `system.tables` shows the TTL expression after apply and none after clearing; an old
   partition's rows disappear after `OPTIMIZE TABLE … FINAL` in a test database.
4. M4: an archived test message is re-enqueued and written exactly once (`count(DISTINCT
   event_id)` unchanged if it already existed), and purge removes only rows before the time.
5. The admin executable builds in the Nix package and is listed in the operations guide.
6. M5: a quarantined fixture rejection is listed with its reasons; purge with a `--before`
   older than it leaves it in place and the default purge after the retention removes it.


## Idempotence and Recovery

Every command previews before acting; `revoke-key`, `apply-retention`, `replay-archive` and
`purge-archive` are safe to re-run. Erasure mutations are irreversible by nature; the tool's
saved discovery file is the audit record. Retention cannot restore deleted partitions; the
guide states that backups are the only recovery.


## Interfaces and Dependencies

Soft dependency on `docs/plans/30-pipeline-backpressure-and-storage-outage-resilience.md`
(archive gauge), `docs/plans/32-time-aware-identity-bindings-and-bounded-resolution-cost.md`
(the `email_hmac` kind must be included in discovery once it exists),
`docs/plans/29-correct-client-timestamp-skew-and-count-ingest-rejections.md` M4 (the
quarantine table M5 reads) and `docs/plans/40-person-properties-set-and-set-once-user-traits.md`
(trait tables in erasure). Claims the
`kansoku-admin` executable name and `KANSOKU_EVENTS_RETENTION_DAYS`. Libraries:
optparse-applicative, hasql, pgmq-effectful, ClickHaskell. A new ADR should record the
administrative boundary: schema changes outside the ledger (TTL), destructive operations
requiring confirmation, and replay relying on idempotency.
