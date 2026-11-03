---
id: 50
slug: accept-portable-drain-evidence-without-cross-user-process-visibility
title: "Accept portable drain evidence without cross-user process visibility"
kind: exec-plan
created_at: 2026-11-03T15:42:12Z
master_plan: "docs/masterplans/7-operate-kansoku-clickhouse-safely-across-deployment-platforms.md"
provenance:
  created_by:
    model: "gpt-6.1-sol"
    harness: "codex-cli"
    at: 2026-11-03T15:42:12Z
---

# Accept portable drain evidence without cross-user process visibility

This ExecPlan is a living document. Keep its living sections current and promote
implemented durable decisions into the relevant ADRs.


## Purpose / Big Picture

An operator can keep other applications online while quiescing Kansoku for native
migrations, retention and erasure. Kansoku accepts evidence from a deployment's
app-scoped controls, including a documented manual procedure, without needing to
read other applications' running queries. Insufficient evidence produces a clear
refusal and leaves the persistent maintenance fence in place.

This delivers IR-2 AC-1 and AC-2's application behavior. It does not implement a
platform login controller or claim Nagare deployment acceptance by itself.


## Progress

- [ ] M1: A bounded portable evidence contract binds an actual maintenance owner and passes a real producer/consumer drain proof while the migration principal remains usable.
- [ ] M2: Migration sessions and prepared/resumed data jobs enforce sufficient evidence; unavailable or restricted process observations never imply drain.
- [ ] M3: Qualified upstream repair behavior and packaged Kansoku acceptance cover denied and own-user process visibility, stale evidence and interrupted requests.


## Surprises & Discoveries


## Decision Log

On 2026-11-03, keep platform control outside Kansoku and bind its retained evidence
at the administrative boundary. A PostgreSQL fence controls cooperating callers;
it cannot itself stop all earlier or delayed ClickHouse requests.

On 2026-11-03, require a prepared data-job identity before external job-bound evidence
is consumed. The existing confirmed job creates its identity immediately before it
executes; that ordering cannot accept evidence naming the job in advance.


## Outcomes & Retrospective


## Context and Orientation

The source request is
[IR-2](../improvement-requests/operate-the-clickhouse-schema-on-a-shared-server.md).
A fence is the durable `kansoku.maintenance_fence` row in PostgreSQL, which identifies
an active data job or native migration session. Drain means earlier requests have
finished and old submitters cannot send further requests. A process list can help
find active work but an empty or inaccessible list does not establish drain.

`kansoku-core/src/Kansoku/Admin/ClickHouse.hs` defines `quiesceRawWrites`, which polls
`system.processes` for raw INSERT text. `kansoku-core/src/Kansoku/Admin/Jobs.hs`
creates, fences and resumes retention/erasure jobs; `executeJob` calls that poll
before discovery. `kansoku-core/src/Kansoku/Admin.hs` owns the administrative CLI.
`kansoku-core/src/Kansoku/Admin/Coordination.hs` owns native session identities,
leases and outcome recording. `kansoku-server/src/Kansoku/ClickHouseMigration/Command.hs`
currently accepts `--quiescent`, `--evidence` references and an exact `--predecessor`.
The counter is incremented before native submission so later operations require
new evidence. `Config.hs` binds target/server/ledger; `Coordinator.hs` adapts the
retained PostgreSQL lease to the toolkit's exclusion interface.

[ADR-17](../adr/0017-fenced-resumable-administration-and-applied-retention.md) requires
resumable data jobs and preserved fences. [ADR-22](../adr/0022-explicit-clickhouse-migrations-and-persistent-administrative-sessions.md)
requires fresh owner-bound evidence before every mutating native entry, exact receipts,
and retained exclusion through completion. [ADR-18](../adr/0018-stable-reader-sql-and-real-consumer-conformance.md)
requires external readers to be paused and definer privileges preserved.
[ADR-10](../adr/0010-owned-executable-acceptance-environments.md) requires owned native
fixtures and non-skipping executable acceptance. These decisions apply together.

The upstream owner is `mori://shinzui/clickhouse-migrate`; the package is
`mori://shinzui/clickhouse-migrate/packages/clickhouse-migrate`. Its repair source
looks up its recorded query IDs even though its comment calls absence diagnostic.
Locate source with Mori before proposing an API. The currently pinned source cohort
is in `cabal.project` and the Nix dependency configuration; do not infer released
support from a local checkout. This plan selects no new package version.

Nagare's request records
`mori://shinzui/nagare/okf/improvement-requests/concepts/IR-30` and
`mori://shinzui/nagare/okf/improvement-requests/concepts/IR-31` report completion.
Its parser supports runtime-only quiescence. Treat that as a candidate evidence
producer, and verify the adopted platform's actual behavior in the final integration.
Kansoku must compile and run without a Nagare CLI, cluster credentials or inventory.


## Plan of Work

### M1: Define and prove owner-bound evidence


Add a shared administrative module, proposed location
`kansoku-core/src/Kansoku/Admin/DrainEvidence.hs`, with a versioned, bounded JSON
input. Proposed CLI option `--drain-evidence FILE` is new work, not existing syntax.
The record binds target key, observed server UUID, ledger UUID where applicable,
application/ledger database names, covered submitter identities, retained procedure
reference and digest, the exclusion interval, and either a native session/predecessor
or a data-job/attempt. It describes which submitters and schedules are blocked,
how running requests and relevant background changes were drained, and which
maintenance/backup principals remain available. Do not put credentials or query
text in it. Reject malformed, oversized, wrong-owner or stale records.

Evidence has an explicit trust boundary: an authorized operator attests the external
procedure and retains its source proofs. Schema validation and a file digest prove
binding/integrity, not the truth of the procedure. No new signing infrastructure is
required. A Nagare JSON export can be retained and mapped into this envelope by an
operator; the core must not parse platform inventory or silently claim to validate
platform signatures. Dedicated restart evidence is another documented producer.

Establish a prepared data-job flow in `Kansoku.Admin`/`Admin.Jobs`: a proposed
`prepare` form for the existing retention/erasure operation persists its scope, job
identity and fence without discovery or ClickHouse mutation, then returns that
identity and next attempt. The operator drains and uses `resume` with matching
evidence. Preserve previews. Existing confirmed commands without sufficient drain
must retain a resumable fenced job and explain how to proceed. Add any durable
attempt/evidence fields in a new PostgreSQL migration, located using the existing
migration tree rather than guessing its next filename. Never edit applied SQL.

Before broad CLI work, prove one real owned flow: fence a job or native session,
block the runtime's new connections using the fixture's operator principal, let/end
its already-running request, pause all other submitters using writable credentials,
and supply the resulting evidence while the migrator still connects. A long query
from another app continues. Invalid owner/attempt and active prior work fail. M1 is
accepted only when this producer/consumer interaction and deterministic validators
pass and the documented envelope is stable enough for the backup consumer.

### M2: Enforce the contract in application maintenance


Thread the accepted evidence through migration `up`, repair, reconciliation and
finish without weakening existing target, lease, predecessor or receipt checks.
Persist its digest/reference with the entry audit. Failed or completed entries do
not create reusable standing authorization. Evidence must still cover current
exclusion at use; the operator keeps runtime blocked through all relevant entries.
Before finish, drain the migration principal's own preceding work and bind fresh
evidence to the new counter. A runtime-only quiesce receipt alone is insufficient
for work previously submitted by a migrator or scheduled backup principal.

Apply the same sufficiency checks before data-job discovery and every resumed native
mutation attempt. Preserve job-stage idempotence, dispositions and maintenance
owner exclusion. A failed resumed attempt needs fresh drain evidence, not a replay
of an old authorization. Expose the prepared/resumable identity in redacted output.

Make process observation explicit: a complete declared writer-user observation may
serve as an additional check under a proven exclusion procedure; visible active work
blocks progress. Permission failure, an incomplete own-user view and an empty result
must never become positive drain evidence. If the record lacks sufficient external
proof, fail with an actionable message identifying the missing coverage. Keep an
explanatory refusal usable under completely denied `system.processes` access.
Do not implement a catch-all exception-to-zero fallback or grant broader access.

### M3: Deliver upstream repair support and package the proof


Use Mori to inspect the upstream repair/public error and evidence APIs, then capture
the required change in `mori://shinzui/clickhouse-migrate`. Its repair must either
use sufficient externally attested exclusion with explicitly unavailable diagnostics
or clearly refuse when evidence/observation is inadequate. Visible active recorded
queries remain blocking. It must not depend on seeing another app's queries.
Track an upstream artifact with its canonical Mori URI once created; do not fabricate
an IR number. This Kansoku plan does not authorize unrelated upstream changes.

Before changing a dependency selection, check authoritative Hackage metadata and
upstream tags, then qualify the selected exact cohort with this repository's native,
embedding and source-archive gates. Retain the existing exact server qualification.
If upstream delivery is pending, leave M3 open with the precise missing behavior;
work on independent children may continue. Do not make a local library patch.

Extend `scripts/clickhouse_coordination_acceptance.py`, `scripts/admin_acceptance.py`
and `scripts/clickhouse_migrations_acceptance.py` with actual packaged entry paths.
Keep dedicated restart fixtures working; add app-scoped fixtures rather than globally
replacing `scripts/native_clickhouse_migrations.py`'s owned restart assumptions.
Update the administration and ClickHouse migration guides and ADRs 17/22 with the
implemented evidence/owner contract, without claiming final platform acceptance.


## Concrete Steps

All commands run from the repository root. Discover dependencies before editing:

```bash
mori registry search clickhouse-migrate
mori registry show shinzui/clickhouse-migrate --full
mori registry docs shinzui/clickhouse-migrate
rg -n 'quiesceRawWrites|executeJob|resumeJob' kansoku-core/src/Kansoku/Admin
rg --files kansoku-server/migrations
nix develop -c just deterministic-test
```

Implement M1 and its representative proof first. Then use existing owned gates:

```bash
nix develop -c just ch-migrations-component
nix develop -c just ch-migrations-acceptance
nix develop -c python3 scripts/admin_acceptance.py
nix develop -c just ch-migrations-source
nix develop -c just check
```

If a dependency cohort changes, the source gate is required in that change; otherwise
run it at the final integrated gate. Expected results include explicit nonzero case
counts, zero failures and zero skipped required cases. A missing native prerequisite
is a failure to accept the milestone, not a successful deterministic substitute.


## Validation and Acceptance

Demonstrate `up` and finish with no server restart and a working migrator while runtime
connections are blocked. Execute retention, erasure and upstream repair in separate
fixtures with process reads denied and limited to a subset of Kansoku users. Sufficient
external evidence permits only the supported safe cases; insufficient coverage exits
nonzero before discovery or native mutation and preserves the fence. Match the refusal
to the missing observation/coverage, not a generic unexpected exception.

Inject an old native INSERT that outlives its client, an active migration query, a
paused-but-running backup, stale predecessor/attempt, wrong server/ledger, and process
permission denial. None may be accepted merely because a query is hidden or absent
from one observation. Kill the CLI after an entry marker is persisted and prove that
fresh evidence and the existing receipt/repair protocol are required on resume.
Another app's active query and fresh connections must succeed throughout shared cases.
Preserve existing retention/erasure facts, rollups and replay-disposition assertions.


## Idempotence and Recovery

Preparation persists one identifiable fenced owner. A lost response is recovered
through status; do not create a replacement job/session. Rejected evidence performs
no application mutation and cannot clear a fence. Evidence is attempt-bound; commands
must never auto-resume runtime or discard receipts on failure. Tests mutate only
fixture-owned stores and stop only recorded processes. Use new owned roots on rerun.

Record Conventional Commits with this plan's `ExecPlan:` and parent `MasterPlan:`
trailers if implementation commits are made; stay on the current branch. Record
material plan revisions using the installed provenance script.


## Interfaces and Dependencies

There are no hard child prerequisites. This plan owns the portable evidence format,
its validators and job/session binding. EP-51 consumes M1's accepted contract through
[its checked-in plan](51-establish-consistent-maintenance-backups-and-restored-server-identity-recovery.md).
EP-53 consumes the completed behavior. Use the existing Aeson and administrative
coordination stack; no platform SDK is required. Toolkit repair is an explicit
upstream delivery/qualification gate, not permission to weaken recovery invariants.
