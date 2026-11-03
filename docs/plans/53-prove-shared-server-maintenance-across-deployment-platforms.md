---
id: 53
slug: prove-shared-server-maintenance-across-deployment-platforms
title: "Prove shared-server maintenance across deployment platforms"
kind: exec-plan
created_at: 2026-11-03T15:42:12Z
master_plan: "docs/masterplans/7-operate-kansoku-clickhouse-safely-across-deployment-platforms.md"
provenance:
  created_by:
    model: "gpt-6.1-sol"
    harness: "codex-cli"
    at: 2026-11-03T15:42:12Z
---

# Prove shared-server maintenance across deployment platforms

This ExecPlan is a living document. Keep its living sections current and promote
implemented durable decisions into the relevant ADRs.


## Purpose / Big Picture

An operator can follow one portable Kansoku maintenance guide and choose a dedicated
server procedure, a generic shared-server procedure, or a Nagare procedure. The exact
privileges needed by each principal are documented and proven. Shared-server tests
show that another app remains available through migration, data maintenance, backup
and restored-copy verification. The originating Nagare deployment is accepted only
after its real capabilities and receipts satisfy the same contract.

This plan joins IR-2 AC-1 through AC-5 and owns the final release evidence. It does
not deploy to production or claim support for unqualified server versions/topologies.


## Progress

- [ ] M1: Exact per-role privileges suffice for runtime, migration, retention/erasure and restored-copy inspection while other apps remain isolated.
- [ ] M2: A required packaged non-Nagare shared-server ceremony proves all five IR criteria, interruption safety and continued availability of a second app; dedicated behavior still passes.
- [ ] M3: Nagare's actual quiesce/backup/restore receipts satisfy the same ceremony in an owned deployment; guides and IR resolution cite the completed evidence.


## Surprises & Discoveries


## Decision Log

On 2026-11-03, require a non-Nagare shared-server proof in addition to Nagare integration.
A core that works only with platform-specific control tools would not satisfy the
user's deployment requirement.

On 2026-11-03, keep the Nagare integration gate visible even after generic tests pass.
Its upstream requests being completed does not prove Kansoku consumed them correctly.


## Outcomes & Retrospective


## Context and Orientation

The source request is
[IR-2](../improvement-requests/operate-the-clickhouse-schema-on-a-shared-server.md).
This child starts only after
[EP-50](50-accept-portable-drain-evidence-without-cross-user-process-visibility.md),
[EP-51](51-establish-consistent-maintenance-backups-and-restored-server-identity-recovery.md)
and [EP-52](52-verify-renamed-clickhouse-restores-without-writes.md) are Complete.
They deliver portable owner-bound drain evidence, complete recovery-set validation
and explicit server re-binding, and read-only renamed-copy verification respectively.
This plan consumes those interfaces; it does not redefine them per deployment.

A runtime principal serves Kansoku requests and writes events. The migration principal
runs native schema changes and remains the definer of public views. A data administrator
runs retention/erasure and coordinator operations. A restore verifier reads scratch
metadata and ledger. A deployment operator manages users, quiescence and backup/restore
facilities outside application code. One installation may bind multiple duties to
a credential, but documentation must show the exact privileges implied by that choice.
Do not give every application principal the deployment operator's authority.

Existing guides are `docs/guides/clickhouse-migrations.md`, `administration.md`,
`operations.md`, `configuration.md` and `consume-clickhouse.md`. Runtime identity-cache
behavior is in `kansoku-core/src/Kansoku/Identity/Cache.hs`; mutation validation is
in `kansoku-core/src/Kansoku/Admin/ClickHouse.hs`. Native migration configuration and
commands live under `kansoku-server/src/Kansoku/ClickHouseMigration/`.
`scripts/clickhouse_migrations_acceptance.py` owns packaged native scenarios,
`scripts/clickhouse_coordination_acceptance.py` covers retained coordination failures,
`scripts/admin_acceptance.py` covers real data jobs, and
`scripts/isolated_clickhouse.py`/`isolated_postgres.py` own disposable stores. `justfile`
and `.github/workflows/check.yml` define required entrypoints and platform gates.

[ADR-10](../adr/0010-owned-executable-acceptance-environments.md) requires fixture ownership,
non-skipping required cases and sanitized evidence.
[ADR-17](../adr/0017-fenced-resumable-administration-and-applied-retention.md) and
[ADR-22](../adr/0022-explicit-clickhouse-migrations-and-persistent-administrative-sessions.md)
require persistent exclusion and explicit interrupted-operation recovery.
[ADR-18](../adr/0018-stable-reader-sql-and-real-consumer-conformance.md) requires correct
definer privileges and pausing direct readers. [ADR-23](../adr/0023-verified-tls-for-native-clickhouse-connections.md)
keeps native transport separate from migration qualification. Preserve their boundaries.

Nagare's canonical prerequisites are
`mori://shinzui/nagare/okf/improvement-requests/concepts/IR-30` and
`mori://shinzui/nagare/okf/improvement-requests/concepts/IR-31`.
Both report completed with resolution in 0.8.0. The local inspected CLI parser supports
`quiesce --users runtime`, on-demand backup, receipt ingestion, resume and evidence.
Discover its current source/docs with Mori and verify the adopted release and actual
commands before producing recipes. This plan does not select a Nagare version or
infer compatibility from request status. The toolkit owner is
`mori://shinzui/clickhouse-migrate`; retain its qualified exact source/server cohort.


## Plan of Work

### M1: Prove the documented privilege inventory


Inventory every statement made by runtime, migrator, data administrator and verifier,
including storage probes, identity-cache `system.parts` reads and temporary `Join`
tables, schema metadata, ledger reads/writes and admin `system.mutations`. Derive
required grants from actual paths, not historical IR line numbers. Distinguish
application/ledger database rights, engine-scoped system metadata, temporary-table
rights and platform operator capabilities. Document exact SQL privileges and object
scope for the qualified engine. Database filters in a query alone do not guarantee
row isolation; prove effective visibility under the actual server settings.

Create fixture roles holding only the documented grants. Run a real metric that
rebuilds identity caches, real writer insertion, native initialization/upgrade,
retention, erasure, repair and renamed verification. Public definer views must work
before quiesce and after resume with underlying definer grants preserved. Runtime
quiescence changes login availability without stripping those grants.

Use separate fixtures for denied process reads and own-user process views, including
an incomplete view that cannot see another Kansoku submitter. Another app's query
text must not be exposed. Restore verifier credentials cannot mutate anything;
application credentials cannot change users or kill other apps' queries. Any platform
operator observations of Kansoku sessions stay in operator evidence, with no other
app's SQL copied into Kansoku reports. Capture the grant set used by each proof.

### M2: Integrate a generic shared-server maintenance proof


Add `scripts/shared_clickhouse_maintenance_acceptance.py` and a proposed required
`just ch-shared-maintenance-acceptance` recipe, reusing existing fixture/process and
packaged-binary helpers. It must create its own PostgreSQL/ClickHouse roots, scoped
users and both apps' databases; reject ambient endpoint overrides. The fixture's
operator controls login/existing-session drain. Only the maintenance subprocess has
Kansoku migration credentials; normal runtime and external schedules are blocked.
Add bounded timeouts, private raw evidence and sanitized result summaries.

Run a second app's long-lived query while also issuing fresh queries throughout
quiesce, backup, migration, retention/erasure and verification. Record the server
process identity/start time before and after each shared ceremony; no restart is
allowed. Verify the second app's data and grants afterward. This proves shared-server
availability under the fixture's workload, not immunity to all resource contention.

Use the real packaged CLI to prepare/fence, produce accepted drain evidence, take
and validate the three-database recovery set, migrate, verify the live current state,
refresh predecessor evidence, finish and resume. Run data jobs through their prepared/
resume path and retain existing erasure/retention assertions. Restore backups into
scratch names on that server and run the read-only verifier. Separately restore an
owned rebuilt server with a new UUID and exercise explicit re-bind and retained
session recovery. Never rebuild the shared availability fixture to claim AC-1.

Fail deliberately after one backup, after a native submission and after re-bind has
committed but before its response. Prove no automatic fence release or runtime resume,
no new-server auto-trust and safe recovery with retained receipts and fresh evidence.
Add a case where a writable external schedule or earlier migration request remains;
runtime-only login blocking must not hide that gap. Ensure the first migration
application step follows completed recovery-set validation, and schema drift with
unchanged history fails restored verification.

Wire this recipe into the qualified native CI gate and required packaged acceptance
without duplicating equivalent long-running fixtures. Keep dedicated restart and
source-archive/embedding qualification intact. Missing prerequisites fail required
mode; a development-only opt-out may report unrun coverage but cannot count as
release evidence. Broaden engine/platform coverage only with explicit qualification.

### M3: Map and execute the Nagare ceremony, then close documentation


Use Mori to read the adopted Nagare quiesce, backup, receipt and scratch-restore
contracts. Map runtime-only quiesce to EP-50 evidence and map PostgreSQL plus both
ClickHouse database receipts to EP-51's complete recovery set. Prove running backup
schedules are paused/drained and that the migration principal remains available.
Account for jobs, readers and manual clients using that principal; a platform receipt
covering only runtime sessions cannot stand in for their drain.

Exercise this mapping on a fresh owned Nagare deployment with two apps. Use reviewed
privilege declarations for system metadata/temporary-table exceptions, not manual
out-of-band grants. Run the actual Kansoku ceremony and restored-copy verification,
observe the other app's long/fresh queries, and retain accepted receipt IDs, role
coverage and unchanged server start time. Re-plan the platform declarations afterward
to check that the ceremony introduced no undeclared grant drift. Nagare/toolkit
changes required by a discovered contract gap belong to their respective canonical
projects; create or link an upstream artifact only when it actually exists.

Do not use the intranet or another live server as a destructive test target. If owned
Nagare infrastructure is unavailable, record exactly which integration remains unrun
and leave M3/IR closure open; generic proofs and ready documentation can still finish.

Publish the portable ceremony first in the ClickHouse migration guide, with evidence
requirements and exact per-user privileges. Keep dedicated server restart as one
valid procedure. Add a separate Nagare subsection or guide mapping concrete reviewed
commands and receipts onto that contract. Other deployments receive a fully usable
manual/operator procedure with the same guarantees and refusal cases. Include backup
coverage/order, scratch schema inspection, server re-bind, failed-session recovery,
external readers, definer grants and transport/server qualification limits.

Update ADRs 17/22 for implemented durable behavior, preserve ADR-18's direct-reader
responsibility, and update relevant capability/terminology/guide evidence. Before
closing IR-2, map every acceptance criterion to executable results, actual Nagare
evidence and documented commands. Use the existing improvement-request profile to
record resolution/target plan and refresh its bundle log; do not claim independent
verification merely because the author ran tests. Mark the parent/children complete
only when their actual gates pass and distill durable findings into ADRs.


## Concrete Steps

Run from the repository root after checking all three hard dependencies are Complete:

```bash
rg -n 'system\.|CREATE|ALTER|Join|processes' kansoku-core/src/Kansoku/Identity/Cache.hs kansoku-core/src/Kansoku/Admin/ClickHouse.hs
mori registry search nagare
mori registry show shinzui/nagare --full
mori registry docs shinzui/nagare
mori path mori://shinzui/nagare/okf/improvement-requests/concepts/IR-31
nix develop -c just ch-migrations-acceptance
```

After implementing the new shared recipe, use these required gates:

```bash
nix develop -c just ch-shared-maintenance-acceptance
nix develop -c just ch-migrations-component
nix develop -c just ch-migrations-source
nix develop -c just acceptance
nix develop -c just check
nix develop -c just guides-check
nix develop -c just capabilities-check
nix develop -c just terminology-check
```

Validate any changed ADR bundle with strict profile/log enforcement:

```bash
nix develop -c okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
```

The Nagare proof's exact invocation is recorded after discovering the adopted owned
deployment harness; do not guess an ambient cluster command. Record release/hash,
qualified server artifact, owned context and sanitized results. Missing Nagare proof
is visibly unaccepted, not converted into a skipped pass.


## Validation and Acceptance

For AC-1, another app queries throughout the session and its server process/start time
does not change while Kansoku runtime is blocked and its migrator works. For AC-2,
retention, erasure and repair run or explainably refuse under denied/incomplete process
visibility; insufficient evidence never starts mutation. For AC-3, restore the complete
recorded set and prove the common pre-migration state, not merely receipt timestamps.
For AC-4, verify renamed scratch databases read-only and detect a changed schema with
matching history. For AC-5, native execution uses only the documented role grants and
a rebuilt restore accepts a new UUID solely through the audited re-bind procedure.

The matrix explicitly reports dedicated, generic shared and Nagare results separately.
Every required group has nonzero cases and zero skipped cases. All evidence is from
owned environments; raw sensitive data stays private. Final documentation distinguishes
qualified combinations from merely configurable ones and does not add a Nagare runtime
dependency to the packaged Kansoku executable.


## Idempotence and Recovery

Each harness run owns new roots/users/databases; cleanup touches only its registered
resources and never infers ownership from names on a shared ambient server. Resume
failed maintenance under the same owner with retained reports and fresh evidence;
do not release fences as test cleanup to turn a failure green. A failed Nagare review
or backup remains a visible failure. Operator resume occurs only after Kansoku's
session/data job has safely completed. Production deployment is outside this plan.

Use Conventional Commits with this plan's `ExecPlan:` and parent `MasterPlan:` trailers
if implementation commits are made; remain on the current branch. Record material
plan revisions with the installed provenance script. Preserve OKF handles and update
bundle logs whenever their governed content/timestamps change.


## Interfaces and Dependencies

Hard dependencies are completed EP-50, EP-51 and EP-52, whose contracts this plan
consumes unchanged. This child owns the privilege inventory, generic joined harness,
Nagare mapping/proof, integrated guides and IR closure. The core runtime gains no
platform SDK, control-plane credentials or provider-specific defaults. Nagare's
recorded completed requests are integration prerequisites only for its deployment;
a non-Nagare shared deployment supplies equivalent exclusion and backup facilities.
