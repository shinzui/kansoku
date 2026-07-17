---
id: 21
slug: migrate-kansoku-to-the-coherent-pg-migrate-pgmq-and-shibuya-cohort
title: "Migrate Kansoku to the coherent pg-migrate PGMQ and Shibuya cohort"
kind: exec-plan
created_at: 2026-07-17T14:02:43Z
intention: "intention_01kxr5jt2heyvt0n768ym9dwqd"
master_plan: "docs/masterplans/2-kansoku-production-hardening-review-fixes-and-portfolio-service-readiness.md"
---

# Migrate Kansoku to the coherent pg-migrate PGMQ and Shibuya cohort

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Kansoku currently resolves one dependency graph through Cabal and a different, older graph through
Nix. Cabal sees pg-migrate 1.1.0.0, PGMQ 0.4.0.1, Shibuya 0.8.0.1, and the Shibuya PGMQ adapter
0.12.0.0 from workstation-local directories; the Nix package build pins older PGMQ 0.3.0.0,
Shibuya 0.7.1.0, and adapter 0.8.0.0 commits. The application still calls APIs removed by the
selected current cohort, so `nix develop -c cabal build all` fails at
`Pgmq.Migration.migrate` before it reaches the other known call sites.

After this plan, both build paths resolve one portable, released cohort; Kansoku exposes a
dedicated `kansoku-migrate` administrative executable whose `plan`, `status`, `verify`, and `up`
commands own PGMQ schema migration; normal server startup no longer silently applies framework
migrations; and the writer compiles against the current handler, adapter, and application APIs.
The migration plan contains only PGMQ because Kansoku does not depend on Kiroku, Keiro, or Kioku
and owns no PostgreSQL application migrations. A fresh ephemeral PostgreSQL integration test proves
the plan creates PGMQ, a second apply does zero work, and queue provisioning works after migration.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-07-17 14:02Z) Located the registered dependency sources and read the selected
  pg-migrate, PGMQ, Shibuya, Shibuya PGMQ adapter, and Nix integration APIs.
- [x] (2026-07-17 14:02Z) Captured the pre-change Cabal failure: `Pgmq.Migration` no longer exports
  `migrate`.
- [x] (2026-07-17 14:02Z) Confirmed Kansoku uses only the PGMQ/Shibuya slice; Kiroku, Keiro, and
  Kioku are absent and must not be introduced.
- [ ] M1: replace workstation-local Cabal dependency paths and the old Nix cohort overrides with
  one portable released cohort.
- [ ] M1: prove Cabal and Nix resolve pg-migrate 1.1.0.0, PGMQ 0.4.0.1, Shibuya 0.8.0.1, and
  shibuya-pgmq-adapter 0.12.0.0.
- [ ] M2: migrate the writer handler to `Message`, create `PgmqAdapterEnv`, handle adapter
  configuration failure, and call Shibuya `runApp` with `AppConfig`.
- [ ] M2: add a PGMQ-only `MigrationPlan` and the explicit `kansoku-migrate` CLI; remove schema
  migration from normal server startup while retaining idempotent queue provisioning.
- [ ] M3: add pure plan tests and an ephemeral PostgreSQL integration test covering first apply,
  strict verification, zero-work second apply, and queue provisioning.
- [ ] M3: run Cabal build/tests and the active Nix build/check path.
- [ ] M3: classify the repository-local development database read-only; run no reset or destructive
  database command without explicit approval.
- [ ] MasterPlan registry/dependencies and outcomes updated; migration plan marked Complete.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-07-17, before implementation: the Nix pins are older than the cohort Cabal currently sees.
  `nix/haskell.nix` pins `pgmq-migration` 0.3.0.0, `shibuya-core` 0.7.1.0, and
  `shibuya-pgmq-adapter` 0.8.0.0, while the Cabal build selected 0.4.0.1, 0.8.0.1, and 0.12.0.0.
  A green `cabal build` alone therefore cannot prove the flake package is deployable.

- 2026-07-17, before implementation: the generic keiro-stack migration order is conditional, not
  a requirement to add unused libraries. `mori show --full` lists PGMQ and Shibuya dependencies but
  no Kiroku, Keiro, or Kioku package. Kansoku's plan is therefore `pgmq` only.


## Decision Log

Record every decision made while working on the plan.

- Decision: Add this migration as a hard dependency of EP-10 rather than treating it as an
  untracked external prerequisite.
  Rationale: EP-10 cannot compile or validate supervision until the dependency cohort and runtime
  APIs agree. A checked-in child ExecPlan makes the gate restartable and visible in the MasterPlan.
  Date: 2026-07-17

- Decision: Use the published known-good cohort: pg-migrate 1.1.0.0, every consumed PGMQ package
  0.4.0.1, shibuya-core 0.8.0.1, and shibuya-pgmq-adapter 0.12.0.0.
  Rationale: these versions are source-verified, mutually compatible, and available as releases;
  they remove workstation-path dependence without inventing newer unverified combinations.
  Date: 2026-07-17

- Decision: Compose only `Pgmq.Migration.pgmqMigrations` into Kansoku's PostgreSQL plan.
  Rationale: Kansoku has no Kiroku, Keiro, Kioku, or application-owned PostgreSQL SQL. Adding absent
  components would enlarge the runtime and database surface without an owner or consumer.
  Date: 2026-07-17

- Decision: Keep queue creation as an idempotent provisioning step after migration, but remove
  PGMQ schema migration from normal server startup.
  Rationale: the PGMQ library owns its schema through a native migration component, while the queue
  name is application configuration and can vary by environment. Startup must fail if the explicit
  schema migration was omitted rather than silently creating a migration ledger.
  Date: 2026-07-17

- Decision: Validate database behavior with an isolated ephemeral PostgreSQL instance before
  classifying or changing the repository-local development database.
  Rationale: this proves the production migration artifact without assuming existing local data is
  disposable. Database policy remains `ask`; destructive work needs separate approval.
  Date: 2026-07-17

- Decision: Keep Kansoku's existing flake and `nix/haskell.nix` structure during this migration;
  replace only the stale PGMQ/Shibuya overrides and use released Hackage packages or exact source
  pins as needed.
  Rationale: adopting a shared Haskell package-set abstraction is not required to migrate this
  service and would mix build-infrastructure redesign into an otherwise small cohort cutover. The
  acceptance criterion is one version cohort across Cabal and Nix, not a new Nix architecture.
  Date: 2026-07-17


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

Kansoku is a GHC 9.12.4 multi-package Haskell service. `kansoku-api` contains Servant route and
wire types, `kansoku-core` contains PostgreSQL/PGMQ ingestion and the Shibuya writer,
`kansoku-server` contains the executable entry points, and `kansoku-client` contains the Haskell
client. This plan is EP-21 of
`docs/masterplans/2-kansoku-production-hardening-review-fixes-and-portfolio-service-readiness.md`
and is the hard dependency immediately before EP-10. EP-21 restores a coherent dependency and
migration baseline; EP-10 then adds writer supervision and readiness without also owning a cohort
upgrade.

A **cohort** is the set of library releases that must agree at their shared APIs. Here it is
pg-migrate 1.1.0.0, the consumed PGMQ packages at 0.4.0.1, shibuya-core 0.8.0.1, and
shibuya-pgmq-adapter 0.12.0.0. A pg-migrate **component** is one library's ordered migration
history; a **plan** validates and orders one or more components. Kansoku has only the PGMQ
component. It has no application-owned PostgreSQL SQL and does not depend on Kiroku, Keiro, or
Kioku.

The two build descriptions currently disagree. Root `cabal.project` names workstation-absolute
package directories for OpenAPI, PGMQ, and Shibuya packages, so it is not portable and happens to
select the current cohort from nearby checkouts. `nix/haskell.nix`, used by `flake.nix`, pins older
PGMQ and Shibuya commits. The observable result is not just theoretical: from the repository root,
`nix develop -c cabal build all` selects the current Cabal cohort and fails first at
`kansoku-core/src/Kansoku/Ingest/Queue.hs` because `Pgmq.Migration.migrate` no longer exists.

The current APIs were located through `mori` and read from their registered sources. PGMQ now
exports `pgmqMigrations :: Either DefinitionError MigrationComponent`; pg-migrate builds a plan
with `migrationPlan` and runs it with `runMigrationPlan`. Shibuya batch handlers now receive
`Shibuya.Core.Ingested.Message`, `pgmqAdapter` requires a `PgmqAdapterEnv` and returns a
configuration `Either`, and `Shibuya.App.runApp` takes an `AppConfig` followed by the processor
registry. The affected Kansoku modules are:

- `kansoku-core/src/Kansoku/Ingest/Queue.hs`, which currently applies the old framework migration
  during `bootstrapQueue` and then creates the configured queue.
- `kansoku-core/src/Kansoku/Writer/Batch.hs` and its test, which still use `Ingested`.
- `kansoku-core/src/Kansoku/Writer/Run.hs`, which calls the older adapter and application APIs.
- `kansoku-server/app/Main.hs`, which invokes `bootstrapQueue` during ordinary server startup.

The repository-local development PostgreSQL state lives under `db/` and defaults to database
`kansoku`. Its persistence and contents are not known in advance. It is therefore classified
read-only during this plan. All migration application tests use a separate ephemeral PostgreSQL
instance; no reset, drop, or ledger repair of the repository-local database is authorized.


## Plan of Work

### Milestone 1 — One portable dependency cohort

Edit `cabal.project` so project membership is repository-relative and external libraries no longer
depend on sibling directories. Add a stable `index-state` that includes the released target
cohort, constrain the cohort versions explicitly, and retain only unrelated source pins that are
still required. Replace local OpenAPI paths with the portable source already used by the Nix
build. Remove broad `allow-newer` exceptions if the resolved cohort proves they are unnecessary.

Edit only the relevant overrides in `nix/haskell.nix` so the active flake resolves the same
published PGMQ and Shibuya releases. Keep the current Nix architecture. Remove stale Git pins one
family at a time and use released Hackage packages or exact source pins when the package set needs
help. `cabal build --dry-run all` and `nix build .` must both report the intended cohort before this
milestone is accepted.

### Milestone 2 — Current runtime APIs and explicit schema ownership

Update `Kansoku.Writer.Batch` and `Kansoku.Writer.BatchSpec` from handler-facing `Ingested` values
to `Message`. Update `Kansoku.Writer.Run` to construct `PgmqAdapterEnv` from the existing pool,
surface the adapter's configuration error, and call `Shibuya.App.runApp` with an explicit
`AppConfig` preserving today's `IgnoreFailures` strategy and inbox size 100. EP-10, not this plan,
will change lifetime supervision.

Add `kansoku-core/src/Kansoku/Migrations.hs` as the single composition point for Kansoku's
PostgreSQL `MigrationPlan`. It unwraps `Pgmq.Migration.pgmqMigrations`, composes that one component,
and returns definition/plan errors rather than hiding them. Add `kansoku-server/app/Migrate.hs`
and a `kansoku-migrate` executable stanza that delegates administrative commands (`plan`,
`status`, `verify`, and `up`) to pg-migrate's CLI API using the same PostgreSQL settings as the
server.

Refactor `Kansoku.Ingest.Queue` so its normal-server function only idempotently creates the
configured queue. Update `kansoku-server/app/Main.hs` accordingly. If PGMQ has not been explicitly
migrated, server bootstrap must fail at queue provisioning; it must not install or mutate the
migration ledger implicitly. Wire the explicit migration command into the documented local startup
path (`justfile` and/or `process-compose.yaml`) before the server begins.

### Milestone 3 — Behavioral migration proof

Add a pure test that the application migration plan is valid and contains only PGMQ in the
expected order. Add an integration test using `pg-migrate-test-support` and an isolated ephemeral
PostgreSQL database. The test applies the plan, strictly verifies it, applies it again and observes
zero pending work, then provisions the Kansoku queue. It must not connect to the repository-local
development database.

Run the whole Cabal suite and both active Nix validations. Finally, perform only read-only checks
against the repository-local database to record whether it is running and whether PGMQ and the
pg-migrate ledgers already exist. Any persistent-database cutover is a separate operator action,
not a hidden test step.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/kansoku-project/kansoku`.

Capture and compare the two dependency resolutions while editing Milestone 1:

    nix develop -c cabal build --dry-run all
    nix build .

Expected evidence includes one set of target versions, not the former split:

    pg-migrate-1.1.0.0
    pgmq-*-0.4.0.1
    shibuya-core-0.8.0.1
    shibuya-pgmq-adapter-0.12.0.0

Exercise the administrative surface without changing a persistent database:

    nix develop -c cabal run kansoku-migrate -- --help
    nix develop -c cabal run kansoku-migrate -- plan
    nix develop -c cabal run kansoku-migrate -- list

The help output names the supported pg-migrate actions. `plan` and `list` inspect the PGMQ-only
plan and do not run a destructive reset. Exact subcommand spelling may follow pg-migrate-cli's
source-verified API; update this transcript if the library exposes different read-only names.

Run the automated verification:

    nix develop -c cabal build all
    nix develop -c cabal test all
    nix build .
    nix flake check
    git diff --check
    git status --short

Expected result: every build/test/check exits zero; the migration integration test reports a
successful first apply, successful strict verification, no work on the second apply, and successful
queue provisioning.

Classify the development database without changing it:

    nix develop -c pg_ctl status -D db/db
    nix develop -c psql -X -Atqc 'select current_database(), current_user'
    nix develop -c psql -X -Atqc "select to_regclass('pgmq.meta'), to_regclass('public.pg_migrate_migrations')"

The first command may report that PostgreSQL is stopped. Record that fact and stop; do not start,
reset, drop, or migrate the repository-local database merely to make this checklist green.


## Validation and Acceptance

The plan is complete only when all of the following are observable:

- Both `nix develop -c cabal build all` and `nix build .` succeed against the same target cohort;
  `cabal.project` contains no workstation-absolute package paths.
- `Kansoku.Writer.Batch` consumes `Message`, and `Kansoku.Writer.Run` uses `PgmqAdapterEnv`, handles
  the adapter's `Either`, and supplies explicit `AppConfig`.
- `kansoku-migrate` exposes the PGMQ-only pg-migrate plan and owns schema application. Ordinary
  `kansoku-server` startup does not call `runMigrationPlan` or mutate pg-migrate ledgers.
- On a fresh ephemeral PostgreSQL database, the first application installs PGMQ, strict
  verification passes, a second application has no pending migrations, and the configured queue
  can be created.
- The full Cabal tests, Nix package build, and flake checks pass. No destructive command was run
  against the repository-local database.


## Idempotence and Recovery

Dependency-resolution, builds, pure tests, and ephemeral-database tests are safe to repeat. Queue
creation remains idempotent. Applying the same pg-migrate plan twice is an explicit acceptance
test and the second run must perform no migration work.

The migration history is forward-only. Do not edit an already-applied migration identity or repair
a persistent ledger by hand. If a new code defect is found before any persistent cutover, fix the
component/plan and recreate only the ephemeral test database. If a persistent database already has
state that does not verify, stop and record its classification; author a forward reconciliation or
an operator-approved cutover plan rather than resetting it.

For Nix resolution failures, remove or replace stale overrides one family at a time and rerun
`nix build .`; do not mix unrelated package upgrades into this plan. Existing user changes outside
the Kansoku repository, including the source blueprint, are not touched.


## Interfaces and Dependencies

The dependency cohort is pg-migrate 1.1.0.0, consumed PGMQ packages 0.4.0.1,
shibuya-core 0.8.0.1, and shibuya-pgmq-adapter 0.12.0.0. Exact APIs must continue to be checked in
the registered source trees with `mori`; memory is not a substitute for package source.

`Kansoku.Migrations` must export an error-bearing way to obtain the application
`Database.PostgreSQL.Migrate.MigrationPlan`. Its only component is the value obtained from
`Pgmq.Migration.pgmqMigrations`. It must not add Kiroku, Keiro, Kioku, or application SQL merely to
mirror a generic stack template.

`kansoku-migrate` must use the official `pg-migrate-cli` interface and the same parsed PostgreSQL
connection settings as `kansoku-server`. Administrative migration is an explicit executable
boundary, not a server-startup side effect.

`Kansoku.Ingest.Queue` retains an idempotent queue-provisioning operation over the existing Hasql
pool. `Kansoku.Writer.Batch.writerBatchHandler` consumes a non-empty batch of
`Shibuya.Core.Ingested.Message`. `Kansoku.Writer.Run.runWriter` constructs the adapter environment
with `mkPgmqAdapterEnv`, handles `pgmqAdapter` configuration failure, and starts Shibuya with an
explicit `AppConfig` equivalent to `defaultAppConfig` (`IgnoreFailures`, inbox size 100).

Later API work remains governed by the repository's Servant house standard: the exact served API
type is the OpenAPI source of truth, NamedRoutes/vertical slices are preferred, MultiVerb unions
are handwritten and exhaustively tested, authentication is declared per field, and non-readiness
errors use RFC 7807 problem details. This migration does not change HTTP contracts, so it neither
preempts EP-9 nor introduces a parallel API pattern.
