---
id: 49
slug: adopt-clickhouse-migrate-for-explicit-clickhouse-migrations
title: "Adopt clickhouse-migrate for explicit ClickHouse migrations"
kind: exec-plan
intention: "intention_01m5356w2megxs0ej4dzfgb20j"
created_at: 2026-10-16T20:05:39Z
provenance:
  created_by:
    model: "gpt-6.1-sol"
    harness: "codex-cli"
    at: 2026-10-16T20:05:39Z
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-16T20:10:42Z
      mode: "other"
      note: "Complete adoption plan and link the intention created with mina ci; preserve release, platform, coordination and cutover gates"
---

# Adopt clickhouse-migrate for explicit ClickHouse migrations

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current. Promote durable implementation decisions into docs/adr/ before completion. Follow agents/skills/exec-plan/PLANS.md and agents/skills/exec-plan/ADR.md when executing it.


## Purpose / Big Picture


Replace Kansoku's filename-only shell migration runner with a packaged `kansoku-ch-migrate` executable. Operators will inspect the compiled migration plan, detect changed historical definitions, import an existing installation's history without replaying its SQL, and recover deliberately after an interrupted step. Normal server startup will continue to require separately applied PostgreSQL and ClickHouse migrations.

Success means the actual packaged executable can migrate an empty owned database, repeat without application SQL, adopt all 25 existing migrations, and execute an appended migration. A lost response must block ordinary execution until explicit recovery. All ClickHouse administration must share exclusion with Kansoku's existing maintenance jobs. The plan delivers and rehearses the cutover on disposable databases; it does not authorize modifying a persistent installation, publishing another package, or claiming a live deployment.


## Progress


- [ ] M1: Published dependencies and the exact supported ClickHouse artifact resolve through both Cabal and Nix; the native acceptance platform is explicit.
- [ ] M2: An embedded Kansoku component exposes the complete reviewed plan and passes fresh replay plus a no-op repeat through a representative public-library consumer.
- [ ] M3: A persistent administrative session fences traffic and other administrators, survives process loss, and requires explicit predecessor-quiescence evidence before mutation can continue.
- [ ] M4: The packaged CLI supports inspection, execution, legacy adoption and explicit repair with target identity, initialization and recovery evidence preserved.
- [ ] M5: Every supported migration entry point uses the executable, and required owned acceptance proves adoption, interruption recovery, coordination and application behavior.
- [ ] M6: Operations guides, architecture decisions and release evidence describe the rehearsed cutover and its actual support limits.


## Surprises & Discoveries


(None yet.)


## Decision Log


2026-10-16: Adopt the released core, embedding and CLI libraries in a separate administrative executable. Keep the native ClickHaskell driver for application queries and writes. Migration transport is independent HTTP owned by the toolkit; replacing the application driver would add unrelated scope.

2026-10-16: Initially target one directly addressed ClickHouse 26.8.28.14 server on Apple Silicon macOS, with the exact official binary from the dependency's qualification matrix. Do not broaden its version allowlist locally. Linux qualification, Cloud, replication and distributed execution are excluded. Keep platform-independent checks on Ubuntu and run required native acceptance on an explicitly selected Apple Silicon macOS runner; missing platform prerequisites fail the gate rather than skip it.

2026-10-16: Use explicit persistent maintenance sessions around ClickHouse migration commands. Reuse the PostgreSQL administrator and traffic locks, and extend persisted admission state. No process lock, advisory lock release, timeout or empty process list proves that ClickHouse has finished an earlier request. Preserve a pending-entry marker after each mutating entry and require external quiescence evidence before another entry or session completion.

2026-10-16: Preserve the 25 original SQL files and the predecessor ledger as evidence. Define reviewed native steps separately and import filename/time history as operator-attested evidence. Current file hashes establish the accepted baseline onward; they cannot prove historical execution bytes or completion.


## Outcomes & Retrospective


(To be filled during and after implementation.)


## Context and Orientation


`db/clickhouse/migrate.sh` creates `analytics.schema_migrations(filename, applied_at)`, sorts `db/clickhouse/migrations/*.sql` by filename, runs each whole file with `clickhouse-client --multiquery`, then inserts a ledger row. It has no checksums, per-statement checkpoints or administrator exclusion. A failed file may have partially executed; a successful file followed by a lost ledger acknowledgement may be replayed on the next invocation. A ledger is the durable record of migration history, not proof of arbitrary live schema equality.

`justfile` exposes the runner as `ch-migrate` and calls it again after dropping `analytics` in `ch-reset`. `scripts/isolated_clickhouse.py:apply_migrations` also invokes it; many native scenarios use that helper without PostgreSQL. `scripts/acceptance.py` already owns both databases and applies PostgreSQL first. `scripts/first_use_acceptance.py` exercises the documented developer commands. Inventory direct shell invocations as well as helper callers before removing the runner.

`kansoku-server/app/Migrate.hs` mounts PostgreSQL migration commands. `kansoku-core/src/Kansoku/Migrations.hs` owns the explicit PostgreSQL application component; it currently ends at `0006-metric-definitions`. Its `0004-maintenance` definition creates `maintenance_fence`, `maintenance_jobs` and `require_traffic_lock()`. Append a new migration rather than editing those applied SQL bytes. `kansoku-core/src/Kansoku/Maintenance.hs:withTraffic` and `kansoku-core/src/Kansoku/Admin/Store.hs:admitMaintenanceTraffic` protect application operations. `kansoku-core/src/Kansoku/Admin/Jobs.hs` uses administrator lock `(726401,2)` and exclusive traffic lock `(726401,1)` for resumable jobs. The existing `active_job` column references a maintenance job; do not invent a synthetic foreign-key value for migration sessions.

`cabal.project` fixes an index state at 2026-10-14, before this release. `flake.module.nix` owns application package overrides and Nix outputs. `nix/haskell.nix`, `flake.nix` and `flake.lock` are Seihou-managed; extend project-specific wiring in `flake.module.nix` and preserve shared pins. The shell currently supplies `pkgs.clickhouse`; recorded Kansoku evidence uses 26.8.2.7. The dependency's runtime accepts exactly 26.8.28.14. `.github/workflows/check.yml` currently runs both deterministic and packaged acceptance on `ubuntu-latest`, which is outside the dependency's qualified platform.

The owning dependency project is [mori://shinzui/clickhouse-migrate](mori://shinzui/clickhouse-migrate). Its [core](mori://shinzui/clickhouse-migrate/packages/clickhouse-migrate), [embedding](mori://shinzui/clickhouse-migrate/packages/clickhouse-migrate-embed), [CLI](mori://shinzui/clickhouse-migrate/packages/clickhouse-migrate-cli) and [test support](mori://shinzui/clickhouse-migrate/packages/clickhouse-migrate-test-support) are separate packages. The CLI package is a reusable parser/handler library, not a ready-made migration executable. Consult the canonical [adoption runbook](mori://shinzui/clickhouse-migrate/okf/user-documentation/concepts/DOC-2), [compatibility contract](mori://shinzui/clickhouse-migrate/okf/user-documentation/concepts/DOC-5), [SQL envelope](mori://shinzui/clickhouse-migrate/okf/user-documentation/concepts/DOC-11) and [operations contract](mori://shinzui/clickhouse-migrate/okf/user-documentation/concepts/DOC-13). Resolve source with Mori before relying on APIs.

At planning time all 25 current SQL files and the shell runner matched the dependency's captured Kansoku fixture at source revision `138d9a316931bbf46781757a29ab6c7fdd90f870`. That fixture belongs to `mori://shinzui/clickhouse-migrate`, project-relative `clickhouse-migrate-test-support/test/fixtures/kansoku/` (file-level artifact URI pending). It preserves 253 source statements and defines 257 native steps. Two standalone assertions in migration 0017 become prepare/INSERT-SELECT-check/cleanup steps, adding four steps. One materialization in migration 0018 removes `mutations_sync=2` in favor of the qualified local `mutations_sync=1` policy. Recheck original hashes before reusing this mapping. Recorded upstream fixture success is useful evidence, but does not replace Kansoku's own executable acceptance.

Relevant local decisions are [ADR-10](../adr/0010-owned-executable-acceptance-environments.md), requiring actual packaged binaries, owned fresh resources, nonzero required cases and private diagnostics; [ADR-17](../adr/0017-fenced-resumable-administration-and-applied-retention.md), requiring persistent fences, shared traffic admission and preservation of failed jobs; and [ADR-18](../adr/0018-stable-reader-sql-and-real-consumer-conformance.md), requiring external SQL schedules to pause during maintenance because they bypass PostgreSQL admission. These remain binding. The new migration decision must explain how it extends them.


## Plan of Work


### M1 — Resolve the release and pin the native platform


Recheck Hackage and upstream tags before selecting versions. During this planning session the core appeared as 0.1.0.0 while companion-package endpoints still returned 404. Treat that as a transient observation. Record exact published versions, source archive hashes and upstream tag/commit identities; compare the released API and migration formats with the inspected source. Do not substitute an untagged local checkout for the released cohort. Advance the dated Cabal index only enough to include the chosen packages. Add exact application constraints and Nix overrides without disabling dependency invariants or widening their declared bounds. Expose the embedding package's build driver in the developer shell so supported recipes can invoke it directly.

Add `nix/clickhouse-qualified.nix` and a checked-in artifact record under `db/clickhouse/qualification/`. Fetch the official aarch64-darwin 26.8.28.14 binary, validate its SHA-256 against the upstream qualification matrix, and supply consistent `clickhouse-server` and `clickhouse-client` launchers through project wiring. The inspected matrix records SHA-256 `ab5a04de4a6b705e0f1f02e6a0e0a44feff8b4455b6dfcc4a03b7571f98fbb60`; independently verify the released matrix before adopting it. Ensure PATH selects this artifact for process-compose, standalone fixtures and packaged acceptance rather than the older shell package. Unsupported platforms may still compile deterministic components but must not silently launch an unqualified server for this gate.

Plan the workflow split now: Ubuntu retains `just check` and appropriate package-build checks; a native arm64 macOS job runs packaged migration/service acceptance with the pinned binary. Use the explicit `macos-26` hosted label, verify `uname -m` is `arm64`, and recheck runner availability against [GitHub's runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners) before editing the workflow. Preserve immutable action revisions, timeouts and sanitized evidence. Do not claim a remote passing run from a local run. If required hosted prerequisites are unavailable, retain the required failing native gate and record the blocker instead of restoring the old shell runner or declaring Linux qualified.

M1 passes when both package managers resolve/build the released cohort, the selected native binary reports 26.8.28.14 and matches its recorded digest, and an owned target probe accepts it while rejecting the previous version and a wrong server UUID. Platform checks and dependency locks must be reproducible without traversing `/nix/store`.


### M2 — Embed the complete reviewed migration component


Create `kansoku-server/migrations/clickhouse/manifest.json`, explicit named statement files beneath it, and `provenance.json` mapping every original filename/hash and byte range to native steps. Keep original `db/clickhouse/migrations/*.sql` unchanged. Use the captured fixture as reviewed input, not a production dependency on test-support data paths. Retain every original assertion and record all three adaptations. Component name is `kansoku`; migration names retain their existing numbered stems. The execution schedule is explicit and append-only: applying a new version must not reorder the already applied prefix.

Define `Kansoku.ClickHouseMigrations` in `kansoku-server/src/Kansoku/ClickHouseMigrations.hs`, exporting the validated component and composed plan using the public constructors and `embedComponent`. Add manifest/SQL/provenance inputs to `kansoku-server/kansoku-server.cabal:extra-source-files`. The server subtree is already a Nix source boundary, so keeping embedding inputs there makes them available to `callCabal2nix` builds. Register modules in the administrative executable and its focused test component; keep CLI/embed/test-support dependencies out of `kansoku-core` and the application's query/write code.

Use `clickhouse-migrate-embed-build` for Cabal build/test/Haddock paths that own the manifest, including developer recipes and scripts that initiate builds. Nix source hashing must include every input. Exercise preserved-timestamp SQL changes so a stale embedded executable cannot pass the gate. Source archives must build independently, and running the compiled plan must not reopen migration sources.

Before expanding the CLI, compile a representative consumer of the public runner and execute the full component on an owned qualified server under an actual serialized fixture scope. Verify the two assertion adaptations run, fresh state matches targeted schema/reader observations, and a second run submits zero application SQL. This is the early producer/consumer proof; failure here changes the mapping before later integration grows around it. M2 passes with 25 migrations, 257 native steps, exact source hashes, successful assertions and an independently observed no-op repeat.


### M3 — Coordinate migration sessions with existing maintenance


Append PostgreSQL application migration `0007-clickhouse-administration` in `kansoku-core/src/Kansoku/Migrations.hs`. Create separate migration-session state retaining a session UUID, target key, expected server UUID, ledger UUID, current administrative entry, predecessor-quiescence requirement and redacted audit/evidence references. Retain the same ledger UUID before any first-use ClickHouse submission, including interrupted initialization. Store no credentials or authored SQL in this state. Enforce a single active session for this initial single-tenant deployment.

Introduce shared coordination in `kansoku-core/src/Kansoku/Admin/Coordination.hs`. An administrative scope owns a dedicated PostgreSQL backend, takes `(726401,2)`, persists its migration-session fence before taking exclusive `(726401,1)`, and refuses entry if an existing data-maintenance job owns the fence. Update `Kansoku.Maintenance.withTraffic`, `Kansoku.Admin.Store.admitMaintenanceTraffic` and `kansoku.require_traffic_lock()` to reject an active migration session as well as an active data-maintenance job. Update `Kansoku.Admin.Jobs` so new jobs and resumed jobs cannot bypass migration-session exclusion. Keep the same lock acquisition order to avoid deadlocks. Bound acquisition and liveness checks; session loss must never be interpreted as successful release.

Expose application-owned `maintenance begin` and `maintenance finish` commands on the new executable. Begin records the operator and returns a durable session ID. Ordinary migration mutations require that ID. Before each mutating entry, persist a predecessor marker under the administrator lock; loss of the process or connection leaves it set. Re-entry after any preceding mutation requires fresh target/session-bound `--quiescent` evidence establishing that all preceding application SQL, ledger INSERTs and initialization DDL have finished or been terminated. This includes clean prior entries: a generic cleanup callback is not a drain proof. Wire the toolkit's `externallySerialized` callbacks to the shared coordinator, and its alive callback to actual retained backend ownership. Do not use the test-support host-local adapter in production.

Finish acquires exclusion, validates explicit predecessor-quiescence evidence, verifies the retained native ledger is current with no unresolved execution/adoption, and then atomically closes the PostgreSQL migration session. Failed inspection, unknown requests or cleanup preserve the fence. Read-only unguarded diagnostics remain available while fenced; no force-clear command is added. A PostgreSQL-only recovery command must not clear an unfinished ClickHouse session merely because its owner process disappeared.

The operator establishes quiescence outside the library. Stopping every administrative client and completely stopping/restarting the directly owned ClickHouse server while retaining its data identity is one reproducible test procedure; a timeout or empty `system.processes` read is not equivalent evidence. Application traffic stays fenced throughout. External reader schedules require operator suspension under ADR-18. This plan does not turn a PostgreSQL fence into a network fence against arbitrary manual SQL.

M3 passes using separate processes: competing migration/admin jobs cannot mutate, protected traffic returns the established maintenance response, process/backend loss preserves the fence, the old session cannot submit after scope loss, and explicit external drain plus matching recovery evidence permits re-entry. Include both Haskell session admission and database-side transaction admission, since either can otherwise bypass the fence.


### M4 — Mount the application CLI and import existing history


Add `kansoku-server/app/ClickHouseMigrate.hs` and modules under `kansoku-server/src/Kansoku/ClickHouseMigration/` for configuration, coordinator adaptation and legacy evidence. Add executable `kansoku-ch-migrate` and Nix output `kansoku-ch-migrate`. Mount the toolkit's parser/handler and renderers, preserving their target/audit/repair validation. Add only application-owned maintenance commands and a read-only `legacy-snapshot` command. Parse offline `plan` without loading PostgreSQL, credentials or live target configuration. JSON goes to stdout, redacted progress/errors to stderr, and failure produces a nonzero exit status.

Keep existing host/user/password/HTTP-port settings usable, but require a direct administrative endpoint and explicit target/server identity. Add `KANSOKU_CH_MIGRATION_TARGET`, `KANSOKU_CH_MIGRATION_ENDPOINT`, `KANSOKU_CH_MIGRATION_SERVER_ID`, `KANSOKU_CH_MIGRATION_LEDGER_ID` and `KANSOKU_CH_MIGRATION_SESSION` configuration. Store events in a dedicated `kansoku_migration_ledger` Atomic database, separate from `analytics`; application SQL is forbidden from touching the ledger namespace. Credentials remain explicit and redacted. First use requires an operator-retained UUID and initialization authorization; recurring execution binds `ExistingLedger` and never silently creates a missing ledger. Do not auto-discover and trust a new server UUID on every run. Before first-use up, refuse an existing predecessor ledger or application objects that could represent a legacy/partial installation; direct those installations to reviewed adoption or explicit investigation. Missing native history must never implicitly authorize replay over an existing schema.

`legacy-snapshot --output DIRECTORY` reads `analytics.schema_migrations` without mutation and creates exclusively owned private evidence files. Preserve exact filenames and timestamp precision, source revision, original source hashes, native mapping/checksums and a snapshot digest. Reject duplicate rows, unknown names and holes or out-of-order mappings; map an accepted complete applied prefix, not only the full 25-row case. Do not sort away invalid history or promote filename-only evidence into historical checksum verification. Keep the predecessor ledger in place after adoption. The reusable `adopt plan/apply/resume --request FILE` commands consume the reviewed snapshot/mapping with explicit operator attestation and quiescence.

Test a complete 25-row import against a database populated by the original SQL, verify that adoption sends zero application statements, then run a test-only appended migration that visibly changes a scratch table. Also test a valid shorter prefix followed by its pending suffix, stale snapshots, malformed mappings, interrupted adoption and identical-batch resume. Cover `repair retry-step`, `accept-step`, `resume` and `finalize` at the application integration boundary: the selected retry executes only its authorized statement, acceptance/finalization execute none, and stale attempts/positions or missing evidence refuse mutation. Do not duplicate the dependency's whole transport suite; exercise Kansoku's configuration, serialization, reports and receipts on representative lost-response and surviving-query cases.

M4 passes through both Cabal and Nix-built CLI binaries. A changed applied step or wrong target identity fails before application SQL; an absent recurring ledger fails without creating it; a successful imported baseline verifies as current with retained operator-attestation evidence.


### M5 — Retire the shell runner and require executable acceptance


Replace `just ch-migrate` with argument forwarding to `kansoku-ch-migrate`; expose the required audit/session inputs rather than manufacturing evidence. Turn `db/clickhouse/migrate.sh` into a short failing retirement stub pointing to the new executable, retaining its original bytes/hash in cutover evidence. No supported script may execute old multiquery migration logic after the switch.

Update `scripts/isolated_clickhouse.py:apply_migrations` and its callers to use the real binary. Introduce an owned coordinator fixture composed from `scripts/isolated_postgres.py` for standalone ClickHouse-only scenarios; reuse the already owned PostgreSQL instance in `scripts/acceptance.py`. Explicitly carry target/server/ledger/session configuration and reject ambient endpoints. Each test owns fresh UUIDs and ports; do not share a coordinator state with the developer database. Resolve Nix-packaged `kansoku-ch-migrate` beside `kansoku-server` for packaged acceptance rather than invoking `cabal run` from the gate. Update `scripts/first_use_acceptance.py`, direct runner invocations and fixture subprocess timeouts for the new workflow.

The previous `ch-reset` is unsafe after introducing a separate ledger: dropping only `analytics` would leave a current ledger and cause replay to skip everything. Replace its old implementation with a refusal and instructions to create a fresh disposable stack with fresh database roots and a new ledger identity. All automated reset/replay proofs must create such owned stacks. Do not add a reset/force operation to the native ledger or apply destructive reset to a persistent target.

Add `scripts/clickhouse_migrations_acceptance.py` and `just ch-migrations-acceptance` with required, non-skipping scenarios for fresh/repeated execution, original-source adoption, a new migration, uncertainty, recovery and competing administrators. Keep original-source replay only as a private fixture function restricted to fresh owned databases, never as an alternate operator entry point. Make full `just acceptance` call the new verifier and retain the existing reader, ingestion, administrative and telemetry families. Update `.github/workflows/check.yml` with the native platform split from M1. Failing platform checks or unavailable binaries must not become pending tests or green shell fallbacks.

M5 passes when static searches find no supported old-runner call path, both focused and full packaged native gates pass with nonzero cases, and the existing application behavior still passes after the pinned ClickHouse upgrade. Include original/native schema observations and raw/derived result parity; matching filenames alone are insufficient. Retain private request/effect evidence and sanitized summaries separately.


### M6 — Document the actual cutover and distill decisions


Update `docs/guides/getting-started.md`, `configuration.md`, `operations.md`, `administration.md`, `development.md`, `consume-clickhouse.md` and `consumer-conformance.md` with explicit PostgreSQL-first setup, qualified binary installation, maintenance sessions, retained UUIDs, adoption evidence and repair. Show the actual generated `--help` syntax and commands after the implementation exists. Explain how to retain/reconcile pending append receipts and why ordinary up does not resume interrupted work. Preserve reader role ownership and privileges, including the definer identity of reader views.

Write a runbook covering an inventory/backup of both stores, stopped writers and external SQL schedules, immutable legacy snapshot, three native adaptations, adoption preview/apply, native verify, a subsequent migration, and controlled traffic release. Rehearse it against an owned legacy-populated stack. Define the point after adoption where returning to the old runner is forbidden. A rollback restores a consistent backup into a separate target and reviews identities; it does not rewrite native checksums or discard ledger events. Persistent live execution remains a separate operator action outside this implementation's acceptance.

Create a new migration ADR with `okf id next`, preserve the profiled ADR convention, and update ADR-10/17/18 where the platform or admission contract changes. Record the final dependency versions, binary digest, source revision, command outcomes and evidence paths in `docs/evidence/clickhouse-migrate-adoption.md`. Distinguish local proof, remote CI configuration, observed remote results and deployment status. Use the new Kansoku plan/change URI as the external consumer reference to `mori://shinzui/clickhouse-migrate`; do not mark its upstream initiative complete or write to that repository merely because the local fixture passed.

M6 passes when the documented fresh and legacy workflows are reproduced with the packaged executable, strict ADR/guide validation passes, and no guide describes the old shell ledger as the current migration system.


## Concrete Steps


Run from the repository root, `/Users/shinzui/Keikaku/bokuno/kansoku-project/kansoku`. These commands describe implementation work; creating this plan does not execute migrations.

First locate the released dependency and verify publication. Registry discovery locates local source; Hackage and upstream tags establish what can be pinned.

```bash
mori registry search clickhouse
mori registry show shinzui/clickhouse-migrate --full
mori registry docs shinzui/clickhouse-migrate
mori path mori://shinzui/clickhouse-migrate/packages/clickhouse-migrate
curl -fsSL https://hackage.haskell.org/package/clickhouse-migrate/preferred.json
curl -fsSL https://hackage.haskell.org/package/clickhouse-migrate-embed/preferred.json
curl -fsSL https://hackage.haskell.org/package/clickhouse-migrate-cli/preferred.json
curl -fsSL https://hackage.haskell.org/package/clickhouse-migrate-test-support/preferred.json
git ls-remote --tags https://github.com/shinzui/clickhouse-migrate.git
```

Each selected package must report a released compatible version; a 404 leaves the corresponding dependency unresolved. Read the release archive and compare it with its tag before filling exact constraints and archive hashes. A newer release must be evaluated against this plan's APIs and target policy rather than accepted solely for its version number.

After implementing M1/M2, enter the development shell and use the content-qualified wrapper from the repository root. Its `--input` pair is the owning package directory and manifest path relative to that package.

```bash
nix develop --builders ''
clickhouse-server --version
clickhouse-migrate-embed-build --input kansoku-server migrations/clickhouse/manifest.json -- build all --enable-tests
cabal run kansoku-server:exe:kansoku-ch-migrate -- plan --json
cabal run kansoku-server:exe:kansoku-ch-migrate -- --help
```

Expected observations are version 26.8.28.14 and a JSON plan containing one `kansoku` component, 25 ordered migrations and 257 named steps. Offline plan must work with PostgreSQL/ClickHouse stopped and migration credentials unset. The new executable and wrapper recipes do not exist before the implementation milestones.

Build and test actual package boundaries after M3/M4. Stage only the intended new Nix input files before flake evaluation so Git-backed flake sources include them; retain unrelated user edits. Do not search or read `/nix/store`; execute exact output paths returned by Nix when needed.

```bash
nix build .#kansoku-server .#kansoku-ch-migrate --no-link --json
just ch-migrations-acceptance
just check
just acceptance
nix flake check --builders ''
seihou diff
```

The focused harness must report a nonzero case count with zero failures and zero skipped/pending required cases. Full acceptance must reach the existing reader and administration families, not stop after fresh migrations. `seihou diff` must show no unintended managed-file drift. Run native commands on the qualified arm64 macOS platform only; Ubuntu retains the deterministic/build checks described in M1.

For source and documentation verification after implementation:

```bash
rg -n 'db/clickhouse/migrate\.sh|schema_migrations|apply_migrations\(' justfile scripts docs/guides
okf id list docs/adr --profile docs/adr/profile.dhall
okf id next docs/adr --profile docs/adr/profile.dhall ADR
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
just guides-check
git diff --check
```

Historical evidence and the retirement stub may mention the old runner; supported execution paths must not call it. Resolve the shared documentation/profile dependency through Mori if using an unfamiliar OKF API rather than guessing commands.


## Validation and Acceptance


The early integration check is the complete embedded plan executed through the public runner on an owned server in M2. Validate independently observed application requests/effects, not just a successful return code. Then use the mounted application CLI and packaged output for all final acceptance. New tests must focus on the migration/coordinator boundary rather than reproducing every implementation detail of the dependency.

An empty owned target reaches the complete current schema, assertions and reader projections. Repeating after explicit predecessor drain sends no application SQL. A changed applied step, reordered history, wrong server UUID, unsupported version or missing recurring ledger returns nonzero before application SQL. The compiled executable continues to inspect its plan with migration source files absent. An input change with preserved timestamps is observed by the supported build path.

An owned legacy installation replays the unchanged source SQL and retains exactly 25 filename/time records. Snapshot and adoption preserve that evidence; adoption submits no application SQL. Verification reports a compatible/current native baseline, and a test-only appended migration executes once. Valid shorter prefixes also work. Duplicate/holey/unknown history and changed snapshots refuse adoption without advancing native history. An interrupted identical adoption batch resumes only after explicit external quiescence and fresh expected state.

Inject response loss after a demonstrably committed application statement and after a ledger append, retain the exact pending receipt, and prove ordinary up refuses replay. A fresh process must see the same unresolved condition. Establish external drain while retaining the persistent fence, reconcile receipts read-only, then use an explicit repair request with current position/attempt. Count SQL effects to distinguish retry, acceptance and finalization. Keep original primary errors and secondary cleanup errors visible; no failure clears the fence. Terminating a process while a server query remains active must block a mutating successor.

Two administrative processes cannot mutate concurrently. Existing erasure/retention and migration sessions exclude each other. HTTP traffic, writer insertion and direct PostgreSQL admission paths respect the migration fence; session or backend death does not release it. Ordinary diagnostic history/status remain usable while fenced. Completion requires current native history plus explicit quiescence evidence. External direct readers are paused by the runbook, not falsely claimed to be covered by the PostgreSQL fence.

Final acceptance is the actual Nix executable, both stores owned by the harness, qualified native binary, repeated native migration scenarios and the existing full service suite. Keep secrets, raw source diagnostics and private snapshots outside sanitized uploads. Update code, plan and ADRs when real interface behavior differs. Do not call a configured-but-unrun remote workflow, a fixture-only proof or a pending live cutover completed deployment.


## Idempotence and Recovery


Builds, offline plan and unguarded inspection are repeatable. A fresh stack always owns new database roots and identities, and cleanup stops only its recorded processes. Preserve failed private diagnostics. Normal up applies only the compatible pending suffix and cannot authorize replay of interrupted work. Creating the coordinator schema is an additive PostgreSQL migration, not an edit to applied history.

Retain the same ledger UUID after interrupted initialization; silently generating another would change the intended target. Never clear a durable session marker based on elapsed time, process absence or a single NotObserved receipt. A request can arrive or complete later. Diagnose read-only, establish external quiescence for all predecessor requests, inspect again under exclusion, then submit only the selected recovery/adoption operation. The persistent fence remains through any unresolved step or cleanup failure.

Before adoption, preserve original files, source hashes, predecessor ledger and a consistent backup. Afterwards preserve both ledgers and retire the old runner permanently. Failed adoption can resume only its identical accepted batch; a different snapshot/mapping is not a replacement. Restore backups only through a separately reviewed operator procedure on a separate target with explicit identity rebinding. Neither restoring only analytics nor deleting the native ledger is a rollback strategy.

All commits made during implementation must use Conventional Commits, stay on the current branch unless instructed otherwise, and include `ExecPlan: docs/plans/49-adopt-clickhouse-migrate-for-explicit-clickhouse-migrations.md` and the active `Intention:` trailer. Record model provenance with the skill's script when a later session materially changes this plan.


## Interfaces and Dependencies


`Kansoku.ClickHouseMigrations` exports the application-owned `MigrationComponent` and `MigrationPlan`. Use `ClickHouseMigrate.Definition`/`Plan` and `ClickHouseMigrate.Embed.embedComponent`; inspect the released signatures first. Keep component identity, migration/step names, SQL bytes and execution order stable after application.

`Kansoku.ClickHouseMigration.Config` constructs `TargetConfig` through validated `TargetKey`, `DirectEndpoint`, `ServerId`, `LedgerNamespace`, `LedgerBinding`, `Credentials` and bounded `HttpLimits`. It never exposes credentials through rendering. `ClickHouseMigrate.CLI.commandEnvironment` and `handleCommand` receive the compiled plan, optional configuration, provider, diagnostic policy and command policy. Use toolkit JSON/text renderers; the application owns stdout/stderr and exit codes. Observe/report types are the source of truth for native ledger state, not PostgreSQL coordinator rows.

`Kansoku.Admin.Coordination` owns the shared PostgreSQL administrative lease and persistent session state. `Kansoku.ClickHouseMigration.Coordinator` adapts that application primitive to `ClickHouseMigrate.ExclusiveAccess.externallySerialized`. Acquisition excludes all administrators for the target; alive checks actual ownership; release preserves the predecessor marker. A lease is temporary exclusive permission, while a persisted fence prevents future traffic after the lease disappears. Neither one alone establishes server quiescence. `maintenance finish` is the explicit application-level transition that verifies evidence/currentness and closes the persistent fence.

`Kansoku.ClickHouseMigration.Legacy` produces bounded private filename/time evidence and native mappings for `ClickHouseMigrate.Adoption`, preserving operator-attested evidence strength. Reuse library validation, receipt reconciliation and explicit `ClickHouseMigrate.Repair` operations rather than synthesizing ledger events or importing private modules.

Production requires the released core, embed and CLI packages plus the existing PostgreSQL coordination stack. Test-support is test-only. Keep new migration dependencies scoped to the server's administrative/test components. No new external service is required. The initial platform is a direct self-managed qualified macOS/arm64 server with local synchronous storage effects; SQL and ledger writes still have no joint transaction and no exactly-once guarantee. This standalone plan has no parent MasterPlan or prerequisite unfinished Kansoku plan; its publication/platform gates are M1, and no live database action is implied by completing it.
