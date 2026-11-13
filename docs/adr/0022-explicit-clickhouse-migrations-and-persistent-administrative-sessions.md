---
type: Architecture Decision Record
title: Explicit ClickHouse migrations and persistent administrative sessions
description: Embed immutable native migration steps, bind administration to retained target identities, and preserve traffic fences and exact uncertain receipts until explicit recovery.
docId: ADR-22
status: Accepted
date: 2026-10-16
timestamp: 2026-11-13T23:03:51Z
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

This is an incremental implementation under ExecPlan 50. Job-bound evidence consumption and sufficiency enforcement are implemented.
Upstream repair qualification and integrated backup/platform acceptance remain
open; the completed shared-server guarantee is not yet established.

Supplementary process observations are not proof of drain. Portable data jobs
record visible writes, no visible writes or unavailable observation separately;
visible writes contradict the attestation and prevent discovery. Denied reads do
not become zero-count observations. Run optional diagnostic exchanges on separate
native connections, because a rejected exchange must not compromise the connection
used for subsequent maintenance. Appended PostgreSQL migration 0012 retains each
accepted data-job attempt's envelope, exact file digest and observations. Consumers
recheck accepted evidence expiry after acquiring exclusion before native entry.

Migration sessions also retain each consumed entry's complete audit document in
`kansoku.clickhouse_migration_entry_audit` (appended PostgreSQL migration 0013).
The current session row remains the status view. Counter advancement and audit
insertion share one PostgreSQL statement: a failed audit write rolls back the
marker and prevents native entry. Later entries never replace earlier proof rows.

Owner-bound envelopes are mandatory for native migration mutations, reconciliation,
finish and every unfinished confirmed data-job resume. An initial data confirmation
retains a prepared scope/fence and refuses rather than discovering or changing data.
Dedicated-server procedures produce the same envelope after their owned drain/restart
ceremony; there is no process-list-only fallback. PostgreSQL migration 0014 retains
predecessor entry/attempt timestamps. A drain must follow the previous attempt even
when its counter matches; continuous exclusion may begin earlier. Expiration is
rechecked at native migration SQL callbacks, data-job stages and fence completion.
Refusal diagnostics use fixed messages and never echo untrusted parser content.

## Pre-change recovery sets

Before a pending native suffix or repair, require complete operator-attested backup
coverage of PostgreSQL application/coordination state, analytics and the native
ledger in one stable interval after drain. The bounded manifest binds original
identities, owner, predecessor, compiled-plan and drain digests, applied retention
policy, exact unresolved coordinator state, artifact hashes and verification
receipts. Its PostgreSQL phase is explicitly fenced-before-native-entry; that
snapshot need not contain the later acceptance record. Appended migration 0015
retains acceptance separately from immutable native history.

Validate new input before consuming the predecessor, then retain acceptance under
the administrative lease before native SQL. Incomplete input cannot advance the
counter. Retry authority stays within the same session and compiled plan and still
requires fresh drain. A separately retained fresh-empty exception requires actual
empty-target checks. Neither initialization syntax nor process visibility bypasses
the backup gate. The application validates bindings and attestations; deployment
tools own capture, artifact storage and restore verification.

Direct rebuilt-server adoption is a separate explicit operation. It revalidates
the historical backup/drain boundary against restored PostgreSQL owner and policy
state, requires current new-server drain and a distinct live restore attestation,
and observes qualified native history through the public toolkit. The original
ledger, target and compiled plan remain exact. Under administrator/traffic
exclusion, one compare-and-set statement changes only the active server binding
and retains its old state, complete evidence, recovery set and audit (appended
migration 0016). Counters, uncertain receipts, outcome and fence remain unchanged.
Exact replay returns the retained audit; conflicting input cannot adopt another
target. Normal configuration changes cannot perform this transition. Scratch
inspection grants no adoption authority. Unresolved native work still requires
existing explicit repair with exact receipts and fresh drain. Rebuilt replicated
inventory adoption is refused pending separate qualification; integrated platform
acceptance also remains open.

## Read-only restored-schema inspection

Keep restored-copy inspection separate from live mutation configuration. Explicit
scratch application/ledger names, endpoint/server UUID, original target/ledger,
compiled plan and expected definer are required. Separate credentials and the
public toolkit's Observe API read complete native history without a coordinator
or session. Neither live database name is accepted. A scratch result grants no
migration or adoption authority; a compatible older prefix is not a full pass.

Generate versioned schema expectations from the actual immutable plan on an owned
qualified artifact, embed them in the executable and bind their digest to that
compiled plan and derivation artifact. Compare installed definitions, columns,
defaults/codecs, engine and keys, materialized-view targets and public references;
report unknown extra objects. Map only structural database references and explicit
reviewed definer bindings. Preserve literals and unrelated names. Physical restore
UUIDs do not define logical schema identity. Unsupported representation or missing
visibility refuses full verification.

Retained operational policy is an independent input, never inferred from observed
TTL text. Constrain the supported applied-retention expression and its cutoff,
including its canonical implicit DELETE form, and cross-check the restored policy
relation at native millisecond precision. Ledger agreement and schema agreement
are separate results. Current qualification covers the direct Atomic shape on the
recorded 26.8.28.14 artifact; other shapes require their own reviewed expectations.
The SELECT-only verifier uses readonly=2 because public transport observation sets
synchronous query settings. Fixture capture proves no attempted writes and its
grants independently prohibit temporary-table creation. Inspection never creates
runtime identity-cache tables or changes deployment grants.


## Repair observation retention (2026-11-13)

After initial Hackage 0.2.0.0 integration, select the delivered immutable upstream
source `f4bc4e6d32decfaaf1a19e1033a22f3e28fc167c` across all four packages in Cabal
and Nix. Its package version remains 0.2.0.0; its new API is distinguished by the
source revision. Authoritative registry/tag checks still show 0.2.0.0 as the
latest published release. All 41 extracted-source matrix groups pass across the
three exact server candidates. Package/source and deployment acceptance remain
independent application gates. The upstream work is tracked at
`mori://shinzui/clickhouse-migrate/plans/13-accept-explicit-external-drain-authority-when-repair-process-diagnostics-are-unavailable`.

Select the explicit per-call external-drain API from
`mori://shinzui/clickhouse-migrate` only after validating and retaining the
application's current proof. Its required typed observer persists each diagnostic
through the retained PostgreSQL lease, referencing the exact entry audit. A failed
observation insert aborts before native recovery authorization. Store unavailable
counts as null and report the latest observation with its entry through maintenance
status. Keep the immutable proof and diagnostic rows separate; observations supply
no standing authority. Preserve visible-query refusal and every existing native
identity, history, receipt and exclusion guard.
