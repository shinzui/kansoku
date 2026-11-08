---
id: 62
slug: run-clickhouse-migrations-on-a-replicated-cluster
title: "Run ClickHouse migrations on a replicated cluster"
kind: exec-plan
created_at: 2026-11-08T00:58:43Z
intention: "intention_01m6wakgf8e24tsk7wkwkddtka"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-11-08T00:58:43Z
---

# Run ClickHouse migrations on a replicated cluster

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current during implementation. Record implementation friction using `agents/skills/exec-plan/FRICTION.md`; distill durable decisions into `docs/adr/` before completion.


## Purpose / Big Picture


Enable `kansoku-ch-migrate` to initialize and upgrade Kansoku on a one-shard ClickHouse cluster with two replicas, using a fresh replicated migration ledger and pre-created databases. Operators select the topology with environment variables. Existing direct installations retain their original 25 migrations, 257 executed SQL steps, and checksum v1 history. A new owned acceptance recipe will prove the actual CLI lifecycle on the exact Altinity `26.3.60.10002.altinitystable` candidate and independently inspect both replicas.

This implements [IR-10](../../docs/improvement-requests/run-clickhouse-migrations-on-a-replicated-cluster.md). Deployment, managed-endpoint acceptance, and replicated application/data-maintenance behavior beyond the migration lifecycle remain the subjects of IR-11 and IR-12. The requesting work is `mori://tan/tan-app-infrastructure/plans/45-onboard-kansoku-to-production-on-the-replicated-clickhouse-cluster`. This is a standalone Kansoku plan, not a child of that other repository's plan. No production contact is required to implement or validate it.


## Progress


- [ ] Milestone 1: Direct and replicated configuration select distinct immutable identities, and PostgreSQL maintenance sessions retain and enforce the full selected identity, including across upgrade from existing direct sessions.
- [ ] Milestone 2: Both histories are embedded; direct offline JSON and v1 checksums match `2008b67`, while the replicated baseline preserves schema semantics with 25 migrations and 254 steps.
- [ ] Milestone 3: Fresh initialization verifies all expected replicas and pre-existing Replicated databases; a representative real CLI migration succeeds under the restricted app profile and PostgreSQL fence.
- [ ] Milestone 4: The full two-replica lifecycle, zero-SQL repeat, native assertions, schema/data parity, and existing query/metrics examples pass on the exact candidate.
- [ ] Milestone 5: Source archives, packaged executable, operator guide, and evidence cover both topologies, with direct regression checks passing and relevant ADRs updated.


## Surprises & Discoveries



## Decision Log


2026-11-08: Preserve the original direct manifest and every bound SQL byte. Create a separately named replicated component with an explicitly reviewed adaptation of the same history. Replaying the adapted history retains the two native assertion groups required by IR-10 and avoids silently omitting historical transformations from a hand-collapsed schema snapshot.

2026-11-08: Extend PostgreSQL session identity as part of this plan. The existing `server_id uuid NOT NULL` cannot represent a cluster. Selecting a representative replica or inventing a synthetic server UUID would fail to bind the intended replica set. This change is necessary to run IR-10's maintenance begin/up/verify/finish lifecycle, while general replicated data-maintenance work remains outside this plan.

2026-11-08: Interpret the request's “argument-free” engines as omitting Keeper path and replica-name arguments, while retaining semantic version-column arguments. For example, `ReplacingMergeTree(received_at)` becomes `ReplicatedReplacingMergeTree(received_at)`. Removing `received_at` would change replacement semantics. The pinned dependency's authoring guide and SQL envelope v2 allow this form.

2026-11-08: Retain the existing four-package `0.1.1.0` source cohort at `0e75c4cc1303423ba561370ee5795aa0cf2455b7`. Registry and upstream tag checks found only release `0.1.0.0`; the local source matches the pinned candidate and already exports the needed replicated APIs. Do not describe this candidate as a Hackage release or upgrade dependencies incidentally.


## Outcomes & Retrospective



## Context and Orientation


A topology describes the servers that own a migration target. A direct target has one persisted server UUID. A replicated target here has one shard (one logical data partition), multiple servers holding the same data, and Keeper coordinating replication. A Replicated database propagates schema changes; Replicated MergeTree engines propagate stored table data. Neither an Atomic database nor a plain MergeTree table supplies both guarantees. A ledger is the immutable record of migration attempts and outcomes. Checksum v1/v2 name the dependency's two definition-hashing policies; replicated execution requires a new v2 ledger and does not convert a direct ledger.

`kansoku-server/src/Kansoku/ClickHouseMigration/Config.hs` loads credentials and target identifiers, constructs only `T.targetConfig`, and checks a single `serverUUID()` plus an empty `analytics` database before fresh initialization. Its HTTP observation is bounded, disables proxying/retries/redirects, and does not share application-native connections. `kansoku-server/src/Kansoku/ClickHouseMigration/Command.hs` selects a plan before executing commands; offline `plan` deliberately needs no credentials, PostgreSQL, or ClickHouse. `kansoku-server/app/ClickHouseMigrate.hs` currently passes `Kansoku.ClickHouseMigrations.plan` for every invocation. The separate `kansoku-server/src/Kansoku/ClickHouseMigration/UpgradeProof.hs` supplies test-only appended and deliberately changed plans.

`kansoku-server/src/Kansoku/ClickHouseMigrations.hs` embeds `kansoku-server/migrations/clickhouse/manifest.json`. That manifest executes 257 steps across 25 migrations. The first steps of migrations 0001, 0002, and 0003 create `analytics`; the history includes 31 plain MergeTree-family table definitions and two Memory-engine assertion groups for source statements 0017/13 and 0017/14. `scripts/check_clickhouse_conversion.py` verifies original byte ranges and native adaptations. It passed during planning with `25 files, 253 exact original ranges, 3 reviewed adaptations, 257 native steps`. Direct history compatibility is measured against commit `2008b67`, not against a newly regenerated golden file.

`kansoku-server/src/Kansoku/ClickHouseMigration/Coordinator.hs` bridges toolkit exclusion to `kansoku-core/src/Kansoku/Admin/Coordination.hs`. The latter persists `server_id` as a PostgreSQL UUID and compares it when acquiring or inspecting a session. `kansoku-core/src/Kansoku/Migrations.hs` owns the additive PostgreSQL migration sequence, currently ending in `0007-clickhouse-administration`. Locks `(726401,2)` and `(726401,1)` serialize administrators and exclude application traffic. A persistent fence continues blocking traffic after a process dies. An entry counter binds each operator drain attestation to the exact previous administrative entry. Keep these protections for both topologies.

`scripts/clickhouse_migrations_acceptance.py` exercises the actual CLI with owned PostgreSQL/ClickHouse processes and includes a request-counting HTTP proxy and parity observations. `kansoku-server/test/ClickHouseMigrations.hs` tests the public migration component on one server. `scripts/check_clickhouse_embedding.py` and `scripts/check_clickhouse_sdist.py` verify content-sensitive builds and execution without runtime SQL files. `justfile`, `kansoku-server/kansoku-server.cabal`, and the Nix configuration connect these checks to builds. `nix/clickhouse-qualified.nix` still supplies a Darwin direct candidate; do not relabel that path as the Linux replicated fixture.

Relevant ADRs consulted are [ADR-22](../../docs/adr/0022-explicit-clickhouse-migrations-and-persistent-administrative-sessions.md), which requires immutable history, explicit migration executables, retained identities, exact receipts, and fail-closed recovery; [ADR-10](../../docs/adr/0010-owned-executable-acceptance-environments.md), which requires disposable owned services and visible failure rather than skipped acceptance; [ADR-17](../../docs/adr/0017-fenced-resumable-administration-and-applied-retention.md), which defines persistent exclusion shared by administrative work; [ADR-18](../../docs/adr/0018-stable-reader-sql-and-real-consumer-conformance.md), which requires stable reader contracts and fencing external readers; and [ADR-23](../../docs/adr/0023-verified-tls-for-native-clickhouse-connections.md), which separates verified native TLS from migration HTTP configuration. ADR-22's single-server/Atomic wording predates the pinned replicated candidate; update it with the qualified new path without weakening its direct-history and recovery rules.

Dependency sources were discovered through Mori at `mori://shinzui/clickhouse-migrate`. Its registry currently advertises no curated docs. Source references below therefore use that canonical project URI plus project-relative paths (artifact-level URIs pending): `clickhouse-migrate/src/ClickHouseMigrate/Target.hs`, `docs/user/authoring.md`, `docs/user/operations.md`, `docs/user/compatibility.md`, `docs/user/contracts/sql-envelope-v2.md`, `clickhouse-migrate-test-support/src/ClickHouseMigrate/TestSupport/Server.hs`, and `clickhouse-migrate-test-support/test/ReplicatedIntegration.hs`. The pinned fixture uses a round-robin HTTP endpoint, two Linux containers, Keeper, cluster `fixture`, an `app` user with password `test-password`, and a constant `database_replicated_allow_only_replicated_engine=1` setting. Its default databases are `fixture_app` and `fixture_ledger`, so Kansoku's harness must bootstrap its own fixed database names before invoking the app CLI.


## Plan of Work


### Milestone 1 — Select and persist the whole target identity


In `kansoku-server/src/Kansoku/ClickHouseMigration/Config.hs`, replace the mandatory single server field with an explicit direct/replicated topology. Extract pure environment-value parsing so tests do not mutate shared process environment. Neither cluster nor replica-list variable means direct mode, retaining all existing direct requirements and `T.targetConfig` arguments. Both variables mean replicated mode and require `KANSOKU_CH_MIGRATION_SERVER_ID` to be absent, even when empty. Exactly one variable, an empty cluster, empty list or CSV element, malformed UUID, or duplicate parsed UUID is an error before network access. Trim surrounding CSV whitespace, validate each UUID through `T.serverId`, sort the validated set deterministically, and reject duplicates rather than silently removing them. Validate the cluster with `T.clusterName` and construct `T.replicatedTargetConfig` through its public `Either` result. Preserve credentials, HTTP endpoint handling, ledger namespace, and first-use binding semantics.

Introduce a topology-bearing session identity in `kansoku-core/src/Kansoku/Admin/Coordination.hs`. Append `0008-clickhouse-replicated-administration` in `kansoku-core/src/Kansoku/Migrations.hs`; never edit the SQL of 0007. Add topology (default `direct` for old rows), cluster name, and a canonical UUID array for replicas; permit nullable `server_id` only for replicated rows. Add constraints requiring exactly one valid shape: direct has a server UUID and no cluster/replicas; replicated has a nonempty cluster and unique, nonempty replica array and no server UUID. Existing direct rows retain their UUIDs, session IDs, fences, entry counters, and receipts. Use canonical sorted arrays and exact topology/cluster/set equality for session matching, not CSV order or a first replica. Update begin/status/lease and coordinator callers together. Never clear fences during this schema migration.

Add `kansoku-server/test/ClickHouseMigrationConfig.hs` and an always-enabled `clickhouse-migration-config` test suite in `kansoku-server/kansoku-server.cabal`. Test the configuration matrix and prove invalid combinations fail without opening a connection. Extend PostgreSQL migration tests and owned session acceptance to show old direct sessions survive the schema upgrade; reordered replicas match; replacing one UUID, changing the cluster, or changing topology refuses resumed access with the fence retained. Native `status --json` must expose the selected topology, cluster, and expected replica set using the toolkit report. Only add application report fields if the toolkit does not already provide them; preserve existing direct fields.

Milestone acceptance is the deterministic configuration suite plus owned PostgreSQL identity tests, including refusal before native application SQL. Keep these tests runnable before the full replicated baseline is ready.


### Milestone 2 — Embed a distinct replicated history without changing direct bytes


Create `kansoku-server/migrations/clickhouse-replicated/manifest.json`, `provenance.json`, and explicit SQL files, embedded by a new `kansoku-server/src/Kansoku/ClickHouseReplicatedMigrations.hs`. Give the component a distinct stable name, `kansoku_replicated`. Retain migration names/order and existing step names wherever retained; remove only the three CREATE DATABASE steps, producing 25 migrations and 254 executed steps. Change the 22 AggregatingMergeTree and nine ReplacingMergeTree engine tokens to their replicated variants while preserving semantic arguments, columns, keys, TTLs, views, inserts, alterations, and assertion prepare/check/cleanup steps. Prohibit explicit Keeper paths, replica-name arguments, ON CLUSTER, CREATE DATABASE, and plain persistent table engines in this baseline. Memory assertion tables remain the intentional transient exception.

Record source and destination hashes and an explicit allowlist of the three omissions and 31 engine adaptations in the new provenance document. Extend `scripts/check_clickhouse_conversion.py` to verify both histories independently and reject any unexplained byte change. SQL is adapted at authoring time and committed, never rewritten at execution time. Keep the direct manifest, provenance, original snapshots, and existing SQL untouched. Preserve version columns such as `received_at`, `version`, and `revision`.

Refactor the plan-selection callback in `Command.hs` and both executable entry points to select by the same validated topology used for online configuration. Offline `plan --json` reads only topology selectors: direct mode still needs no environment; replicated mode needs cluster and replica IDs but no password, endpoint, ledger UUID, or PostgreSQL connection. Invalid selector combinations must not silently fall back to direct. Route status, history, up, verify, repair, reconcile, and finish through the selected history consistently. Keep test-only upgrade variants inaccessible to the production executable.

Capture `plan --json` from a separately built `2008b67` executable with all application and database environment variables removed. Commit the golden JSON under `kansoku-server/test/fixtures/clickhouse-direct-plan-2008b67.json` with its source revision. Compare parsed JSON recursively against the new direct CLI, including every existing field, migration/step order and v1 checksum; normalize only whitespace/object-key order, not values or arrays. Also run the original conversion check and verify no tracked direct migration input differs from that revision. The replicated offline plan must show 25/254 and expose v2 checksums. Add both manifests to all content-qualified build invocations and Cabal source-file lists, including both source-archive proof scripts.


### Milestone 3 — Verify every replica and exercise the real boundary early


Extend fresh-initialization observation in `Config.hs` without inferring the expected UUID inventory from the service. For replicated mode, make fresh non-reused HTTP connections to the configured endpoint until each configured UUID has returned a complete bounded local observation. Each observation includes `serverUUID()`, the engine/presence of `analytics` and `kansoku_migration_ledger`, and the local application object count. Require both databases to exist with engine `Replicated`. Reject an unexpected UUID, malformed/oversized/incomplete/non-success response, nonempty application schema on an uninitialized ledger, or missing expected UUID. Use a single total 35-second deadline, at most 64 observations, a short delay between repeated IDs, per-request timeouts bounded by remaining time, and a 64-KiB response bound. Reject a configured inventory larger than that observation budget. This is bounded coverage verification, not a guarantee that an arbitrary endpoint will route to every replica. Exhaustion fails closed and identifies the missing expected identities without credentials.

Keep public `I.history` validation for ledger shape, identity, and checksum policy. A matching initialized ledger permits interrupted recovery without requiring empty application tables, but still requires complete replica coverage and correct database engines before fresh-initialization authorization proceeds. Conflicting or incompatible history fails. All this occurs under the existing persistent session/exclusion before any application statement. The direct branch keeps its established single-server behavior. A v1 ledger must never be adopted or converted in replicated mode.

Add `kansoku-server/test/ClickHouseReplicatedMigrations.hs` as an explicitly enabled native test driver and `scripts/clickhouse_replicated_migrations_acceptance.py` as the owned PostgreSQL/process/CLI harness. The Haskell driver uses `withReplicatedCandidate "altinity-linux-arm64-10002"`, creates `analytics` and `kansoku_migration_ledger` through fixture administrative `queryServer`, obtains each UUID using `queryReplica server 0/1`, and supplies the endpoint/expected IDs to the Python harness. Bootstrap SQL may use ON CLUSTER and explicit database Keeper templates; application migration SQL may not. Do not add a production database-name override merely to accommodate fixture defaults.

Before expanding the full acceptance matrix, execute an explicitly test-only tiny replicated plan through actual maintenance begin, up initialization, guarded verify, and finish against owned PostgreSQL and the restricted app account. This proves plan selection, session identity, all-replica observation, v2 initialization, and the deployed-command boundary together. Promote this harness into the full proof once it passes; failures change the implementation before adding more scenarios. The tiny plan is never shipped as a production selectable plan.

Use a new fresh fixture for each rejection case: one configured UUID absent despite the right replica count, an endpoint pinned to one actual replica, unexpected identity, a stopped replica, missing/Atomic ledger database, missing/Atomic application database, existing application objects without initialized history, and a foreign v1 ledger. Assert nonzero CLI result, retained fence, and zero application requests. Exercise initialized matching recovery separately so strict freshness does not block supported resumption.


### Milestone 4 — Prove full lifecycle and schema/query parity


Add `just ch-migrations-replicated` to build the test driver and real executables and run the entire owned proof. Use the fixture's restricted `app` login for migrations. Inspect the fixed engine restriction independently. Apply the full replicated baseline through maintenance begin, `up --initialize-ledger`, `verify --require-current --guarded`, and finish. Read the session UUID/entry from JSON and supply the exact predecessor counter, target, actor, reason, quiescence, and evidence flags for each mutating operation, following the existing harness. Verify before finish that the fence is still active and after finish that it is released.

Wrap the round-robin endpoint in Kansoku's existing Python request-counting `FaultProxy`, generalized only where necessary. The dependency fault proxy assumes a single-server transport internally, so do not assume it composes with the replicated fixture. Record counts without SQL/authentication. A repeat in a new retained maintenance session must issue zero additional application SQL and append no native migration events. Compare ordered ledger events independently on both replicas using `queryReplica`. Assert checksum format `sha256-v2` and the expected replicated component throughout.

Prove all permanent table definitions and seeded rows agree between replicas, and that Memory assertion prepare/check/cleanup steps for 0017/13 and 0017/14 succeed with no scratch tables left. Scratch rows are intentionally local and need not replicate. Extend the test-only upgrade proof with a replicated append-only suffix to show a subsequent migration runs once, preserves the baseline prefix, replicates a seeded row, and repeats without application SQL. A deliberately changed applied definition is refused without application SQL.

Compare a fresh direct installation and a fresh replicated installation of the same exact Altinity candidate. Use public direct fixture support with that candidate as the control, leaving the existing Darwin direct acceptance unchanged. Extend `parity_observation` from `scripts/clickhouse_migrations_acceptance.py` to compare table inventory, column order/types/defaults, sorting/primary/partition keys, TTLs, and view SELECT definitions. Normalize only engine-family differences, generated UUIDs, and server-added replica path metadata. Compare version-column engine arguments explicitly. Do not erase meaningful SQL differences with broad string normalization. Seed identical fixtures and compare raw, rollup, reader-view, and metric results on both replicas.

Run the existing query/metrics examples from `kansoku-core/test/Kansoku/QueryIntegrationSpec.hs` and the native metric groups named in `scripts/deterministic-tests.py` against the replicated-baseline database, with `KANSOKU_REQUIRED_INTEGRATION=1`, enforcing nonzero examples and zero pending cases. Reuse `scripts/test_support.py`'s Hspec validation. The dependency's public Server API exposes HTTP but no native TCP endpoint: the owned harness can resolve the local container's published `9000/tcp` mapping by matching the exact `queryReplica` HTTP endpoint to a container carrying `clickhouse-migrate.fixture=owned`, using the explicit isolated Docker context. Require exactly one match and verify the native connection's UUID equals the expected replica before setting test environment ports. Never select an ambient container by a loose name or mutate containers not matched to this fixture. Run suites serially against one replica with the other present, then synchronize and compare observations. This exercises existing query semantics, not general multi-replica writer/maintenance qualification under IR-11.

Missing Docker, wrong architecture/image digest, missing fixtures, zero tests, or pending tests fail the recipe; none count as successful acceptance. Bound all subprocesses and preserve private failure evidence. Keep direct acceptance separately runnable.


### Milestone 5 — Qualify packaging and publish the operator contract


Extend `scripts/check_clickhouse_embedding.py` to mutate a SQL input in each history separately while retaining its timestamp, proving the correct embedded checksums change and the other history does not. Extend `scripts/check_clickhouse_sdist.py` to build both histories from extracted archives, remove migration sources from the extracted copy, and inspect both offline plans successfully. Audit `justfile`, `flake.nix`, `nix/`, and source filtering for all manifest/content-wrapper inputs; both must be present wherever content is qualified. Run the actual Nix-packaged `kansoku-ch-migrate` in the replicated lifecycle recipe as well as the early Cabal proof, resolving its output through Nix JSON build results rather than hard-coded output locations.

Update `docs/guides/clickhouse-migrations.md` with the selector rules, sorted UUID inventory, pre-created databases, fresh v2 ledger, PostgreSQL prerequisite, offline plan usage, all-replica observation bound, operator-provided drain evidence covering every replica, and rejection/recovery behavior. Document that the endpoint must route observation connections to every expected UUID within the bound, and that owned round-robin evidence does not certify a managed service. Update `docs/evidence/clickhouse-migrate-adoption.md` with exact source/image identities, commands, case counts, artifact variant and platform, direct comparison evidence, and any unexecuted gate clearly labeled. Do not claim a Linux-client or production deployment proof from macOS-hosted container results.

Update ADR-22 for direct/replicated identity, separate immutable histories, and pre-existing Replicated ledgers, and ADR-10 for the additional owned acceptance gate. Inspect `mori show --full` and `docs/adr/profile.dhall` before ADR edits; preserve stable handles and update bundle logs using `okf log add`, then run strict validation. Leave unrelated ADR decisions intact. Triage implementation friction and record remaining deployment gates in Outcomes & Retrospective before marking completion.


## Concrete Steps


Run commands from the repository root, `/Users/shinzui/Keikaku/bokuno/kansoku-project/kansoku`. Resolve external dependency paths with Mori; never search `/` or `/nix/store`.

```bash
mori registry search clickhouse-migrate
mori registry show shinzui/clickhouse-migrate --full
mori registry docs shinzui/clickhouse-migrate
mori path mori://shinzui/clickhouse-migrate
python3 scripts/check_clickhouse_conversion.py
git diff 2008b67 -- kansoku-server/migrations/clickhouse
```

Before changing plan selection, build the compatibility executable in a detached temporary checkout; this does not create a feature branch. Choose an unused sibling path (the commands below use `.dev/acceptance` under this repository) and keep evidence until the comparison passes.

```bash
mkdir -p .dev/acceptance
git worktree add --detach .dev/acceptance/direct-reference-2008b67 2008b67
cd .dev/acceptance/direct-reference-2008b67
nix develop --no-write-lock-file -c just ch-migrate plan --json > ../direct-plan-2008b67.json
cd ../../..
```

The golden-capture harness must strip all `KANSOKU_`, `CLICKHOUSE`, and `PG` variables when launching the reference executable; the shell command above shows the build/invocation path, and the implementation should perform the sanitized capture as a subprocess. The direct JSON is the reference for all fields, not only the 25/257 counts.

After creating the proposed tests and recipes, use these gates:

```bash
nix develop --no-write-lock-file -c cabal test kansoku-server:clickhouse-migration-config --test-show-details=direct
python3 scripts/check_clickhouse_conversion.py
nix develop --no-write-lock-file -c just build
nix develop --no-write-lock-file -c just ch-migrations-component
nix develop --no-write-lock-file -c just ch-migrations-source
nix develop --no-write-lock-file -c just ch-migrations-acceptance
```

For replicated offline inspection, no live credentials are needed:

```bash
env -u KANSOKU_CH_MIGRATION_SERVER_ID \
  KANSOKU_CH_MIGRATION_CLUSTER=fixture \
  KANSOKU_CH_MIGRATION_REPLICA_IDS=11111111-1111-4111-8111-111111111111,22222222-2222-4222-8222-222222222222 \
  nix develop --no-write-lock-file -c just ch-migrate plan --json
```

For owned native acceptance, select an existing isolated local Unix-socket Docker context and pre-pull the exact fixture artifact. The context value below is a placeholder for the local owned test context, not a production context:

```bash
export CLICKHOUSE_MIGRATE_DOCKER_CONTEXT='<isolated-local-context>'
docker --context "$CLICKHOUSE_MIGRATE_DOCKER_CONTEXT" pull --platform linux/arm64 \
  docker.io/altinity/clickhouse-server@sha256:7e72405bf85df6d163205ee2e56251ebc35daf6dc71142f58bdee7a461690ffb
nix develop --no-write-lock-file -c just ch-migrations-replicated
nix develop --no-write-lock-file -c just check
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
git diff --check
```

The new recipe must print a sanitized nonzero case count with zero failures and zero skipped cases, plus direct/replicated migration counts, zero repeat application requests, replica parity, and query example counts. Record actual results rather than inventing an expected case total. Build/fixture prerequisites that fail remain visible blockers; do not change pins or lower qualification checks to make them pass.


## Validation and Acceptance


IR-10 AC-1 is satisfied only by the recursive offline JSON comparison with `2008b67`, unchanged original inputs and passing conversion evidence, plus direct native regression showing the existing ledger remains usable. AC-2 requires deterministic selector refusal before connection, a real status report naming the chosen cluster/replicas, and retained session identity rejecting target changes. AC-3 requires the reviewed explicit replicated SQL, schema parity beyond columns alone, and the existing non-skipped query/metrics examples. AC-4 requires fresh v2 history in the already-existing Replicated ledger database and independently demonstrated all-replica coverage, including negative cases with no application SQL. AC-5 requires the full CLI/coordinator lifecycle on the exact 10002 image under the fixed app profile, successful Memory assertions, zero-SQL repeat, and independent table/row/event observations through both `queryReplica` indices.

The early tiny-plan lifecycle is required before expanding full-history cases because it tests the uncertain boundary between dependency topology, Kansoku's PostgreSQL session, and fixture bootstrap. Compilation, a single-server test, or the dependency's own release evidence cannot substitute for this application's complete lifecycle. Packaged and source-archive checks must exercise both embedded histories. This plan's completion does not attest production permissions, endpoint affinity, all runtime maintenance jobs, or deployment acceptance.


## Idempotence and Recovery


All native acceptance creates fresh owned services and clears inherited target variables. Only the harness-created test databases may be dropped or recreated for rejection cases. Repeated test runs use new roots and ledger IDs; preserve private diagnostics on failure and stop only owned child processes. Do not run test SQL against staging or production.

Direct ledger history and all applied migration SQL remain immutable. Never convert a populated direct stack in place, copy a v1 ledger into the replicated database, delete only `analytics`, or regenerate ledger identity after a partial initialization. A failed/ambiguous run retains its PostgreSQL fence, session, ledger UUID, predecessor marker, and receipts. Observe status/history, obtain explicit evidence that prior requests on all replicas have drained, then use existing reconciliation/repair commands with the selected topology. Only verified current history permits finish. Timeout, missing replica, or empty process list is not drain evidence.

The PostgreSQL upgrade is additive and preserves old rows; application rollback must not erase new session metadata. Do not run an older direct-only CLI against a retained replicated session. Restore consistent store backups into a separately reviewed target if recovery requires rollback. Source-archive mutation tests modify only extracted private copies, never checked-in SQL or an applied ledger.


## Interfaces and Dependencies


Retain `mori://shinzui/clickhouse-migrate/packages/clickhouse-migrate`, `mori://shinzui/clickhouse-migrate/packages/clickhouse-migrate-cli`, `mori://shinzui/clickhouse-migrate/packages/clickhouse-migrate-embed`, and `mori://shinzui/clickhouse-migrate/packages/clickhouse-migrate-test-support` at the common source candidate already pinned in `cabal.project` and the Nix configuration. The relevant verified public signatures are:

```haskell
replicatedTargetConfig
  :: TargetKey -> DirectEndpoint -> ClusterName -> NonEmpty ServerId
  -> LedgerNamespace -> LedgerBinding -> Credentials -> HttpLimits
  -> Either TargetError TargetConfig
withReplicatedCandidate :: Text -> (Server -> IO a) -> IO a
queryReplica :: Server -> Int -> Text -> IO Value
stopReplica :: Server -> Int -> IO ()
startReplica :: Server -> Int -> IO ()
```

`queryReplica` returns a JSON object including HTTP status and body; validate status and parse complete JSONEachRow responses rather than treating it like `queryServer`'s decoded row array. Replica indices are 0 and 1. Use administrative fixture calls only for bootstrap/independent observations; actual migrations must authenticate as the restricted app user.

The operator-facing additions are exactly `KANSOKU_CH_MIGRATION_CLUSTER` and `KANSOKU_CH_MIGRATION_REPLICA_IDS`. Existing endpoint, target, ledger UUID, session UUID, credentials, and PostgreSQL variables retain their meaning. PostgreSQL becomes capable of persisting either a direct UUID or a cluster plus full replica set. No production option discovers identities, changes database names, converts old history, or overrides the qualified server guard. The requesting TAN plan can consume this contract and evidence when implementation finishes; this plan does not authorize posting messages or changing its deployment repository.
