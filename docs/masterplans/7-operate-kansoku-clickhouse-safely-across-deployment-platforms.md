---
id: 7
slug: operate-kansoku-clickhouse-safely-across-deployment-platforms
title: "Operate Kansoku ClickHouse safely across deployment platforms"
kind: master-plan
created_at: 2026-11-03T15:41:55Z
provenance:
  created_by:
    model: "gpt-6.1-sol"
    harness: "codex-cli"
    at: 2026-11-03T15:41:55Z
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-11-04T05:38:58Z
      verdict: "changes-requested"
      note: "Toolkit pin is only in cabal.project, coordinator schema is the embedded plan in Kansoku/Migrations.hs, shared CLI parser and acceptance harness lacked owners; decomposition and dependencies sound"
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-11-04T05:38:58Z
      mode: "update"
      note: "Corrected toolkit pin location and coordinator schema location; added shared parser/harness ownership and local-checkout lag discovery"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-13T18:06:03Z
      mode: "implement"
      note: "Started EP-50 and recorded unmet Mori dependency-discovery prerequisite"
---

# Operate Kansoku ClickHouse safely across deployment platforms

This MasterPlan is a living document. Keep Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective current. Child plans own implementation
milestones; the registry below owns their status.


## Vision & Scope

Deliver [IR-2](../improvement-requests/operate-the-clickhouse-schema-on-a-shared-server.md):
an operator can migrate, retain or erase Kansoku data, take a consistent recovery
backup, and verify a restored copy while unrelated applications continue using the
same ClickHouse server. Kansoku must work with documented app-scoped credentials
and cannot require access to other applications' queries.

Kansoku defines the maintenance guarantees and accepts deployment-produced evidence.
The deployment supplies client exclusion, drain, backup and restore mechanisms.
Nagare is a concrete integration, not a runtime dependency, mandatory control plane,
or default configuration. A dedicated self-managed deployment may retain the
stop-clients-and-restart procedure. A shared deployment must establish equivalent
Kansoku-only exclusion without restarting the shared server. A deployment that
cannot establish these guarantees gets an explanatory refusal, not an unsafe bypass.

A **fence** is persistent PostgreSQL state that blocks cooperating Kansoku traffic.
**Drain evidence** records how earlier native requests finished and how later requests
from old clients are prevented. Both are required: a native request may outlive its
client's PostgreSQL backend. The platform may observe or end Kansoku sessions with
its own administrative authority; Kansoku application users need no cross-user
process visibility. Read schedules and other clients using the migration credential
must be excluded too, while the active migrator remains usable.

The target ceremony is: persist the fence; stop submitters and pause conflicting
schedules; establish app-scoped drain; take PostgreSQL and both ClickHouse database
backups within one stable window; record the recovery set; migrate; verify; establish
fresh predecessor drain; finish the session; resume runtime and external schedules.
The backup set contains PostgreSQL coordination/application state, `analytics`, and
`kansoku_migration_ledger`. A pair of platform receipts may package all three, but
coverage must be explicit. Close timestamps alone never prove a common recovery point.

The initiative includes read-only schema and ledger verification under explicit
scratch database names and a controlled identity re-bind after a rebuilt restore.
It does not rename live databases, change applied migration SQL or hashes, remove
the identity cache's temporary Join tables, loosen exact server qualification,
introduce cross-store transactions, automate production restore, or turn Kansoku
into a general deployment or backup service. An account inside Kansoku is not the
shared-server isolation boundary: the boundary here is the whole Kansoku installation.


## Context and decision constraints

[ADR-17](../adr/0017-fenced-resumable-administration-and-applied-retention.md) requires
persistent fences, resumable data jobs and retention/erasure correctness.
[ADR-22](../adr/0022-explicit-clickhouse-migrations-and-persistent-administrative-sessions.md)
requires immutable migrations, retained target/server/ledger/session identities,
fresh predecessor counters and explicit resolution of uncertain receipts. This plan
preserves those guarantees while adding alternative ways to establish external drain.
[ADR-18](../adr/0018-stable-reader-sql-and-real-consumer-conformance.md) explains why
direct SQL readers bypass the PostgreSQL fence and why definer privileges must survive
quiescence. [ADR-10](../adr/0010-owned-executable-acceptance-environments.md) requires
owned, non-skipping executable acceptance. [ADR-23](../adr/0023-verified-tls-for-native-clickhouse-connections.md)
keeps transport configuration independent of migration qualification.

The originating IR describes October 19 assumptions. On November 3, Mori and the
source records report both
`mori://shinzui/nagare/okf/improvement-requests/concepts/IR-30` and
`mori://shinzui/nagare/okf/improvement-requests/concepts/IR-31` completed, with a
recorded resolution in Nagare 0.8.0. The inspected parser offers runtime-only
quiescence. This is evidence to start integration, not proof that a deployed Nagare
instance or the Kansoku ceremony satisfies this plan. Nagare-specific acceptance
must verify the actual adopted release, capabilities and evidence.

The toolkit owner is `mori://shinzui/clickhouse-migrate`. Its strict repair API
continues requiring process diagnostics. The delivered source revision
`f4bc4e6d32decfaaf1a19e1033a22f3e28fc167c` adds an explicit external-drain policy
with a required typed observer while preserving active-query refusal and all
ordinary guards. Its 41-group extracted-source qualification passes on all three
exact server candidates. Kansoku selects that complete four-package source cohort
in Cabal and Nix; its 35 packaged and four SDK cases, normal checks and
source/embedding reconstruction pass. There is no vendored/local
library patch or observation-to-drain conversion. Authoritative Hackage metadata
and upstream tags checked on 2026-11-13 still identify 0.2.0.0 as the latest
published release. The selected snapshot retains that numeric package version;
its immutable revision distinguishes the new API. The original 0.1.0.1 planning
pin and initial Hackage 0.2.0.0 integration are historical selections.



## Decomposition Strategy

Four workstreams separate independent safety concerns. EP-50 owns exclusion and the
shared evidence contract. EP-51 uses that contract for recoverable backups and server
identity recovery. EP-52 supplies independent read-only restore inspection. EP-53
joins them into deployment procedures and executable shared-server acceptance.

Combining all work into one plan would hide the distinction between evidence of drain,
evidence of recoverability, and inspection of restored content. Splitting one plan
per provider would duplicate safety policy. Backup and identity recovery stay together
because the retained backup set is the authority for accepting a rebuilt target.
Documentation is delivered with each behavior; EP-53 owns the integrated ceremony,
privilege inventory and platform-specific instructions.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 50 | Accept portable drain evidence without cross-user process visibility | [ExecPlan](../plans/50-accept-portable-drain-evidence-without-cross-user-process-visibility.md) | None | None | Complete |
| 51 | Establish consistent maintenance backups and restored-server identity recovery | [ExecPlan](../plans/51-establish-consistent-maintenance-backups-and-restored-server-identity-recovery.md) | EP-50 M1: accepted evidence contract and owner binding | EP-52 for early restored-copy roundtrip | Complete |
| 52 | Verify renamed ClickHouse restores without writes | [ExecPlan](../plans/52-verify-renamed-clickhouse-restores-without-writes.md) | None | EP-51 recovery-set manifest | Complete |
| 53 | Prove shared-server maintenance across deployment platforms | [ExecPlan](../plans/53-prove-shared-server-maintenance-across-deployment-platforms.md) | EP-50; EP-51; EP-52, all Complete | None | Not Started |

Status values are Not Started, In Progress, Complete, and Cancelled. A whole-child
hard dependency requires completion; the EP-50 M1 dependency explicitly requires only
its accepted contract, validators and producer/consumer proof, not all of EP-50.


## Dependency Graph

Start EP-50 M1 with a real owned producer/consumer check: runtime logins are blocked,
old native work drains, the migrator still connects, and its evidence binds the exact
persisted owner and predecessor. Do not expand evidence adapters before this passes.
EP-51 may then begin. EP-52 can proceed independently against an owned restored fixture.
Default execution order is EP-50, EP-51, EP-52, EP-53; this ordering needs no delegation.

Within EP-51 M2, exercise one PostgreSQL plus two-ClickHouse backup/restore set before
adding recovery variants. EP-52 supplies the richer verifier when available; it is a
soft dependency because EP-51 can prove backup coverage through independent owned
observations without that command. EP-53 begins only after the first three children
are Complete and owns final cross-plan and Nagare integration acceptance.

The Nagare requests are platform-specific prerequisites, not hard dependencies for
portable code or non-Nagare acceptance. Unavailable Nagare infrastructure must remain
an explicit unpassed integration gate. Generic success alone does not close IR-2's
originating Nagare use case. Toolkit changes have their own upstream delivery gate
inside EP-50; other ready work can continue without silently accepting that gate.


## Integration Points

**Evidence and owner identity — EP-50 owns, EP-51 and EP-53 consume.** Add a bounded,
versioned evidence record and validation in the Kansoku administrative boundary.
It identifies the deployment procedure and retained evidence reference/digest, target,
server and ledger, covered databases/users, the active session plus predecessor or
active data-job plus attempt, and the interval in which exclusion remains in force.
It records what was blocked/drained and which maintenance/backup principals remain
available. An operator attestation is explicit; parsing JSON does not authenticate a
platform receipt or prove the external procedure occurred. No Nagare subprocess or
cluster credential belongs in core runtime code. Nagare receipts are mapped to this
contract by the operator procedure and retained with it.

**Administration and persistence — EP-50 owns drain changes.**
`kansoku-core/src/Kansoku/Admin/Jobs.hs`, `Admin/Coordination.hs`, and
`kansoku-server/src/Kansoku/ClickHouseMigration/Command.hs` enforce their existing
owner kinds. A data job needs a prepared identity before job-bound external evidence
can be produced. Preserve mutual exclusion between jobs and migration sessions.
Coordinator schema lives in `kansoku-core/src/Kansoku/Migrations.hs` as an ordered
embedded plan; there is no PostgreSQL migration directory. Add coordinator changes as
new appended steps there and never edit applied ones. EP-50 appends first; EP-51's
backup-requirement and re-bind audit steps follow EP-50's, which its hard dependency
on EP-50 M1 already orders.

**Shared CLI parser and acceptance harness — EP-50 owns shared changes.**
`kansoku-server/src/Kansoku/ClickHouseMigration/Command.hs` gains evidence threading
from EP-50, `--recovery-set` and `maintenance rebind` from EP-51, and `verify-restored`
from EP-52. EP-52 runs in parallel with the other two, so it adds an isolated sibling
subcommand and does not alter the `--predecessor` option or the `maintenance` group.
`scripts/clickhouse_migrations_acceptance.py` is extended by EP-50, EP-51 and EP-52;
each child adds its own scenario function, and shared fixture helpers change only in
EP-50 while it is active.

**Recovery set — EP-51 owns, EP-52 and EP-53 consume.** A retained manifest binds the
three database snapshots to one fenced/quiesced interval, checksums/receipts, original
identities, compiled-plan digest and unresolved recovery state. Coordinator bookkeeping
may evolve after the PostgreSQL snapshot; the manifest must name that boundary and
retain external evidence needed to reconcile it. Background data-changing work must
be settled or excluded using app-scoped controls or the qualified backup mechanism.
No server-wide pause is required of the application role. The first actual migration
step cannot start until the recovery set is complete and accepted.

**Restore mapping and identity — EP-52 owns inspection, EP-51 owns adoption.** A
separate inspection command takes explicit observed endpoint/server UUID, original
ledger/target expectations, and scratch application/ledger database names. It never
changes the live configuration or restores trust automatically. It reports ledger
compatibility and actual schema agreement separately. EP-51's re-bind consumes those
results plus backup provenance and updates only explicit target/session binding state
with retained audit; migration history and original receipts remain unchanged.
EP-51 supplies retained policy expectations for legitimate operational schema changes,
including the applied-retention TTL; EP-52 validates constrained expressions against
that evidence rather than treating all divergence from a fresh install as drift.

**Privileges — EP-53 owns inventory, every child supplies observed needs.** Distinguish
runtime, migrator, data administrator, restore verifier and deployment operator roles.
List exact statements/objects and verified engine-scoped system metadata needs.
Application credentials receive no blanket cross-user process visibility, access
management or query-kill powers. Preserve definer grants and verify actual runtime
identity-cache queries and data-admin mutations under the declared set.

**Acceptance and documentation — EP-53 owns the joined proof.** Extend existing owned
harnesses, add a required shared-server recipe, and keep dedicated-server acceptance.
Guides describe a portable ceremony first and a Nagare mapping separately. Update
ADRs 17/22 for the changed durable contract when implemented; preserve ADR-18's
external-reader responsibilities and ADR-23's transport boundaries. At completion,
strictly validate changed OKF bundles, distill decisions into ADRs, and update IR-2's
resolution with real evidence rather than this plan's existence.


## Acceptance and IR traceability

| IR criterion | Owner and required observation |
|---|---|
| AC-1 | EP-50 plus EP-53: real Kansoku migration session accepts app-scoped evidence, runtime is blocked, migrator remains available, another app queries throughout, server process start time stays unchanged. |
| AC-2 | EP-50 plus EP-53: retention, erasure and toolkit repair have no cross-user visibility dependency; own-user and denied observations either work under sufficient evidence or clearly refuse while preserving the fence. Empty hidden results never establish drain. |
| AC-3 | EP-51 plus EP-53: manifest explicitly covers PostgreSQL and both ClickHouse databases, all snapshots occur after fence/drain and complete before migration, restoration demonstrates a common logical recovery point. |
| AC-4 | EP-52 plus EP-53: renamed scratch databases on the live fixture's server verify ledger and actual schema read-only; missing objects or changed schema fail; live databases stay untouched. |
| AC-5 | EP-51 plus EP-53: exact per-role grants suffice in a native run; a rebuilt-server restore is re-bound deliberately and works, while unapproved/wrong-target changes fail. |

The integrated matrix covers a dedicated server, a non-Nagare shared server, and Nagare.
Dedicated restart proof is retained. Shared-server proof excludes restart and uses a
second app's long query plus repeated fresh queries as sentinels. Required cases fail
if missing or skipped; live production endpoints are never acceptance fixtures.


## Progress

EP-50, EP-51 and EP-52 are Complete on 2026-11-13. EP-50 delivers owner-bound
portable drain, fresh-entry enforcement and separately retained repair observations.
Its upstream prerequisite is delivered and all 41 extracted-source server groups
pass; Kansoku adopts that exact complete source cohort. The final 35-case packaged
harness, four SDK cases, normal checks and embedding/ten-package source reconstruction
pass, including denied/own-user repair, audit-write refusal, clean/interrupted
whole-store restore/re-bind and renamed read-only verification. Earlier administration
and two-replica maintenance evidence remains recorded in EP-50.

EP-53 is now eligible and owns the integrated generic shared-server ceremony,
exact privilege inventory and actual owned Nagare proof. Final platform acceptance
and IR closure remain open. Toolkit/component success does not substitute for those
integrated gates.



## Surprises & Discoveries

On 2026-11-03, the originating request's Nagare 0.7.0 limitations were found to have
upstream resolution records in 0.8.0. Read those records and actual adopted behavior
before prescribing platform work again. The inspected parser supports `--users runtime`,
which addresses the requirement to leave the migration principal available.

Current `verify` checks migration history, not equality of the installed schema.
Renaming configuration alone cannot deliver AC-4: embedded SQL contains fixed database
references and must remain immutable. EP-52 therefore owns a distinct read-only schema
inspection and namespace-mapping boundary.

MasterPlan 6 reserved uncreated ExecPlan numbers 50–53. Its provisional references
were changed to named lake workstreams without altering its scope, so script-assigned
IDs for this initiative have one meaning in the repository.

On 2026-11-03, the review found that the local Mori checkout of
`mori://shinzui/clickhouse-migrate` is at the 0.1.0.0 release and does not contain the
commit `00afa9fa` that `cabal.project` pins for 0.1.0.1. EP-50 M3 and EP-52 M1 inspect
the toolkit's repair and inspection APIs; they must read the pinned commit, not the
local checkout's HEAD. The Nagare checkout carries tags through v0.11.0, so "the
adopted release" in EP-53 is a deliberate choice at or above 0.8.0, and its
`nagarectl` quiesce option is `--users` with default `runtime`.

Kansoku's PostgreSQL coordinator schema is an embedded ordered plan in
`kansoku-core/src/Kansoku/Migrations.hs`; `kansoku-server/migrations/` holds only the
ClickHouse plan. The children originally pointed at a PostgreSQL migration directory
that does not exist.


## Decision Log

On 2026-11-03, make the maintenance contract platform independent and make Nagare a
conformance integration. The user's deployment question establishes that installations
outside Nagare are first-class consumers. Platform evidence mechanisms may differ;
the required safety guarantees do not.

On 2026-11-03, separate restored-copy inspection from mutating target configuration.
This permits scratch names without changing immutable migration SQL or creating an
alternate path for live mutations.

On 2026-11-03, retain four functional children and place final privilege/platform proof
in EP-53. Changes to drain, recovery provenance and schema inspection can be verified
individually; their combined release claim needs one explicit owner.

Revision note, 2026-11-03: a review against the working tree corrected the toolkit pin
location, named `Kansoku/Migrations.hs` as the coordinator schema plan, added shared
ownership for the migration CLI parser and the migration acceptance harness, and
recorded the lagging local toolkit checkout. Scope, children and dependencies are
unchanged.


## Outcomes & Retrospective
