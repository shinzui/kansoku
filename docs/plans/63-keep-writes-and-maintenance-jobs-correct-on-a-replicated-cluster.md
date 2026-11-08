---
id: 63
slug: keep-writes-and-maintenance-jobs-correct-on-a-replicated-cluster
title: "Keep writes and maintenance jobs correct on a replicated cluster"
kind: exec-plan
created_at: 2026-11-08T01:08:07Z
intention: "intention_01m6wb2n39ebt923b1jvk24qss"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-11-08T01:08:07Z
---

# Keep writes and maintenance jobs correct on a replicated cluster

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current during implementation. Record implementation friction through `agents/skills/exec-plan/FRICTION.md` and distill durable decisions into `docs/adr/` before completion.


## Purpose / Big Picture


Make Kansoku safe to write to and maintain on one ClickHouse shard with two replicas behind a connection-balancing endpoint. An erase-user or retention job must retain its persistent traffic fence until every expected replica has finished the relevant work. Writer acknowledgements must cover both replicas, and Kansoku's own read-back checks must observe completed writes. An owned two-replica acceptance command will demonstrate these guarantees with a held insert, replication lag, a stopped replica, a lost acknowledgement, and an interrupted rebuild.

This implements [IR-11](../../docs/improvement-requests/keep-writes-and-maintenance-jobs-correct-on-a-replicated-cluster.md). [Plan 62](../../docs/plans/62-run-clickhouse-migrations-on-a-replicated-cluster.md), implementing the replicated migration baseline, is a hard prerequisite for native acceptance. It is presently a plan, not an implemented capability. This plan is standalone; production deployment and managed-endpoint qualification remain separate. The requesting work is `mori://tan/tan-app-infrastructure/plans/45-onboard-kansoku-to-production-on-the-replicated-clickhouse-cluster`.


## Progress


- [ ] Milestone 1: Shared topology configuration, bound job identity, and an owned native two-replica roundtrip reject incomplete or changed replica coverage.
- [ ] Milestone 2: Quiescence, pre-discovery synchronization, and mutation verification cover every expected replica and retain the fence on failure.
- [ ] Milestone 3: Projection rebuilds survive interruption, synchronize all replicas, and verify canonical/public contents before release.
- [ ] Milestone 4: Explicit all-replica writer durability, retry behavior, and consistent read-back pass native failure cases while direct-mode behavior remains compatible.
- [ ] Milestone 5: The complete replicated acceptance recipe, direct regression checks, operations guidance, and durable architecture records describe the demonstrated guarantees.


## Surprises & Discoveries



## Decision Log


2026-11-08: Reuse Plan 62's explicit cluster name and expected server UUID set. Expected identities must come from configuration and the persisted job, not from whichever replicas happen to answer. Acquire and retain a native connection to each expected replica through the configured endpoint; an endpoint that cannot provide complete coverage fails closed.

2026-11-08: Choose synchronous inserts acknowledged by all configured replicas: for the requested two-replica deployment, `async_insert=0`, `insert_quorum=2`, and `insert_quorum_parallel=0`. A missing replica sacrifices write availability rather than weakening acknowledgement. This is replication durability, not a filesystem power-loss or cross-table transaction guarantee.

2026-11-08: Use explicit synchronization and per-replica verification for maintenance. Sequentially consistent SELECTs alone do not prove that mutations, truncation, or every materialized-view target has completed. Submit each replicated mutation or rebuild INSERT once, then verify all replicas; executing the same INSERT on each replica would duplicate work.

2026-11-08: Preserve the existing logical replay contract in ADR-4. Native block deduplication is finite and cannot replace canonical event identity or replay-safe aggregates. AC-3's prescribed ambiguous identical-batch test must additionally prove physical raw-row deduplication and correct values in every target. Do not describe that bounded proof as unlimited physical exactly-once storage. If the requested test fails, keep the criterion open and fix the delivery path; do not substitute a passing canonical count for the failing physical check.


## Outcomes & Retrospective



## Context and Orientation


A shard is one logical partition of data; replicas are servers holding copies of that partition. Keeper coordinates replication. A materialized view runs a SELECT on inserted blocks and writes derived data into a target table. Replicating a raw part is not a substitute for proving delivery to those targets. A mutation is an asynchronous table rewrite such as DELETE or UPDATE. A quorum is the number of replicas required to acknowledge an insert. The persistent fence is PostgreSQL state that prevents Kansoku traffic from starting while an administrative job is unfinished; backend termination does not remove it.

`kansoku-core/src/Kansoku/Admin/Jobs.hs` persists jobs, takes administrator lock `(726401,2)`, sets the fence, then takes exclusive traffic lock `(726401,1)`. `executeJob` drains raw writes before identity discovery, mutates source data, rebuilds projections, verifies, and atomically marks completion and clears the fence. Its stages are `created`, `discovered`, `disposed`, `sources-scrubbed`, `raw-mutated`, `rebuilt`, `verified`, and `complete`. Resume skips completed stages. Today these data jobs do not bind a ClickHouse replica inventory. Plan 62 adds topology-bearing identities for migration sessions; extend that shared representation to data jobs here.

`kansoku-core/src/Kansoku/Admin/ClickHouse.hs` owns `quiesceRawWrites`, `verifyMutations`, `discoverIdentity`, and `rebuildDerived`. The first two inspect local `system.processes` and `system.mutations`. Rebuild reads current installed view SELECTs and target columns, truncates fourteen targets, replays in dependency order from canonical facts, and compares canonical/public counts on one connection. Many DELETE/UPDATE commands in `Admin/Jobs.hs` already use `mutations_sync=2`; the missing guarantee is broader than adding that setting. `kansoku-core/src/Kansoku/PersonProperties.hs` also participates in erasure and must use the same maintenance connection policy.

`kansoku-core/src/Kansoku/ClickHouse.hs` owns native TLS, the dedicated writer connection, query pools, raw inserts, and `countEvents`/`selectEventProjections`. Writer connections set only `async_insert=0`. The vendored driver disposes failed connections; fresh writer handles must reapply all role settings. `kansoku-core/src/Kansoku/Writer/Recovery.hs` holds the same queued payloads during in-process recovery, with a thirty-second insert deadline. `kansoku-core/src/Kansoku/Writer/Run.hs` calls `rewriteQueuedEvents` inside traffic admission on every retry so maintenance dispositions and retention still apply. `kansoku-core/src/Kansoku/Writer/Batch.hs` acknowledges good messages only after insertion succeeds. Restart or queue redelivery can change batch boundaries.

`analytics.events_canonical` reads `events_raw FINAL`, which chooses one accepted event version before background merges. Aggregates such as event/page counts use unique event-ID states. Existing direct tests deliberately allow two physical raw copies but require one canonical fact. Thus physical block deduplication and logical event correctness are distinct assertions. The replica-local `system.parts` query in `kansoku-core/src/Kansoku/Identity/Cache.hs` estimates cache size, not maintenance completion; leave its behavior unchanged and document that boundary.

`kansoku-core/src/Kansoku/Config.hs` currently has no topology field. Plan 62 introduces `KANSOKU_CH_MIGRATION_CLUSTER` and `KANSOKU_CH_MIGRATION_REPLICA_IDS`, strict topology parsing, a replicated baseline, and an owned `just ch-migrations-replicated` recipe. Reuse its parser and identity rather than copying a second permissive parser. Native host/port/TLS settings remain independent of migration HTTP transport and credentials. Extract the shared topology type into the core package if Plan 62 initially locates it in the server package.

`scripts/admin_acceptance.py` exercises actual administrative commands against owned stores. `scripts/outage-acceptance.py` tests writer recovery. `scripts/acceptance.sh` exercises the packaged server. `kansoku-core/test/Kansoku/ClickHouseSpec.hs` already tests canonical replay before merges. `kansoku-core/kansoku-core.cabal`, `kansoku-server/kansoku-server.cabal`, `scripts/deterministic-tests.py`, and `justfile` select native versus deterministic checks. Keep new live tests explicitly owned and non-skipping.

Relevant decisions consulted are [ADR-2](../../docs/adr/0002-pipeline-observability-readiness-and-writer-recovery.md), which requires disposable failed connections and honest writer recovery; [ADR-4](../../docs/adr/0004-queryable-event-properties-and-identity-resolved-projection.md), which distinguishes canonical replay correctness from physical duplicates; [ADR-10](../../docs/adr/0010-owned-executable-acceptance-environments.md), which requires private disposable fixtures; [ADR-17](../../docs/adr/0017-fenced-resumable-administration-and-applied-retention.md), which owns persistent fences, dispositions, and whole-projection rebuilds; [ADR-18](../../docs/adr/0018-stable-reader-sql-and-real-consumer-conformance.md), which preserves reader contracts and requires external readers to honor maintenance; [ADR-22](../../docs/adr/0022-explicit-clickhouse-migrations-and-persistent-administrative-sessions.md), which owns immutable migration history and retained target identity; and [ADR-23](../../docs/adr/0023-verified-tls-for-native-clickhouse-connections.md), which requires verified TLS on every native connection.

Dependency discovery used Mori. Native settings are documented at `mori://KovalevDima/ClickHaskell/docs/settings`; the compiled implementation is `vendor/ClickHaskell/ClickHaskell/Statements.hs`, `vendor/ClickHaskell/ClickHaskell/Protocol/Settings.hs`, and `vendor/ClickHaskell/ClickHaskell.hs`. `passSettings` supports INSERT as well as SELECT; `addSetting` includes dependent-view deduplication and insert tokens. The migration fixture is `mori://shinzui/clickhouse-migrate/packages/clickhouse-migrate-test-support`. Additional inspected sources belong to `mori://shinzui/clickhouse-migrate`, project-relative `clickhouse-migrate/src/ClickHouseMigrate/Internal/ServerProfile.hs` and `clickhouse-migrate-test-support/src/ClickHouseMigrate/TestSupport/Server.hs` (artifact-level URIs pending). The replicated profile already combines quorum, serial quorum inserts, synchronous mutation/alter, and sequential reads. Its public fixture exposes HTTP observations and replica stop/start, not public native endpoint access; native wiring is an explicit deliverable below.

ClickHouse's [insert-retry guide](https://clickhouse.com/docs/guides/developer/deduplicating-inserts-on-retries) describes finite deduplication windows and uncertain materialized-view delivery after failed inserts. Its [SYSTEM reference](https://clickhouse.com/docs/sql-reference/statements/system#sync-replica) distinguishes strict queue draining from lightweight synchronization. These current documents are context, not a claim that newer settings exist in the exact Altinity candidate. Qualify the actual settings on `26.3.60.10002.altinitystable`, using Plan 62's exact image identity, before enabling replicated operation.


## Plan of Work


### Milestone 1 — Bind the runtime and each job to a complete replica set


Create `kansoku-core/src/Kansoku/ClickHouse/Topology.hs` and share its strict direct/replicated parser with `kansoku-server/src/Kansoku/ClickHouseMigration/Config.hs`. The runtime consumes the same cluster and replica-ID selectors as Plan 62; neither selects direct mode, both select replicated mode, partial/empty/malformed/duplicate sets fail before network work. Preserve Plan 62's migration-specific validation. Add the topology to `Config` and `ClickHouseConfig` and update construction sites. Runtime startup must reject a replicated application schema selected as direct, rather than silently using local-only maintenance checks; inspect engine metadata on the connected server. Direct schemas retain their present behavior.

Create `kansoku-core/src/Kansoku/ClickHouse/Consistency.hs` for role settings, bounded identity observation, and replica acquisition. For replicated administration, open fresh native connections through the configured endpoint, query `serverUUID()`, retain one handle for each configured UUID, and close duplicates. Bound acquisition to 35 seconds and 64 attempts with a short delay between repeated identities; close every acquired handle on any error. Missing or unexpected UUIDs fail with redacted expected/observed IDs. Verify the configured cluster has one shard and the same inventory, and that application tables are replicated. Neither a count of two nor a discovered subset establishes identity. Preserve certificate verification and endpoint hostname checks; do not redirect connections to untrusted hostnames returned by system tables.

Treat the resulting replica set as an operation-scoped resource. A failed handle invalidates the operation; do not reconnect it invisibly and continue a checkpoint. On resumed work, reacquire the full set and revalidate identities and topology. Keep one selected coordinator handle for statements issued once and each replica's own handle for local barriers and observations.

Append a PostgreSQL migration after Plan 62's final migration in `kansoku-core/src/Kansoku/Migrations.hs`. Persist the selected topology, cluster and canonical expected UUID set with new data jobs, using the shared identity encoding. Record it atomically with job creation/fence ownership and compare it on every resume before native work. Historical jobs without that field are direct-only; never adopt an unfinished direct job onto a replicated target. Preserve existing receipts, stages, and fences. A resume against a different cluster/set fails and names the mismatch without reducing job data.

Add deterministic tests in `kansoku-core/test/Kansoku/ClickHouse/TopologySpec.hs` for parsing, complete coverage, cleanup and settings selection, and PostgreSQL/native tests for job identity. Extend the owned recipe from Plan 62 with `scripts/replicated_clickhouse.py` as Kansoku's native-capable fixture boundary. If its upstream fixture still exposes only HTTP, implement the owned lifecycle in that adapter using the same exact image and Keeper configuration: bind each container's native port only to dynamically allocated loopback ports and add a native round-robin proxy. Own and record container/network/process identifiers and retain private logs. Do not import undocumented dependency files out of a build closure or traverse `/nix/store`. Bootstrap the full schema through the actual migration CLI, reusing Plan 62's migration/session harness.

Create `kansoku-server/test/ClickHouseReplicatedRuntime.hs` and `scripts/clickhouse_replicated_runtime_acceptance.py`. First prove the actual native driver can insert one event on replica A and perform a synchronized canonical/public read on B. Check effective settings, native UUID identity, restricted grants, and both endpoints. This bounded integration proof must pass before expanding fault cases. Failure to expose native ports or execute required synchronization under the intended account is a failed milestone, not a reason to replace native proof with HTTP-only assertions.


### Milestone 2 — Drain and verify every replica before advancing jobs


Pass the operation-scoped replica set through `withNative` and `executeJob` in `kansoku-core/src/Kansoku/Admin/Jobs.hs`. Keep lock order and the persistent fence unchanged. After exclusive traffic admission, run the existing raw INSERT predicate on every replica, retaining per-UUID observations. Repeat until all report zero within one sixty-second drain deadline. A nonresponse, malformed result, incomplete visibility, timeout, or changed identity fails closed. Missing permissions must never become an empty successful result. Document that the administrative account needs visibility into all Kansoku writer sessions. Unrelated shared-server query scoping remains the separate shared-server request.

After draining and before identity discovery, synchronize `events_raw` and every replicated source needed for identity, traits, cohorts, and retention on all replicas. Use `SYSTEM SYNC REPLICA ... STRICT` under the fence with explicit receive/query deadlines; also synchronize the Replicated database schema before reading installed definitions. This closes the case where an insert has ended on A but B has not fetched its raw or derived parts. Enumerate required tables from the current application schema and reviewed dependency list; a required absent or unexpected nonreplicated table fails. Do not apply SYNC REPLICA to views.

Set the maintenance profile on every newly opened physical connection: synchronous inserts, quorum equal to the expected replica count, serial quorum insertion, `mutations_sync=2`, `alter_sync=2`, sequential consistency, and bounded inactive-replica/quorum waits. Use a 60-second operation budget for each barrier or native maintenance statement; bound server waits inside that budget. Job-level work may legitimately take multiple budgets. Report timeout stage and replica, retain the fence, and allow deliberate resume. Keep direct-mode policy unchanged.

Replace local `verifyMutations` with complete per-replica verification. Return table/mutation identity, completion status and a redacted failure classification for every relevant unfinished mutation, including already-submitted work encountered on resume. An empty local mutation list only counts after that replica has consumed the relevant replication log. Poll within the deadline; a recorded mutation failure or unavailable replica fails with a named reason. Mutation submission remains once on the coordinator; settings are not proof without independent observations.

Milestone acceptance pins maintenance to B while a native insert is held open on A after registration in `system.processes`. Assert no discovery checkpoint or mutation occurs until the insert completes. Run again with A unreachable and with a mutation queue deliberately paused on A: the command waits or exits nonzero with its fence active and no completion receipt. Resume after restoring A and verify both identities participate. Test a permission-denied observation and an endpoint pinned to only one UUID as explicit rejection cases.


### Milestone 3 — Make rebuild and final verification safe across lag and restart


Refactor `rebuildDerived` to use the verified coordinator and full replica set. Read installed materialized-view definitions and ordered target columns after schema synchronization, check that the same definitions exist on every replica, and preserve the current canonical-source substitution and dependency order. Send TRUNCATE once per target, wait until all replicas have applied it, then replay each target once. Before replay reads a previously rebuilt dependency, synchronize that dependency on all replicas. Do not issue the whole rebuild independently on each replica.

Rebuild retries start by clearing all targets again. Disable insert-block deduplication for rebuild INSERT SELECT statements, including dependent-view deduplication where applicable, so a previous rebuild's deduplication entries cannot suppress rows after a new TRUNCATE. Scope these settings to rebuild statements; writer connections retain their own policy. This is safe only while the persistent fence excludes producers and every target is cleared before replay. Prove the interaction with chained identity views rather than assuming identical SQL or TRUNCATE resets all deduplication history.

After replay, drain replication queues and verify mutations on every replica, then compare canonical/public event counts on each replica and across replicas. Counts alone can hide equal-sized wrong populations: acceptance also compares ordered event identities and finalized aggregate values for the seeded fixture. Verify erasure/retention predicates on every replica, including raw identity/fingerprint fields, current traits, cohort membership and derived identity evidence. Retention-policy writes and source discovery must receive the same barriers as raw data.

Repeat final barriers and postconditions on every resume, even when a saved stage is already `rebuilt` or `verified`. A previous verification result is not permission to release a fence after a replica is replaced or unavailable. Only fresh complete coverage and all-replica postconditions allow the existing atomic PostgreSQL completion/release transaction. Preserve dispositions and re-evaluate held writer batches after release.

Milestone acceptance interrupts the admin process after a TRUNCATE and again after a rebuild INSERT has committed but before its PostgreSQL checkpoint. Resume each job and require the original canonical event set, correct finalized values in all fourteen targets on both replicas, and zero erased/expired evidence. Include a lagging replica and a stop immediately before final verification. No failed path may clear the fence, and no successful resume may skip a fresh final check.


### Milestone 4 — Qualify writer durability, retries and read-back consistency


Apply the replicated writer profile in `kansoku-core/src/Kansoku/ClickHouse.hs` when opening every writer connection: `async_insert=0`, `insert_quorum` equal to the configured replica count, `insert_quorum_parallel=0`, `insert_deduplicate=1`, `deduplicate_blocks_in_dependent_materialized_views=1`, and `materialized_views_ignore_errors=0`. Use a twenty-second server quorum timeout inside the existing thirty-second writer deadline. Read back effective settings and fail if the exact candidate or account refuses them. Do not silently downgrade to single-replica acknowledgement. Keep raw/direct fixture inserts compatible with existing direct-mode tests.

Retain deterministic native row ordering and block formation for retries of the same post-disposition batch. Do not add a batch-ID token derived only from event IDs: erasure can change the bytes submitted by a later attempt. If the native proof requires an explicit token, derive it from the complete ordered serialized payload and its serialization version, test changed dispositions, and record the change in this plan before adopting it. Neither token nor block deduplication replaces `rewriteQueuedEvents`, immutable event acceptance, or canonical aggregate semantics.

Exercise a server-committed insert whose success reply is deliberately withheld from Kansoku. Use a native proxy with an explicit arm/release control: after initial handshake/settings, hold server-to-client traffic for the INSERT completion and independently observe its committed data before closing the connection. Retry through the other replica with the actual writer recovery path. For this identical-batch case, assert one physical raw occurrence per event on both replicas without FINAL or OPTIMIZE and compare the complete expected finalized contents of every view target. Aggregating targets do not hold one row per event, so their assertion is the corresponding aggregate result, not a fabricated event-id column. Also inject a materialized-view failure, heal it, and verify the retry fills any missing target without double counting the successful ones.

Run restart/regrouped delivery, multiple native blocks, and deliberately shortened deduplication-window cases separately. Preserve ADR-4's logical event-once behavior in canonical reads and every relevant aggregate before merges. Report physical counts separately and do not extrapolate finite block deduplication to an unbounded physical exactly-once claim. If the real target semantics expose missing or duplicated logical contributions, repair that path and add the regression before accepting AC-3; a quorum-only change is insufficient.

Keep ordinary analytics reads explicitly eventually consistent with queued ingestion and replica progress. Add a dedicated read-back helper in `Kansoku.ClickHouse.Consistency` for Kansoku-owned smoke/verification flows: synchronize each replicated table that the check depends on on its acquired connection, use `select_sequential_consistency=1`, then execute the read on that same connection. A reconnect invalidates the barrier and restarts it. For public views include all underlying identity/trait sources, not just `events_raw`. Maintenance uses the stronger fenced all-replica protocol from Milestones 2–3. Do not put privileged SYSTEM commands in ordinary metrics requests.

Audit `countEvents` and `selectEventProjections` call sites, `scripts/admin_acceptance.py`, `scripts/outage-acceptance.py`, and the new replicated harness. Route immediate post-write assertions through the helper or the equivalent explicit same-connection SQL barrier. A fixed sleep or a random second connection is not evidence of read-your-write behavior. This contract starts after successful native writer acknowledgement; an HTTP ingest 202 only means PostgreSQL accepted the event.

Milestone acceptance stops B during writer batches and proves the queue remains unacknowledged until all-replica success; then restarts B and proves convergence. A write on A followed immediately by the production read-back helper on B must return the expected event and projections, or fail explicitly while B cannot catch up. Include fresh pooled connections and recovered writer connections so initialization cannot accidentally be one-time only.


### Milestone 5 — Publish reproducible acceptance and the operating contract


Add `just ch-runtime-replicated` to build the real server/admin/migration executables and native test driver and run `scripts/clickhouse_replicated_runtime_acceptance.py`. Support `--case topology`, `--case maintenance`, `--case rebuild`, `--case writer`, and `--case readback` for focused development; the default runs every case. The recipe must fail, rather than skip, if Docker, the exact qualified image, required grants, or prerequisite schema are unavailable. Reuse Plan 62's baseline initialization and identity inventory, while keeping fault injection local to the owned fixture.

Save a private structured report under `.dev/acceptance/` with image identity, effective per-role settings, both UUIDs, test outcomes, job stages/fence observations, per-replica physical/canonical counts, and aggregate comparisons. Commit only a redacted concise evidence document at `docs/evidence/replicated-runtime.md`. Evidence must distinguish source testing from packaged-executable testing; support `--packaged` in the recipe and run it for final acceptance. Include a clear success summary only when every scenario passed.

Update `docs/guides/operations.md`, `docs/guides/administration.md`, `docs/guides/consume-clickhouse.md`, and `docs/guides/clickhouse-migrations.md`. Explain configuration and required permissions, all-replica acknowledgement and its availability cost, finite block deduplication versus logical replay, eventual ordinary reads versus synchronized read-back, diagnostic replica identifiers, and the repair/resume procedure. State that external native writers and readers must be paused through maintenance; PostgreSQL admission cannot fence arbitrary external SQL. Note the cache-sizing estimate's replica-local nature. Do not imply this local proof qualifies a managed production endpoint.

Update relevant ADRs, especially ADR-4 and ADR-17, with the tested boundaries and new completion rules; preserve Plan 62's identity/history decisions in ADR-22. Follow `agents/skills/exec-plan/ADR.md` for profile/log maintenance and strict validation. Run the existing direct administration, outage smoke, native TLS, and normal deterministic gates to show that topology selection does not weaken single-server behavior. Triage recorded implementation friction and complete the outcome section only after all four source-request acceptance criteria have evidence.


## Concrete Steps


Run commands from the repository root, `/Users/shinzui/Keikaku/bokuno/kansoku-project/kansoku`. Implementation requires the Nix development environment, a local Docker daemon capable of the exact Linux candidate from Plan 62, and fresh owned PostgreSQL and Keeper resources. No ambient development or production database may be substituted.

Before implementation, read Plan 62's Progress and evidence. These commands must exist and pass after that prerequisite is implemented; they are not available in the current working tree:

```bash
nix develop --no-write-lock-file -c just ch-migrations-replicated
```

Expect the full replicated migration lifecycle to pass with two distinct UUIDs and the exact candidate recorded. If it is unavailable or incomplete, implement only independent parsing/tests here and leave dependent milestones unaccepted; do not claim the baseline already exists.

During development, register the new modules and suites, then run:

```bash
nix develop --no-write-lock-file -c just build-with-tests
nix develop --no-write-lock-file -c just deterministic-test
nix develop --no-write-lock-file -c python3 scripts/clickhouse_replicated_runtime_acceptance.py --case topology
nix develop --no-write-lock-file -c python3 scripts/clickhouse_replicated_runtime_acceptance.py --case maintenance
nix develop --no-write-lock-file -c python3 scripts/clickhouse_replicated_runtime_acceptance.py --case rebuild
nix develop --no-write-lock-file -c python3 scripts/clickhouse_replicated_runtime_acceptance.py --case writer
nix develop --no-write-lock-file -c python3 scripts/clickhouse_replicated_runtime_acceptance.py --case readback
```

Each new case command must initialize its own fixture and dependencies and exit zero only after its behavioral assertions pass. Implement the CLI options as specified rather than requiring a contributor to reconstruct hidden test state. The planned full-recipe summary is:

```text
Replicated runtime acceptance passed: topology, maintenance, rebuild, writer, readback; 2 replicas verified.
```

At final acceptance run:

```bash
nix develop --no-write-lock-file -c just ch-runtime-replicated
nix develop --no-write-lock-file -c python3 scripts/clickhouse_replicated_runtime_acceptance.py --packaged
nix develop --no-write-lock-file -c python3 scripts/admin_acceptance.py
nix develop --no-write-lock-file -c just outage-smoke
nix develop --no-write-lock-file -c just native-tls
nix develop --no-write-lock-file -c just check
nix develop --no-write-lock-file -c okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
nix develop --no-write-lock-file -c just guides-check
git diff --check
```

Keep failed-case private reports for diagnosis. After relevant fixes, repeat the affected cases and required final suite; a skipped case or missing candidate is not a passing result. These are implementation acceptance commands, not tests claimed to have run during plan creation.


## Validation and Acceptance


AC-1 is satisfied by a confirmed erase/retention command pinned to B remaining before discovery while an INSERT is visibly active on A, then proceeding only after complete all-replica drain. Assert the persistent PostgreSQL fence throughout; missing A, missing visibility, malformed observations, and wrong inventories produce named failures and no native mutation.

AC-2 requires erase-user and retention runs with delayed/stopped A, separate interrupted-rebuild runs, and independent final observations on both replicas. Every reported successful job must have no outstanding or failed applicable mutation, complete replicated rebuilds, matching canonical/public populations, and no forbidden erased/expired evidence. Resume from `verified` must still fail with a missing replica. Inspect the fence and job journal, not merely process exit status.

AC-3 requires the explicit quorum policy, no queue acknowledgement while a replica is unavailable, and the lost-acknowledgement identical-batch retry with exactly one physical raw copy on each replica plus correct finalized results in every view target. Materialized-view partial failure must recover without loss or double contribution. Regrouped/restarted and expired-window retries separately preserve existing logical semantics. Neither canonical FINAL alone nor eventual background merges may mask a failed physical assertion in the prescribed identical-batch test.

AC-4 requires an acknowledged write on A immediately followed by the actual synchronized read-back path on B, including dependent views and a fresh connection. With replication blocked it must wait or fail explicitly rather than return a stale successful assertion. Documentation states ordinary read consistency, the stronger read-back procedure, and that ingestion acceptance precedes native writing.

The first native cross-replica roundtrip is the integration gate before implementing the full matrix. Unit tests cover malformed configuration and policy selection; real processes prove server behavior, queue acknowledgement, lock/fence retention, and recovery. Direct-mode regression checks preserve existing physical-duplicate/canonical-singleton behavior, verified TLS, cancellation and connection disposal.


## Idempotence and Recovery


Use a fresh owned cluster and PostgreSQL database for each acceptance case. Fault controls may stop only recorded owned replicas/processes. Cleanup must restore paused replication/merges where the fixture remains alive, then remove only resources recorded by that fixture. Preserve private failure evidence and never reset a shared ClickHouse database or delete a migration ledger.

All production failures retain the persistent job fence. Restore reachability or permissions, verify the same configured inventory and external producer exclusion, then resume the original job through `kansoku-admin`; do not manually advance stages or clear the fence. A timeout is an uncertain native outcome, so resume first drains and synchronizes the full replica set. Repeating a destructive predicate remains idempotent; repeating a partial projection rebuild clears all targets and replays under the fence with fresh final verification.

Append schema migrations only. Never alter Plan 62's applied replicated baseline, the immutable direct migration files, or prior PostgreSQL migration bytes. Deployment rollback must not run an older binary that ignores the new replica identity/completion contract against unfinished replicated jobs. Keep traffic stopped and use the capable binary to finish/recover; data restoration requires the repository's separate coordinated backup procedure.


## Interfaces and Dependencies


The new shared topology type represents direct mode or a validated cluster name plus nonempty unique sorted UUID set. `Kansoku.ClickHouse.Topology` owns parsing and equality; migration configuration and runtime configuration adapt that shared value without importing a server module into core. The existing native connection settings and TLS code remain the only transport constructor.

`Kansoku.ClickHouse.Consistency` owns role-specific initialization and operation-scoped resources. Its public boundary must provide `withReplicaConnections`, `synchronizeTables`, and `withConsistentReadback` (names may be adjusted consistently while implementing). The first brackets complete identity-checked handles; the second takes explicit replicated table names and a deadline; the third synchronizes dependencies and reads on the same physical connection. `Kansoku.Admin.ClickHouse` receives the verified set rather than inferring topology from an arbitrary bare connection. All APIs propagate errors so callers retain fences and dispose broken resources.

No new library or dependency version is selected by this plan. Retain the repository's vendored ClickHaskell and Plan 62's migration/test-support cohort. Before any necessary bounds, pin, or compatibility-workaround change, use Mori to inspect sources and verify released versions with Hackage and upstream tags; registry snapshots alone are insufficient. Native fixture ports and synchronization grants are not assumed to exist in the dependency API. Implement the local owned adapter described in Milestone 1 or consume a separately qualified public fixture extension after explicit version verification.

Plan 62 must deliver the replicated schema, exact candidate, immutable identity representation, and working migration initialization before the native acceptance milestones here can complete. This plan adds application write/read/maintenance guarantees and does not certify deployment infrastructure, multi-shard routing, arbitrary external SQL, or automatic replica replacement.
