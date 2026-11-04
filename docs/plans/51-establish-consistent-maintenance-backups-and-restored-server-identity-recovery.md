---
id: 51
slug: establish-consistent-maintenance-backups-and-restored-server-identity-recovery
title: "Establish consistent maintenance backups and restored-server identity recovery"
kind: exec-plan
created_at: 2026-11-03T15:42:12Z
master_plan: "docs/masterplans/7-operate-kansoku-clickhouse-safely-across-deployment-platforms.md"
provenance:
  created_by:
    model: "gpt-6.1-sol"
    harness: "codex-cli"
    at: 2026-11-03T15:42:12Z
  reviews:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-11-04T05:38:58Z
      verdict: "changes-requested"
      note: "Pointed at a nonexistent PostgreSQL migration directory; guide backup claim overstated; otherwise consistent with EP-50 M1 contract"
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-11-04T05:38:58Z
      mode: "update"
      note: "Point coordinator schema work at Kansoku/Migrations.hs after EP-50 steps; correct guide backup claim; add ADR bundle validation"
---

# Establish consistent maintenance backups and restored-server identity recovery

This ExecPlan is a living document. Keep its living sections current and promote
implemented durable decisions into the relevant ADRs.


## Purpose / Big Picture

An operator can demonstrate that backups of Kansoku's PostgreSQL state and both
ClickHouse databases form one recovery point before a migration starts. After a
rebuilt-server restore changes the ClickHouse UUID, the operator can deliberately
re-bind the restored installation without discarding migration history, receipts
or a persistent maintenance fence. The same contract works with manual tools or
platform backup facilities; Nagare is one consumer.

This delivers IR-2 AC-3 and the rebuilt-server part of AC-5. It does not implement a
backup engine, production restore orchestration or a new automatic failover policy.


## Progress

- [ ] M1: A recovery-set manifest validates complete database coverage and one fenced, drained backup interval before migration application SQL can start.
- [ ] M2: An owned roundtrip restores all three databases and proves application, coordinator and ledger agreement, including failed/partial backup refusal.
- [ ] M3: A rebuilt-server restore is explicitly re-bound with retained provenance and recovery state; automatic or wrong-target re-binding fails.


## Surprises & Discoveries


## Decision Log

On 2026-11-03, use a retained recovery-set manifest over deployment-produced backups.
Backup mechanisms differ across installations; one recovery contract avoids a
Nagare dependency and exposes coverage gaps hidden by a generic "backup succeeded".

On 2026-11-03, require provenance and explicit old/new identity checks before re-bind.
Replacing a server UUID in the environment alone is not an adequate recovery ceremony.


## Outcomes & Retrospective


## Context and Orientation

The request is [IR-2](../improvement-requests/operate-the-clickhouse-schema-on-a-shared-server.md).
Kansoku stores queue, acceptance, dispositions and coordination state in PostgreSQL;
ClickHouse's `analytics` holds event data and derived objects, while
`kansoku_migration_ledger` holds native migration history. Backing up only analytics
can leave a ledger that says changes already ran against different data.

A fence is persistent PostgreSQL maintenance ownership that rejects cooperating
traffic. Quiescence is externally established exclusion of other submitters plus
completion of old native work. A recovery set is a manifest identifying backups
of all three database states and evidence that their logical contents agree at
a documented point. Independently timed snapshots are sufficient only if relevant
state is stable through their capture or a qualified mechanism proves equivalent
consistency. Nearby timestamps and matching server UUIDs alone do not establish it.

`docs/guides/clickhouse-migrations.md` tells operators to back up both stores
consistently before a rollout and to restore consistent backups for rollback, and it
retains `KANSOKU_CH_MIGRATION_TARGET`, endpoint, server ID and ledger ID;
`docs/guides/operations.md` requires backup and rehearsal of both stores before native
upgrades. Neither guide yet defines what proves one recovery point.
`kansoku-server/src/Kansoku/ClickHouseMigration/Config.hs` loads that binding;
`Command.hs` owns `up`/repair/session entry paths. Native session state is managed
by `kansoku-core/src/Kansoku/Admin/Coordination.hs`. Server identity also appears
in persisted session ownership; simply editing a shell variable can orphan a
restored fence. Locate all identity checks before implementing recovery.

[ADR-22](../adr/0022-explicit-clickhouse-migrations-and-persistent-administrative-sessions.md)
requires retained identities, append-only migration history, exact uncertain receipts
and explicit recovery. [ADR-17](../adr/0017-fenced-resumable-administration-and-applied-retention.md)
requires dispositions, retention policy and resumable job state to survive recovery.
[ADR-10](../adr/0010-owned-executable-acceptance-environments.md) requires owned restores.
[ADR-18](../adr/0018-stable-reader-sql-and-real-consumer-conformance.md) requires pausing
external SQL schedules. Preserve these constraints together.

Hard prerequisite: M1 of
[EP-50](50-accept-portable-drain-evidence-without-cross-user-process-visibility.md)
is accepted. Its versioned drain record binds the owner, target, server/ledger,
covered databases/users and procedure interval; source proofs remain operator-attested.
The implementation must reuse that contract, not define a competing quiescence flag.
[EP-52](52-verify-renamed-clickhouse-restores-without-writes.md) is a soft dependency
for richer restored-copy verification; its absence does not prevent independently
proving backup coverage or implementing a safe re-bind with existing ledger checks.


## Plan of Work

### M1: Bind backup evidence to the fenced pre-migration boundary


Define a bounded versioned recovery-set JSON manifest, proposed implementation in
`kansoku-server/src/Kansoku/ClickHouseMigration/Recovery.hs`, with reference examples
and a precise schema in the migration guide. Bind a unique recovery-set ID, target,
original server and ledger IDs, session, pre-migration predecessor, compiled-plan
identity, the accepted drain-evidence digest, three explicit database coverages,
backup start/completion intervals, artifact references/digests, verification receipts
and the held-exclusion interval. A platform receipt that packages both ClickHouse
databases is valid only when both are explicitly covered and retrievable.
Retain expected applied-retention policy values and any other supported operational
schema parameters with this set so restored-schema verification can distinguish
legitimate administration changes from drift without trusting observed schema alone.

Use one stable logical interval after fence/drain and before any migration application
SQL. Stop data writers and competing administrators, pause and drain overlapping
backup schedules and external readers, and account for TTL, mutations or other
background work that can change logical contents. Merges that preserve logical state
need not be frozen merely to keep physical bytes identical. If background changes
cannot be settled, held app-locally, or captured by a qualified backup mechanism,
refuse to claim a common recovery point. Do not stop the entire shared server.

Take the PostgreSQL snapshot after the maintenance session/fence exists, before
native migration entries, so a restore retains an explicitly fenced recovery state.
The snapshot need not contain its own later backup receipt. Keep the final manifest
outside those snapshots and identify exactly which coordinator phase each snapshot
contains. Record later coordinator audit changes as recovery evidence; do not pretend
there is an atomic transaction across PostgreSQL, ClickHouse and object storage.

Add a proposed `--recovery-set FILE` input to mutating migration entry validation.
The first `up` that can apply a pending suffix requires an accepted complete set;
retries of the same migration attempt may reference that retained pre-change set
with fresh drain evidence and normal receipt recovery. A later maintenance session
or changed pre-change boundary cannot silently reuse it. Clearly document a fresh,
proven-empty installation exception: there is no prior data to back up, but target
and empty-initialization checks still apply. Never let initialization syntax bypass
backup requirements for populated or initialized targets.

M1 acceptance rejects a missing ledger snapshot, mismatched identities, receipts
outside the exclusion window, incomplete artifacts and an invalid predecessor before
any application step. Ledger/status reads for validation do not constitute permission
to run application migration SQL.

### M2: Prove a common recovery point with actual restores


Extend the owned migration harness with a deployment-neutral backup producer. Use
qualified PostgreSQL and ClickHouse backup/restore mechanisms, discovered from their
source/docs through Mori where available and authoritative engine documentation.
Do not invent snapshot APIs. Seed accepted queue work, canonical events, retention/
disposition state and a known native ledger prefix. Fence and drain, capture the
three backups, then change the live fixture with a migration and additional events.
Restore the recorded set into owned scratch targets and compare the pre-change
application facts, coordinator phase, ledger prefix and plan identity. Keep direct
read-only observations so this child's proof can run before EP-52 is complete.

Demonstrate a backup command failing after one artifact completes. The session stays
fenced; `up` refuses the incomplete set. A safe retry creates a new complete set
within a new verified stable interval or finishes a proven unchanged interval;
never combine arbitrary snapshots from different attempts. Capture precise ordering
of fence, completed drain, snapshot boundaries and first application SQL submission.

Document generic mechanisms first. A Nagare recipe references
`mori://shinzui/nagare/okf/improvement-requests/concepts/IR-31` and maps its on-demand
receipts to PostgreSQL plus both ClickHouse coverages. It must keep the backup and
migration principals usable while runtime access is blocked. Current upstream records
report this facility delivered; verify the adopted release rather than scheduling
already-completed upstream work. Final Nagare execution belongs to EP-53.

### M3: Re-bind a rebuilt target without rewriting history


Define an explicit operator recovery operation, proposed `maintenance rebind`, with
expected old and new server IDs, target, ledger, recovery-set ID and retained restore
verification evidence. It must be independently usable when ordinary session loading
refuses because its old server ID differs. Observe the candidate server with a
read-only connection and validate its exact qualified version, expected restored
ledger, original target, backup provenance and restored coordinator owner state.
No command may auto-trust a newly discovered UUID during normal startup, `up` or
repair. Make scratch inspection evidence distinguishable from acceptance of a live
recovery target; EP-52 inspection alone authorizes no mutations.

Keep all unrelated submitters externally blocked and acquire the existing admin/
traffic exclusions in their established order. Re-bind only explicit target/session
identity metadata under compare-and-set checks against the expected original IDs.
Retain old/new binding, actor, reason, backup manifest and verification digests as an
audit record. Do not replace ledger UUID, edit historical events/checksums, mark
failed operations successful or clear the restored fence. Preserve original receipts
and counters. If the public toolkit needs extra read-only restored-target support,
track that with `mori://shinzui/clickhouse-migrate`; do not bypass checks locally.

Prove recovery of a clean pre-migration snapshot whose coordinator contains an active
session, and an interrupted session with unresolved outcome/receipts. The latter
remains blocked until existing reconciliation/repair completes with fresh drain.
Handle a lost re-bind response idempotently: status reports the accepted binding and
audit, and repeating the same request performs no additional transition. Conflicting
old/new IDs or a different manifest fail visibly.

Update the retained-identity and recovery sections of the migration/operations
guides and ADR-22 with the actual procedure. Record the exact boundary of guarantees:
operator-controlled restoration of the whole recovery set, not automatic failover
or arbitrary adoption of another populated server.


## Concrete Steps

Commands run from the repository root. Confirm EP-50 M1's accepted artifact before
beginning implementation, then inspect identity/persistence references:

```bash
rg -n 'server_id|serverId|SERVER_ID|pending_entry|quiescence' kansoku-core/src/Kansoku/Admin kansoku-server/src/Kansoku/ClickHouseMigration
rg -n 'clickhouse_migration_sessions|maintenance_fence' kansoku-core/src/Kansoku/Migrations.hs
mori registry search clickhouse-migrate
mori registry docs shinzui/clickhouse-migrate
nix develop -c just deterministic-test
```

Implement manifest validation and its mutation-boundary checks before the real backup
roundtrip, then the re-bind path. Add a focused owned scenario through the existing
migration harness and run:

```bash
nix develop -c just ch-migrations-acceptance
nix develop -c just ch-migrations-component
nix develop -c just check
```

Require nonzero backup/restore/re-bind case counts, zero failures and no skipped
required cases. Publish sanitized ordering/coverage results; keep raw artifacts,
credentials, receipts and data in the harness's restricted evidence directory.

After amending ADR-22, validate the bundle strictly and advance its log:

```bash
nix develop -c okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
```


## Validation and Acceptance

A complete manifest covers all three databases and their actual restored contents
agree with the seeded pre-change point. A backup failure, missing database, foreign
ledger, wrong plan/boundary, late snapshot or failed consistency condition blocks
migration before its first application step and preserves the fence. Equivalent
manual and platform receipt mappings have identical validation requirements.

A rebuilt owned server has a genuinely different UUID. Ordinary commands refuse the
retained old binding; the explicit re-bind accepts only the verified restore and
leaves its session fenced until normal recovery/finish succeeds. A same-server
scratch restore needs no live identity change. Wrong target, missing coordinator,
unknown ledger, unsupported server, stale restore evidence and unapproved UUID changes
fail without mutating application data or migration history. Interrupted recovery
retains exact receipts and unresolved outcomes. Another app on the original shared
fixture remains available during backup and migration; rebuilt-server proof uses a
separate owned fixture and is not a promise of zero-downtime server replacement.


## Idempotence and Recovery

Retain immutable manifests and raw backup evidence outside the backed-up databases.
Never overwrite a verified recovery set with a partial retry. Failed checks retain
the fence; recover the same owner after a lost response. Re-bind transitions are
compare-and-set and audited so replay cannot accept a different restored server.
Rerun tests with fresh owned roots; never point restoration at ambient databases.
Add coordinator schema as new steps appended to the embedded PostgreSQL plan in
`kansoku-core/src/Kansoku/Migrations.hs`, after any step EP-50 appended, and preserve
applied migration bytes.

Use Conventional Commits with this plan's `ExecPlan:` and parent `MasterPlan:` trailers
if implementation commits are made. Record material plan revisions with the installed
provenance script and distill accepted recovery constraints into ADR-22.


## Interfaces and Dependencies

The hard dependency is EP-50 M1's evidence contract and accepted owner-binding proof.
This plan owns recovery-set validation, the pre-migration backup gate, and audited
server identity re-binding. EP-52 owns renamed read-only inspection and supplies a
compatible verification result when ready. EP-53 consumes the completed ceremony and
exact backup/recovery role requirements. No provider SDK or backup scheduler becomes
a Kansoku runtime dependency. Recheck authoritative registries/tags before selecting
any new dependency or qualified backup mechanism; no new pin is selected by this plan.
