---
type: Runbook
title: "Administrative operations"
description: "Issue and revoke credentials, inspect rejected events, and preview or resume fenced erasure, retention and archive maintenance."
docId: DOC-1
tags: ["administration", "credentials", "maintenance", "retention"]
generated:
  by: process:codex
  at: "2026-10-16T22:48:56Z"
---

# Administrative operations

`kansoku-admin` ships with the server and migration executables and uses their database and
queue configuration. Apply both migration systems first; [operations](operations.md) describes
them. Normal startup applies neither migrations nor retention policy. Build the packaged CLI
with `nix build .#kansoku-admin`, then use `./result/bin/kansoku-admin --help`.
`nix run .#kansoku-admin -- --help` selects the same administrative executable.

Exit 0 means success or a requested preview; exit 1 means invalid arguments or an operation/
output failure. Data jobs preview unless `--prepare` or `--confirm` is requested; other destructive
commands preview without `--confirm`. Key issuance
is an explicit creation command and displays its token once. Mutation journals cannot restore
deleted payloads. Run commands against the intended database endpoints.

## ClickHouse migration sessions

`kansoku-ch-migrate maintenance begin/status/reconcile/finish` owns explicit native schema
administration. Follow the [migration runbook](clickhouse-migrations.md) for exact arguments,
retained target/server/ledger/session UUIDs, external drain and native repair. Migration sessions
share exclusion with erasure/retention jobs and extend the persistent traffic fence. A new or
resumed data job cannot bypass an active migration session. Neither PostgreSQL-only recovery,
backend death nor a timeout clears an unfinished native session.

Every native mutating entry retains its predecessor counter before submission. Failed or killed
entries require explicit recovery; all exact pending receipts remain visible in maintenance
status and must be supplied to reconciliation/repair. Inspection remains available while fenced.
Only current native history, resolved outcomes and fresh external quiescence evidence permit
completion. Stop external SQL schedules as well; they bypass PostgreSQL traffic admission.

## Credentials

```bash
kansoku-admin issue-key --kind write --account account_123 --description 'browser'
kansoku-admin issue-key --kind service --account account_123 --description 'reporting'
kansoku-admin list-keys --account account_123 --limit 100
kansoku-admin revoke-key --id KEY_UUID
kansoku-admin revoke-key --id KEY_UUID --confirm
```

Listings contain metadata, never hashes or recoverable tokens. Revocation affects the next
authenticated request. Already-revoked IDs succeed; unknown IDs fail. Optional `--account`
constrains the revocation preview. `kansoku-server issue-key` calls the same issuance code.

## Erasure and recovery

```bash
kansoku-admin erase-user --account account_123 --user user_42
kansoku-admin erase-user --account account_123 --user user_42 --prepare
kansoku-admin erase-user --account account_123 --user user_42 --delete-events
kansoku-admin erase-user --account account_123 --user user_42 --delete-events --prepare
```

Use the standard `--user=VALUE` form for user IDs beginning with `--`.

Preview reports scope and counts for raw facts and replayable sources without printing SQL or
discovered identifiers. Live ingest can change counts before confirmation. Default **identity
unlinking** removes matching cookies, mapped identifiers, session links and current traits;
explicit user IDs and arbitrary historical properties/context may remain. `--delete-events`
also removes that account/user's explicit facts. Shared/probabilistic evidence never authorizes
deleting another user's anonymous facts. Other accounts' facts remain unchanged.

Both modes scrub queue/archive envelopes and remove matching quarantine. Rejected payloads do
not establish bindings or reserve event IDs. Accepted hashes and minimal dispositions remain:
equal retries acknowledge the existing logical event without publishing it again. Legacy erased
IDs without a hash conflict. New IDs can establish new observations; this is not a permanent
user ban or a search for unknown personal text embedded in arbitrary JSON.

Preparation persists a job and global fence without discovery or native mutation.
An initial `--confirm` without prepared-owner evidence retains that resumable job and
refuses with instructions to establish external drain. Resume requires an owner-bound
`--drain-evidence` file before discovery or mutation; an empty process list is never
sufficient. Drain earlier native work, including work surviving a cancelled caller,
and retain the procedure proof.
Ingest and metric routes return retryable 503 `maintenance_unavailable`, preserving ingest CORS.
Operational routes and the schema catalog remain available; readiness may report the paused
pipeline. The global window is intentional for the initial single-tenant deployment.

```bash
kansoku-admin list-jobs --limit 20
kansoku-admin job-status --id JOB_UUID
kansoku-admin resume-job --id JOB_UUID
kansoku-admin resume-job --id JOB_UUID --confirm --drain-evidence /secure/current-drain.json
```

Unconfirmed resume returns status. Failed/interrupted jobs keep the fence: resolve the dependency
or schema failure, then resume. Completed resume is idempotent. There is no automatic fence-clear
command. Rebuilds use current projection definitions; do not rerun historical migrations instead.

Executing jobs create random, exclusive 0600 recovery receipts in the temporary directory.
`--out NEW_PATH` chooses a new filename; existing files/symlinks are refused. Receipts contain
the job ID and redacted counts at their checkpoint. PostgreSQL is the authoritative current
stage and full unfinished discovery. Completion removes saved signal discovery and retains a
user digest. The final JSON response reports completion and the receipt path.

## Applied event and fingerprint retention

```bash
KANSOKU_EVENTS_RETENTION_DAYS=90 kansoku-admin apply-retention
KANSOKU_EVENTS_RETENTION_DAYS=90 kansoku-admin apply-retention --prepare
```

This applies a UTC snapshot cutoff at command time minus the configured days. Zero/unset means
unlimited events. Setting the variable alone changes nothing; schedule confirmed commands when
periodic advancement is required. Canonical reports and raw-triggered aggregates enforce the
applied cutoff. The job removes expired raw/replayable payloads, reserves logical identities,
rebuilds all derived states and verifies before releasing the fence. TTL is physical cleanup,
not the query predicate. Crossing sessions use remaining facts, so entry/duration/first-seen
cohorts may change. Profiles follow the event cutoff; expired profiles can remove current traits.

Every confirmed run also applies the separate 180-day fingerprint cleanup, including unlimited
event retention. Preview includes that cutoff and affected counts. Cleanup removes expired
fingerprint keys from raw/context data and existing queue/archive/diagnostic envelopes, preserves
other identifiers, rebuilds identity state and persists the fingerprint cutoff for later writer
attempts. Lookup evidence already expires after 180 days independently. New rejected diagnostics
retain their original-payload contract until their quarantine schedule or a later applicable cleanup.

Acceptance hashes, dispositions, trait-erasure and replay IDs remain indefinitely. Payload expiry
does not expire logical identity. Returning to unlimited retention cannot restore removed payloads.
Backups/manual database restoration need operator policy preserving ledgers/cutoffs and reapplying
erasure; never restore old source payloads into a live writer without that policy.

## Archive replay and purge

```bash
kansoku-admin replay-archive --limit 100 --before 2026-10-01T00:00:00Z
kansoku-admin replay-archive --limit 100 --before 2026-10-01T00:00:00Z --confirm
kansoku-admin replay-archive --after 2026-09-01T00:00:00Z --confirm --out new-replay.json
kansoku-admin purge-archive --before 2026-09-01T00:00:00Z --limit 1000
kansoku-admin purge-archive --before 2026-09-01T00:00:00Z --limit 1000 --confirm
```

`before` is exclusive and `after` inclusive, using archive time. Replay sends unchanged stored
envelopes and records new message IDs in one transaction with row locks and a unique physical-
queue/archive-ID ledger. Concurrent/retried commands cannot resend completed rows. Rollback sends
nothing. An output-file failure after commit can return exit 1: rerun safely and trust the ledger.
Archives remain until purge or retention expiry. Replay respects fences, dispositions and retention;
event idempotency preserves metrics. Limits default to 100, in 1..10000. Purges use at most 1000
rows per statement and stop at the command's total limit; repeat for more rows. No OFFSET is used.

## Rejected event inspection

```bash
kansoku-admin list-rejections --account account_123 --event identify --since 2026-10-01T00:00:00Z --limit 100
kansoku-admin list-rejections --account account_123 --limit 10 --include-payload
kansoku-admin purge-rejections --account account_123
kansoku-admin purge-rejections --account account_123 --confirm
```

Listings default to metadata; `--include-payload` explicitly prints sensitive original objects.
Purge defaults to now minus `KANSOKU_INGEST_QUARANTINE_RETENTION_DAYS`, accepts `--before`, and
uses the same bounded limits. Manual purge complements automatic quarantine expiry/caps; it is
not the automatic retention guarantee.

## Maintenance on a replicated cluster

Use the same `KANSOKU_CH_MIGRATION_CLUSTER` and canonical comma-separated
`KANSOKU_CH_MIGRATION_REPLICA_IDS` for the server, writer and administrative CLI.
Both selectors must be present for replicated operation. Neither selects direct
operation; an empty, partial, malformed or duplicate inventory is rejected.
The native host, TCP port and verified TLS selector remain independent of the
migration HTTP endpoint. A replicated application schema cannot run as direct.

A confirmed data job records its topology, cluster and complete expected UUID set
in the same PostgreSQL transaction that owns the persistent fence. Resume requires
that exact identity. Historical jobs are direct-only. Do not change identities to
make an unavailable replica disappear from a job.

Maintenance retains a native connection to every expected replica through the
configured endpoint. That endpoint must expose the full inventory; an endpoint
pinned to one server fails closed. Kansoku never connects to a hostname returned
by a system table. Each operation checks UUIDs on its retained connections; a
failed connection invalidates the operation. Resume reacquires the full set.

After traffic exclusion, the job drains raw INSERTs on every replica, synchronizes
the database schema and all reviewed source/target tables, and only then discovers
identity evidence. Mutations are submitted once and independently checked on each
replica. Every target is cleared before a dependency-ordered rebuild, with rebuild
insert deduplication disabled for those statements. A retry clears every target
again so an earlier rebuild block cannot suppress replacement rows. Writer
settings remain independent. All replicas must pass fresh final checks even when
the saved stage is `rebuilt` or `verified`.

The administrative account needs SELECT visibility into all Kansoku writer
sessions in `system.processes`, local mutations, table/column/database metadata
and the configured cluster inventory; INSERT, ALTER and TRUNCATE on application
tables; `READ ON REMOTE` for cluster identity verification; and `SYSTEM SYNC
REPLICA` and `SYSTEM SYNC DATABASE REPLICA`. Use
`distributed_ddl_output_mode='none'` for the native command API. Configure system
table access to expose all writer sessions, not a filtered subset. Restricted
observation failures must be repaired, never interpreted as an empty queue.

Replica acquisition is limited to 35 seconds and 64 attempts. Each native barrier
or statement has a 60-second budget; the job can use several budgets. Diagnostics
name nonsecret replica UUIDs and failed stages. A timeout leaves the outcome
uncertain and the fence active. Restore the same replicas and required access,
stop external SQL clients, and resume the original job with the capable binary.
Do not manually advance stages or clear the fence. Do not roll back to a binary
that ignores replicated job identity while such a job is unfinished.

PostgreSQL admission fences cooperating Kansoku traffic. Pause external native
writers and readers explicitly throughout maintenance, including repair/resume;
arbitrary external SQL does not participate in that admission protocol.

## Prepare an externally drained data job

`erase-user` and `apply-retention` accept `--prepare` instead of `--confirm`.
Preparation persists the requested scope and installation-wide fence and returns
`job_id` and `next_attempt` without connecting to ClickHouse or discovering data.
Use `job-status` after a lost response; creating another job is refused while that
fence is active. Native attempts increment the retained counter before opening
ClickHouse, including attempts that fail. This preparation interface supports the
portable drain work in ExecPlan 50. Resume accepts `--drain-evidence FILE` bound
to that job and next attempt. Set the trusted `KANSOKU_CH_MIGRATION_TARGET`,
`KANSOKU_CH_MIGRATION_LEDGER_ID`, `KANSOKU_CH_DRAIN_SERVERS`,
`KANSOKU_CH_DRAIN_SUBMITTERS` and `KANSOKU_CH_DRAIN_AVAILABLE_PRINCIPALS`
configuration independently of the envelope. The three inventory variables are
JSON string arrays. Native server UUIDs are checked against the evidence inventory
before discovery. A failed resumed attempt consumes its counter, so inspect the
new next attempt before producing fresh evidence. Accepted evidence is retained
on the job. The envelope format is documented in the migration runbook. Evidence is mandatory for every unfinished confirmed resume. `drain_not_before`
in job status is the timestamp of the prior attempt; the new drain must follow it.
A missing file is refused before opening ClickHouse, with the fence retained.

Portable attempts retain each accepted envelope and exact input-file digest in
`kansoku.maintenance_drain_attempts`. Supplementary process observations are recorded
separately: visible raw writes block progress; denied/failed observations are
unavailable rather than an empty process list. Valid external evidence supplies
the drain authority in that case. Optional diagnostics use separate connections.
`job-status` exposes `next_attempt` for producing fresh evidence after failure.
