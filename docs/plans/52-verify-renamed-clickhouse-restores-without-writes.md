---
id: 52
slug: verify-renamed-clickhouse-restores-without-writes
title: "Verify renamed ClickHouse restores without writes"
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
      note: "verify-restored did not name its executable; Command.hs is edited by EP-50 and EP-51 in parallel; local toolkit checkout lags the pinned commit"
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-11-04T05:38:58Z
      mode: "update"
      note: "Name kansoku-ch-migrate and parser isolation for verify-restored; note pinned commit versus local checkout; add ADR bundle validation"
---

# Verify renamed ClickHouse restores without writes

This ExecPlan is a living document. Keep its living sections current and promote
implemented durable decisions into the relevant ADRs.


## Purpose / Big Picture

An operator restores Kansoku backups into scratch databases beside live databases
and checks that the restored migration ledger and actual installed schema match
the expected release. The inspection uses read-only credentials, writes nothing,
and does not change Kansoku's live database names or authorize a later migration.
A matching migration ledger with a missing or changed table must fail verification.
This delivers IR-2 AC-4 independently of any deployment platform.


## Progress

- [ ] M1: A separate restored-copy inspection path accepts explicit scratch mappings and safely reads the expected original ledger under a read-only identity.
- [ ] M2: Release-bound schema expectations and structural comparison detect actual schema drift without executing or rewriting migration steps.
- [ ] M3: Packaged verification passes on a matching renamed restore, fails on adversarial drift, and proves zero writes and no effect on live databases.


## Surprises & Discoveries


## Decision Log

On 2026-11-03, make restored-copy verification a separate inspection path. Making
normal mutation configuration accept arbitrary database names would enlarge the
live mutation surface and still leave immutable embedded SQL pointing at analytics.

On 2026-11-03, report ledger agreement and schema agreement separately. Native
history proves recorded execution; it does not prove no later manual schema drift.


## Outcomes & Retrospective


## Context and Orientation

The source request is
[IR-2](../improvement-requests/operate-the-clickhouse-schema-on-a-shared-server.md).
Live application SQL uses `analytics` and the migration ledger uses
`kansoku_migration_ledger`. A scratch restore is a separate copy, for example
`analytics_restore_ID` and `kansoku_migration_ledger_restore_ID`, on the same server.
Its physical database/table UUIDs may legitimately differ. The logical ledger UUID,
original target and exact migration definitions still need to match the backup and
release expectations.

`kansoku-server/src/Kansoku/ClickHouseMigration/Config.hs` fixes the ledger namespace
and the empty-analytics initialization check. `Command.hs` delegates `verify` to the
upstream inspection API. Its existing current-history check does not compare all
installed objects. `kansoku-server/migrations/clickhouse/manifest.json`, `steps/`,
`original/` and `provenance.json` define the immutable compiled baseline.
`scripts/check_clickhouse_conversion.py` and `scripts/check_clickhouse_embedding.py`
protect its conversion and source embedding. `scripts/clickhouse_migrations_acceptance.py`
already compares original/converted fixture behavior and owns packaged CLI scenarios;
reuse its fixture and fault boundaries where practical.

[ADR-22](../adr/0022-explicit-clickhouse-migrations-and-persistent-administrative-sessions.md)
requires immutable steps, explicit target/ledger identity, and no legacy adoption.
[ADR-18](../adr/0018-stable-reader-sql-and-real-consumer-conformance.md) requires the
published projections and correct SQL SECURITY DEFINER behavior.
[ADR-10](../adr/0010-owned-executable-acceptance-environments.md) requires actual
packaged commands against owned databases with required cases that cannot skip.
Inspection must honor all three without pretending to be a restore/adoption command.

The toolkit source owner is `mori://shinzui/clickhouse-migrate`. Discover its public
inspection/target/ledger APIs through Mori before designing an adapter, reading the
commit `00afa9fa` that `cabal.project` pins for 0.1.0.1; on 2026-11-03 the local Mori
checkout was at the 0.1.0.0 release and did not contain that commit. If a public
read-only API cannot inspect a restored namespace and original target safely, track
upstream support there. Do not import private internals, disable identity checks or
copy a second ledger implementation into Kansoku.


## Plan of Work

### M1: Add an isolated read-only restored-copy target


Add a proposed `verify-restored` command to the `kansoku-ch-migrate` executable, whose
parser is `kansoku-server/src/Kansoku/ClickHouseMigration/Command.hs`. It is a sibling
of the toolkit's native commands and of the `maintenance` group; it must not change the
`--predecessor` option or the `maintenance` subcommands, which EP-50 and EP-51 edit in
parallel. Its name and flags describe new work, not syntax available today. Require explicit application
and ledger database names, observed endpoint/server UUID, original target/ledger
expectations, and expected compiled release/plan. Support an optional recovery-set
reference from EP-51, but do not make that child a hard prerequisite: explicit
expectations suffice to test inspection independently.

Keep restore configuration separate from `Config.loadConfig`'s mutating path. Reject
invalid/ambiguous identifiers, equal application/ledger names, missing expectations
and an implicit fallback to live names. Quote identifiers through one tested
boundary; never interpolate arbitrary SQL. The command must operate without a live
PostgreSQL coordinator or a maintenance session and must not create one. An observed
server UUID is an inspection binding, not acceptance of a replacement live server.

Use a connection and account restricted to read-only metadata and the named restored
ledger; no CREATE, INSERT, ALTER, DROP, temporary table or session-lock writes.
Use bounded reads and fail clearly on denied or incomplete metadata visibility.
Through the public toolkit inspection API, validate event shape, checksums, original
target, ledger UUID, ordered prefix/currentness and unresolved outcomes. Preserve
original event bytes: changing a namespace for inspection must not re-author history.

Prove the boundary early with one owned scratch ledger on the same server as a live
ledger. A foreign ledger, wrong server UUID or wrong original target fails; correct
scratch mapping reads the expected ledger while normal mutation config stays fixed.
If upstream delivery is required, keep that milestone open until its public API and
qualified source cohort work; do not claim private SQL cloning as support.

### M2: Compare actual schema against release-bound expectations


Define a versioned schema expectation artifact tied by digest to the compiled
migration plan and qualified server artifact. Generate the initial expectations by
applying the real immutable migration plan to a fresh owned server and inspecting
metadata, not by splitting or rewriting SQL. Check the artifact into the server's
migration inputs and package it alongside the compiled plan. Extend build/source
archive checks so a plan/expectation mismatch cannot ship. Keep source SQL and its
provenance bytes unchanged. Initial acceptance covers a current restored release;
an older compatible prefix is reported distinctly as not current, never a full pass.

The comparison covers expected database engines and application objects, columns
with types/default/materialized expressions/codecs, table engines, partition/order/
primary keys, TTL policy, materialized-view targets and definitions, public views
and references between objects. Include ledger storage/schema compatibility through
the toolkit's supported inspection. Separate configured grants from schema content:
check definer existence/reference expectations without changing users or their grants.
EP-53 proves actual access under deployment-specific roles.

Account explicitly for schema expressions changed by supported administration operations.
For example, `Kansoku.Admin.Jobs.retainNative` installs an applied-retention TTL
containing the cutoff. Represent that expression as a constrained schema template
whose expected cutoff comes from retained recovery metadata or explicit expected
policy input, and cross-check the restored policy relation. Do not compare an
operated backup only against fresh-install TTL bytes, ignore TTL entirely, or trust
the observed expression as its own expectation. If required policy evidence is
missing, report incomplete verification. This remains read-only and requires no
connection to the live PostgreSQL coordinator.

Normalize only explicitly permitted differences: scratch application/ledger database
identifiers, physical UUIDs assigned by restore, and reviewed deployment principal
bindings. Match database references structurally; never use global string replacement,
which would alter data literals, comments, JSON paths or unrelated identifiers.
Keep actual expected expressions in the artifact. If the qualified metadata includes
an unsupported representation or normalization cannot establish equivalence, report
an explanatory unsupported/mismatch result. Unknown extra objects are reported and
prevent a full schema-equality pass unless explicitly documented as outside the
owned object set; do not hide them through a broad name-prefix rule.

Report stable redacted results for ledger compatibility, schema equality, missing/
extra objects and mismatches. Include the observed scratch mappings and expectation
digest, clearly distinct from the original live identity and backup provenance.
No success result authorizes re-binding or migration; EP-51 owns that operation.

### M3: Prove native read-only behavior and package the procedure


Restore an actual owned backup beside live databases, with both database names
changed. Give the verifier only its documented read grants and read-only settings.
Run the packaged command, expect successful ledger and schema results, then compare
live and scratch metadata/data with fixture-owned independent observations. Use
fixture request capture plus denied write privileges to demonstrate no writes,
including temporary tables and PostgreSQL changes. A before/after count alone is
insufficient to detect attempted writes.

Change a restored column type/default, remove a view, change an engine/sort key,
change a TTL/reference and add an unexpected object in separate fixtures while
keeping the ledger unchanged. Each must return a precise mismatch and nonzero exit.
Include a view containing the literal string `analytics.events_raw` and an identifier
that merely contains `analytics`; mapping must preserve literals and unrelated names.
Test identifier rejection, denied metadata, a missing/foreign ledger and partial
history. The live copy always remains untouched and usable.

Update `docs/guides/clickhouse-migrations.md` with exact commands, roles, results and
limits. Amend ADR-22 to distinguish native-history inspection from restored-schema
comparison. Update source/package acceptance for the expectation artifact. Final
Nagare restoration and privilege integration is EP-53 work.


## Concrete Steps

Run from the repository root:

```bash
mori registry search clickhouse-migrate
mori registry show shinzui/clickhouse-migrate --full
mori registry docs shinzui/clickhouse-migrate
rg -n 'verify|nativeConfig|ledgerNamespace' kansoku-server/src/Kansoku/ClickHouseMigration
rg --files kansoku-server/migrations/clickhouse
nix develop -c just ch-migrations-component
```

Implement M1's public read-only producer/consumer proof before schema normalization.
Add expectation generation/verification to the existing migration tooling and run:

```bash
nix develop -c just ch-migrations-acceptance
nix develop -c just ch-migrations-source
nix develop -c just check
```

Each required native case must run and report an explicit nonzero count with zero
failures and zero skips. Verify the installed Nix executable and extracted source
artifact contain the expectation digest. Proposed `verify-restored` examples become
executable guide fixtures once its actual CLI is implemented.

After amending ADR-22, validate the bundle strictly and advance its log:

```bash
nix develop -c okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
```


## Validation and Acceptance

A matching restored pair under different names passes on the live fixture's server
with read-only credentials and no coordinator configuration. Its report separately
identifies a compatible/current ledger and matching actual schema. Schema drift with
an unchanged ledger fails; a correct schema with incompatible ledger fails too.
Wrong target, wrong observed server, wrong logical ledger, incomplete visibility and
unsupported schema comparison cannot yield a full pass.

Observe every request sent by the verifier and assert only the documented read-only
operations occurred. Keep both denied write privileges and independent before/after
observations. No mutation entry accepts scratch configuration, and no verifier result
automatically re-binds live identity. Preserve the baseline's exact SQL/hash/order.


## Idempotence and Recovery

The verifier is repeatable and performs no cleanup because it creates nothing.
Failures leave restores and live targets untouched. The operator owns backup restore
and disposal of scratch databases; this command never creates or drops them. Tests
restore only fixture-owned databases and retain private evidence on failure. Updating
schema expectations requires a fresh owned derivation from the actual appended plan,
not accepting whatever schema happens to be live.

Use Conventional Commits with this plan's `ExecPlan:` and parent `MasterPlan:` trailers
if implementation commits are made. Record material plan revisions through the
installed provenance script and distill the accepted inspection boundary into ADR-22.


## Interfaces and Dependencies

No hard child prerequisites. EP-51's recovery-set manifest is a soft integration:
the verification result exposes observed endpoint/server, scratch mappings, original
target/ledger, compiled-plan and expectation digests, compatibility/schema results
and unresolved history, so recovery can consume it without guessing. This child owns
the command, schema expectation artifact, namespace normalization and read-only role
requirements. EP-53 consumes the completed behavior. Public toolkit support may be
an external delivery gate; verify authoritative registry releases and upstream tags
before selecting a replacement cohort. This plan chooses no new dependency version.
