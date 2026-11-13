---
type: Architecture Decision Record
title: Explicit ClickHouse migrations and persistent administrative sessions
description: Embed immutable native migration steps, bind administration to retained target identities, and preserve traffic fences and exact uncertain receipts until explicit recovery.
docId: ADR-22
status: Accepted
date: 2026-10-16
timestamp: 2026-11-13T18:40:00Z
generated:
  by: process:codex
  at: 2026-10-16T22:55:08Z
---

# Explicit ClickHouse migrations and persistent administrative sessions

## Context

The filename-only shell ledger cannot distinguish partial SQL from a lost ledger
acknowledgement. Kansoku has not been deployed, so there is no production history
to import. The [owned acceptance](0010-owned-executable-acceptance-environments.md),
[persistent maintenance](0017-fenced-resumable-administration-and-applied-retention.md)
and [external reader](0018-stable-reader-sql-and-real-consumer-conformance.md)
contracts also apply to native schema changes.

## Decision

Use an exact qualified [core](mori://shinzui/clickhouse-migrate/packages/clickhouse-migrate),
[embedding](mori://shinzui/clickhouse-migrate/packages/clickhouse-migrate-embed) and
[CLI](mori://shinzui/clickhouse-migrate/packages/clickhouse-migrate-cli) cohort in a
separate `kansoku-ch-migrate` executable. Application reads and writes retain their
native driver. Normal startup applies neither store's migrations. PostgreSQL
migrations run first and create additive session coordination state.

The initial cohort came from Hackage `0.1.0.0`. The first Altinity qualification used
`0.1.0.1` at immutable upstream source commit
`00afa9fa1038f2b90e7bc5f041ac1b56649b639f` across all four dependency packages.
Hackage and the upstream release tags were checked; this is a qualified source
candidate, not a claimed registry release. The upstream Nix and seven extracted
source-archive variants each pass both exact server candidates and all thirteen
native groups. Cabal and Nix retain the same source revision; archive/embedding
checks must use that cohort too. Do not locally patch the guard or substitute an
unqualified source revision. Managed endpoint and packaged application acceptance
remain independent deployment gates. Qualification evidence lives in
`mori://shinzui/clickhouse-migrate`, project-relative
`docs/release-evidence/2026-11-02-altinity.md` (artifact URI pending).

The package owns an explicit 25-migration/257-step baseline. Preserve the original
SQL as conversion evidence. Two standalone assertions become explicit
prepare/INSERT-SELECT-check/cleanup steps; one materialization uses the qualified
local synchronous mutation policy. The manifest, original byte ranges and every
adaptation carry exact hashes. Once applied, names, order and SQL bytes are
immutable; subsequent releases append a suffix. Embedding build recipes qualify
inputs by content, including changes with preserved modification times. Source
archives contain those inputs; inspection does not reopen sources at runtime.

Every administrative entry binds an explicit target key, direct endpoint, server
UUID, ledger UUID and persistent PostgreSQL session UUID. Retain the ledger UUID
before the first native submission, including failed initialization. Native history
lives in a separate `kansoku_migration_ledger` Atomic database. Existing application
objects without native history are refused. Legacy adoption and destructive reset
are unsupported; old development data stays under its owner's control.

Migration sessions share administrator lock `(726401,2)` and exclusive traffic
lock `(726401,1)` with data-maintenance jobs, in that order. A separate session
foreign key extends the persistent fence. New and resumed data-maintenance jobs,
Haskell traffic admission and database transaction admission all check both owner
kinds. Temporary backend ownership does not clear a durable fence. Toolkit scope
liveness checks the retained backend's actual exclusive advisory locks.

Before every mutating entry, persist a new predecessor marker. Explicit quiescence
evidence binds the target/session identities and exact preceding entry counter.
The first entry also requires stopping old submitting clients and draining their
native requests. A PostgreSQL lock, elapsed timeout, client death or empty process
list cannot prove that requests have finished or cannot arrive later. Owned proofs
stop their clients and restart their owned native server with its retained data
root; this is an external procedure, not a library guarantee or an automatic
operator action. External SQL schedules must be paused as well.

Persist failed/interrupted outcome state and exact append receipts. Ordinary `up`
and session completion refuse unresolved application outcomes. Repair uses the
public toolkit's position/attempt/step/query validation and requires every retained
receipt. Explicit maintenance reconciliation uses exact-event native observations,
complete history and external drain evidence. A `NotObserved` observation alone
never authorizes mutation. Incompatible or unresolved native history still requires
repair. Native acceptance/finalization send no application SQL; an explicitly
authorized retry can repeat an effect and makes no exactly-once claim.

Only verified current native history under retained exclusion and explicit fresh
predecessor evidence permits session completion. Inspection, errors, process loss
and cleanup failure preserve the fence. Reports and receipts are redacted; any raw
request/effect diagnostics belong in private owned evidence. Preserve primary
native errors even when PostgreSQL outcome recording fails.

The initial proof uses the exact official Darwin/arm64 ClickHouse 26.8.28.14 artifact
from the checked-in qualification matrix. The macOS download self-expands; Nix
expands the hash-verified download in its writable build directory before installing
it. Other platforms fail native execution visibly. Existing Ubuntu acceptance stays
required and blocked on upstream qualification. macOS integration does not select a
deployment platform or qualify Linux. The unknown-cause startup crash, intervening
server patches, actual deployment target and exact production candidate remain
release/deployment gates, recorded in [adoption evidence](../evidence/clickhouse-migrate-adoption.md).
The Kansoku release owner selects the actual target; the upstream toolkit maintainer
qualifies/releases support for required artifacts before Kansoku updates its pin.

## Replicated migration targets

Both direct and replicated paths now use the common `0.1.1.0` source candidate at
`0e75c4cc1303423ba561370ee5795aa0cf2455b7` from
`mori://shinzui/clickhouse-migrate`; this is not a Hackage release claim.
Keep the original direct manifest and bound SQL bytes immutable. A distinct
`kansoku_replicated` component retains the reviewed history with three database
creation steps omitted and 31 persistent engine tokens adapted, preserving
version columns and both Memory assertion groups (25 migrations, 254 steps).
The already-empty 0020 schema inference uses EMPTY AS SELECT because Replicated
databases reject populating CREATE AS SELECT, even when its predicate is false.
The separate backfill remains unchanged; provenance records this single syntax adaptation.
Replicated targets require a fresh v2 ledger in an already-existing Replicated
`kansoku_migration_ledger` database, and an already-existing Replicated `analytics`
database. Never convert a direct ledger in place.

Persist topology and the entire selected identity in PostgreSQL. A direct target
retains one server UUID. A replicated target retains the cluster name and sorted,
unique, nonempty replica UUID array, with no representative server UUID. The
additive 0008 migration preserves old direct sessions, fences, counters and receipts.
Exact topology/cluster/set matching applies before resuming administrative access.

Fresh initialization verifies local observations from every configured replica,
correct database engines, and empty application schema when native history is absent.
Matching initialized history supports recovery without requiring empty tables.
Coverage is bounded by 35 seconds, 64 fresh observations and 64 KiB per response;
missing or unexpected identities fail closed. The configured endpoint must route
fresh connections across the expected inventory. This bound is not service discovery
or certification of an arbitrary managed endpoint. Drain evidence covers all replicas.
General replicated application/data-maintenance and deployment acceptance remain
separate gates under the [implementation plan](../plans/62-run-clickhouse-migrations-on-a-replicated-cluster.md).

## Alternatives considered

Keeping the shell runner alongside native history allows two incompatible ledgers.
Importing undeployed legacy history creates unnecessary recovery obligations.
Transient PostgreSQL exclusion cannot fence native work surviving its backend.
An unconditional cleanup callback cannot attest external drain. Dropping analytics
alone leaves the native ledger current and silently skips schema recreation.
Locally widening the dependency's version allowlist would misrepresent qualification.

## Consequences

Migrations intentionally stop application traffic and require retained identities,
operator evidence and deliberate recovery. Old development stacks must be replaced
with new owned roots, without automatic deletion. Future persistent rollback
restores consistent backups into a separate reviewed target; it does not rewrite
checksums, discard native events or delete only the analytics database. No joint
PostgreSQL/ClickHouse transaction, arbitrary manual-SQL fence, power-loss guarantee
or live deployment follows from this integration.

## Shared runtime identity selectors

The strict cluster/expected-UUID parser now lives in the core topology module and
is shared with runtime configuration. Migration configuration retains its
additional direct server UUID requirement and independent HTTP transport. Data
jobs append their own persisted topology/cluster/canonical inventory identity in
PostgreSQL migration 0009; this does not modify migration session identities, the
0008 schema bytes, either native manifest, or direct/replicated ledger history.
The runtime's native consistency and maintenance contracts are defined by
[ADR-4](0004-queryable-event-properties-and-identity-resolved-projection.md) and
[ADR-17](0017-fenced-resumable-administration-and-applied-retention.md).

## Selected managed deployment scope

Plan 64 selects TAN's one-shard/two-replica Altinity.Cloud target at exact
26.3.60.10002.altinitystable separately from local fixture qualification. Managed
routing, full independent UUID inventory, healthy writable Local default storage,
fsync, permissions and external drain remain deployment obligations. Per-connection
admission fails closed but cannot certify routing, uptime or complete inventory.
The managed endpoint always needs a dated release-owner acceptance; selection,
offline plan smoke and Darwin-client fixture passes cannot supply that decision.
Startup and patch/security dispositions and Linux application-image coverage are
tracked in the [release dossier](../evidence/tan-production-target.md). Existing
direct history and certificate verification remain mandatory.

## Recorded production release disposition

On 2026-11-08 the requesting release owner explicitly approved the four documented
startup, patch/security-source, Linux application-image coverage and managed-endpoint
risks. The [decision record](../evidence/tan-production-release-decision.md) retains
the participant identity, actual approval, UTC date, reasons and immutable candidate
binding. The [qualified artifact](../evidence/tan-production-qualified-artifact.json)
is published and readback verified. Acceptance is target-specific: it does not
certify provider routing or claim full replicated execution inside the amd64 image.
TAN still owns independent production inventory, storage/fsync, grants, drain and
managed migration/event-flow rehearsal. Publication performs no database migration.

## Portable operator drain boundary

The initial portable drain contract lives in `Kansoku.Admin.DrainEvidence` and
binds a bounded versioned operator attestation to the complete expected server
inventory, databases, ledger, owner and predecessor/attempt. Trusted coverage comes
from deployment configuration and retained coordination state, independently of
the document. Parsing does not authenticate external procedures or platform
signatures. Platform control remains outside the application. Migration entries
can retain validated envelopes in their existing audit JSON without rewriting
native receipts or migration history. Preparation of data jobs persists a scope
and fence without connecting to ClickHouse; appended PostgreSQL migration 0011
adds monotonic native-attempt state. Direct and replicated identities retain their
existing semantics.

This is an incremental implementation under ExecPlan 50. Full job-bound evidence
consumption, sufficiency enforcement, upstream repair qualification and integrated
backup/platform acceptance remain open; the initial CLI option does not replace
the dedicated procedure or establish the completed shared-server guarantee.

Supplementary process observations are not proof of drain. Portable data jobs
record visible writes, no visible writes or unavailable observation separately;
visible writes contradict the attestation and prevent discovery. Denied reads do
not become zero-count observations. Run optional diagnostic exchanges on separate
native connections, because a rejected exchange must not compromise the connection
used for subsequent maintenance. Appended PostgreSQL migration 0012 retains each
accepted data-job attempt's envelope, exact file digest and observations. Consumers
recheck accepted evidence expiry after acquiring exclusion before native entry.
