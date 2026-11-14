---
type: Architecture Decision Record
title: Fenced resumable administration and applied retention
description: Coordinate cross-store jobs with persisted fences, protect stale writer batches with permanent event dispositions, replay archives transactionally, and rebuild current projections under one applied retention cutoff.
docId: ADR-17
status: Accepted
date: 2026-10-16
timestamp: 2026-11-13T23:55:47Z
generated:
  by: process:codex
  at: 2026-10-16T02:47:59Z
---

# Fenced resumable administration and applied retention

## Context

Raw mutations do not retract aggregate states. A queue batch can remain in memory through
an outage, and an archive can outlive the event it originally delivered. A local output file
cannot atomically record a PostgreSQL resend. Historical migrations recreate obsolete view
shapes, so replaying one during maintenance could silently remove newer enrichment or traits.
[ADR-1](0001-sdk-grade-ingest-contract-boundaries.md) owns logical event acceptance,
[ADR-5](0005-evidence-based-multi-signal-identity-resolution.md) owns identity evidence,
[ADR-13](0013-whole-retained-replay-safe-web-sessions.md) owns retained sessions, and
[ADR-16](0016-governed-current-user-traits-and-replay-safe-erasure.md) owns governed traits.

## Decision

Ship `kansoku-admin` with the server/migration package. The server's issue-key convenience
alias calls the same implementation. List keys returns metadata without hashes or credentials;
revocation takes effect on the next authenticated request. Destructive/data-maintenance commands
preview unless explicitly confirmed. Command failures exit 1 and do not echo SQL or secret values.

Use a persisted global maintenance fence for this initial single-tenant deployment. A confirmed
job owns an administrator advisory lock, persists its identity/fence, then takes the exclusive
traffic lock and waits for admitted operations. Whole protected HTTP operations and each native
writer insert attempt hold shared session locks. New traffic fails with retryable
`maintenance_unavailable`; ingest CORS and operational/public-schema routes remain functional.
Payload acceptance and diagnostic INSERTs also take shared transaction locks on their own
PostgreSQL backend sessions. A caller's cancellation cannot release those locks while its SQL
is still completing; try-lock admission avoids deadlock behind a waiting exclusive job. After
exclusive admission, maintenance requires fresh owner-bound external drain evidence
covering every submitter, schedules and work surviving a disconnected client.
Process observations are supplementary: visible work blocks entry, while a denied
or incomplete empty view cannot establish drain. Native insertion negotiates a sample block
before sending rows, and writer connections explicitly disable asynchronous inserts. A failed
sixty-second drain retains the fence before discovery or mutation.

A bounded twenty-session nonblocking libpq pool admits without waiting, bounds connection
initialization to three seconds, and bounds lock/status/unlock exchanges to 500ms. Failed or
cancelled sessions are disposed. Cleanup must not emit a second HTTP response after success.

PostgreSQL is the authoritative staged job journal. Failure leaves the persisted fence active;
resume repeats incomplete idempotent stages. Random, exclusively created 0600 local receipts
contain the job ID and redacted discovery counts. Full signal discovery remains in the protected
journal while unfinished; completion removes it and reduces the user selector to a digest.
No output filename is derived from a user ID. No cross-store transaction is claimed.

Discover bindings before mutation, including raw mapped values whose fingerprint evidence TTL
has already expired. Scrub implicit cookies, all mapped kinds and session references in matching
raw facts and replayable envelopes. Identity unlinking may retain explicit user IDs and arbitrary
historical JSON. Explicit-fact deletion removes only that account/user's explicit facts; inferred
anonymous facts are scrubbed rather than deleted. Both modes remove governed current traits.

Persist account/event dispositions containing only delete/scrub flags. Merge repeated discoveries
with boolean OR and re-evaluate dispositions on every writer retry, including a pre-fence batch
held in memory. Preserve accepted hashes and reserve legacy event IDs that lack an acceptance
row. Rejected diagnostic payloads never establish bindings or event dispositions: a later valid
producer may reuse a rejected ID. Matching diagnostics are removed independently. Public JSON
cannot impersonate the private envelope merely by containing an event field.

Apply event retention as an explicit snapshot cutoff advanced by `apply-retention`. Canonical
queries and all raw-triggered materialized views enforce that cutoff immediately. Expire older
queue/archive/quarantine payloads, reserve accepted/legacy event identities, delete old raw facts,
and rebuild every derived state while fenced. Physical TTL is cleanup for the applied cutoff,
not the query predicate. Zero/unset event days means unlimited future retention; it cannot
restore payloads already removed. Profiles follow the same event cutoff. Lookup fingerprint
evidence retains its separate 180-day TTL; apply-retention also scrubs expired fingerprint keys
from retained raw/context data and source envelopes, preserves other identifiers, and persists
that applied fingerprint cutoff for future writer attempts. Schedule the explicit command when
periodic advancement is required. New rejected diagnostics still follow their original-payload
and bounded quarantine-retention contract until the next applicable cleanup.

Rebuild the fourteen current projections from their installed materialized-view SELECT definitions
and target columns, substituting canonical raw reads. Clear all targets, replay in dependency
order, wait for mutations and verify the frozen public projection. Do not replay historical
migrations or replace newer rich views. Readers remain fenced through verification and release.

Archive replay selects bounded keyset candidates with row locks and SKIP LOCKED, sends unchanged
stored envelopes, and inserts a unique physical-queue/archive-ID ledger in the same PostgreSQL
transaction. Rollback sends nothing; a crash or output-file failure after commit cannot resend
a ledger-completed row. Respect dispositions and applied retention. Purges use at most 1000 rows
per statement and a bounded per-command total. Minimal acceptance, disposition, trait-erasure
and archive-replay identities remain indefinitely; pruning requires a separate retry-horizon
decision.

## Alternatives considered

A transient process flag leaves other processes and restarts unfenced. A pre-insert status check
has a race with maintenance. Fencing alone cannot sanitize a batch retained in memory. Output
files cannot replace the transactional replay ledger. TTL alone leaves stale rollups. Replaying
old migrations loses newer schema fields. Rejected payloads are not trustworthy binding evidence.

## Consequences

Maintenance stops analytics traffic globally and may require a complete retained-history rebuild.
An operator must resolve failures and resume; no command automatically clears a failed fence.
Other accounts' facts survive account-scoped erasure, while global retention intentionally applies
to every account. Future newly generated events can establish new observations. Backups and
manual database restoration require operator policy, including retained tombstones and cutoffs;
the tool cannot find unknown personal values embedded in arbitrary JSON. Owned source, packaged
CLI and ordinary public workflow acceptance pass, including seven non-skipped administrative
scenario families, backend-lifetime fencing and native old-block replay under retention.

## Native schema administration

[ADR-22](0022-explicit-clickhouse-migrations-and-persistent-administrative-sessions.md)
extends the fence with a separate ClickHouse migration-session foreign key. New and resumed
data jobs refuse that owner, while migration sessions refuse unfinished data jobs. Both share
the existing administrator/traffic locks in the same order. PostgreSQL application migration
0007 replaces transaction admission additively; applied 0004 bytes remain unchanged.

Migration entries preserve target/server/ledger/session identities, predecessor counters,
failed/interrupted outcomes and exact uncertain append receipts. Every mutating successor
requires external client exclusion and complete native drain, even after clean prior entries;
a backend lock release cannot prove that a native request cannot complete or arrive later.
Ordinary up/finish cannot clear failed outcomes merely because history later looks current.
Explicit receipt reconciliation and native repair retain the fence until resolved, current
history and fresh external evidence permit completion. PostgreSQL-only job recovery cannot
clear an unfinished migration session.

## Complete replica coverage for data jobs

Runtime and migration configuration share a strict explicit direct/replicated
selector. A replicated data job binds its cluster and canonical expected UUID set
atomically with fence creation. PostgreSQL migration 0009 appends that identity;
historical data jobs retain a direct-only default. Every resume compares the full
identity before native work and reacquires complete verified connections through
the configured endpoint. Missing, unexpected, replaced or unreachable replicas
cannot shrink the inventory. Native TLS retains endpoint hostname verification;
no system-table hostname redirects the client's connections.

After exclusive traffic admission, maintenance observes raw INSERTs on every
expected replica within one drain budget, synchronizes the Replicated database
schema and reviewed sources, then discovers identity evidence. It submits each
mutation once and consumes relevant replication logs before independently checking
mutation completion on every replica. Failed observations or mutation failures
retain the fence; lack of permission cannot become an empty successful result.
The administrative account must see all Kansoku writer sessions.

Read current materialized-view SELECTs and ordered target columns after schema
synchronization and require matching definitions across replicas. Clear all
fourteen targets before replay, issue each rebuild insert once, and synchronize
each rebuilt dependency before its consumers. Disable block and dependent-view
insert deduplication only on rebuild statements, because a repeated rebuild must
replace rows even when an earlier attempt's block identity survives TRUNCATE.
Interrupted rebuilds restart by clearing every target under the retained fence.

Fresh final synchronization, mutation observations, canonical/public populations
and erasure/retention predicates must cover every expected replica before atomic
completion/release. Saved `rebuilt` and `verified` stages do not authorize release
without fresh checks; identity checks also follow the final checkpoint. The native
resource never silently reconnects one member after a barrier. Each native
statement/barrier is bounded to sixty seconds; a full job can use multiple budgets.
Resume deliberately after repairing the same inventory and privileges. External
SQL writers/readers must be stopped separately because PostgreSQL admission cannot
fence their sessions. Replica-local cache size estimates are not completion proof.
