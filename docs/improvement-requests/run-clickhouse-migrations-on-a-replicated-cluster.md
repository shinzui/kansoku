---
type: Improvement Request
title: Run ClickHouse migrations on a replicated cluster
description: Let kansoku-ch-migrate select clickhouse-migrate's replicated target from its environment and run a separate replicated baseline with Replicated*MergeTree engines and a fresh v2 ledger, leaving the direct target and its bound history unchanged, so Kansoku can initialise and upgrade its schema on TAN's two-replica production ClickHouse cluster.
generated:
  by: process:claude-code
  at: "2026-11-08T00:00:15Z"
requestId: IR-10
status: completed
completedAt: "2026-11-08T02:31:43Z"
resolution: >-
  AC-1 through AC-5 delivered by plan 62: the direct history keeps the 2008b67 25/257 v1
  plan; cluster and replica settings select a validated replicated target with a separate
  replicated baseline and a fresh v2 ledger, and fresh initialization checks every
  replica. just ch-migrations-replicated passed 13 owned cases plus the Nix-packaged full
  lifecycle on the two-replica 26.3.60.10002.altinitystable candidate (commits df07621,
  f5a37ca).
targetPlan: docs/plans/62-run-clickhouse-migrations-on-a-replicated-cluster.md
origin: mori://tan/tan-app-infrastructure/plans/45-onboard-kansoku-to-production-on-the-replicated-clickhouse-cluster
acceptanceCriteria:
  - id: AC-1
    statement: With KANSOKU_CH_MIGRATION_CLUSTER unset, kansoku-ch-migrate builds the direct target exactly as at 2008b67 and plans the same 25 migrations / 257 native steps with unchanged v1 checksums against the existing ledger.
    verification: An offline plan comparison against the 2008b67 CLI shows every existing JSON field and every migration and step v1 checksum unchanged, and scripts/check_clickhouse_conversion.py still passes for the original history.
  - id: AC-2
    statement: With KANSOKU_CH_MIGRATION_CLUSTER and KANSOKU_CH_MIGRATION_REPLICA_IDS set, kansoku-ch-migrate builds clickhouse-migrate's replicatedTargetConfig with that cluster name and replica server UUIDs, refuses an empty, duplicate or malformed replica list before connecting, and refuses KANSOKU_CH_MIGRATION_SERVER_ID in the same environment.
    verification: Config unit tests cover the direct, replicated and refused combinations, and the CLI's status JSON names the topology, cluster and replica set.
  - id: AC-3
    statement: A replicated target runs a separate replicated baseline whose tables use only argument-free Replicated{Replacing,Aggregating}MergeTree engines (no Keeper paths, ON CLUSTER or CREATE DATABASE), producing the same analytics schema, views and query results as the direct history.
    verification: A schema comparison of analytics after the direct history and after the replicated baseline shows identical columns, sorting keys and view definitions apart from engine names, and the existing query/metrics example suites pass against a replicated-baseline database.
  - id: AC-4
    statement: On a replicated target the ledger is a fresh checksum v2 ledger in the pre-existing Replicated database kansoku_migration_ledger, and fresh-initialization checks verify every listed replica rather than one server UUID.
    verification: Initialising against a fixture where one listed UUID is absent, or where the ledger database is missing or Atomic, is refused before any application SQL.
  - id: AC-5
    statement: The full native lifecycle passes on a one-shard, two-replica cluster of the exact Altinity 26.3.60.10002.altinitystable candidate with Keeper and an app user whose profile fixes database_replicated_allow_only_replicated_engine to 1.
    verification: A new just recipe using clickhouse-migrate-test-support's withReplicatedCandidate on altinity-linux-arm64-10002 runs maintenance begin, up --initialize-ledger, verify --require-current --guarded and finish; a repeat sends zero application SQL; the Memory-engine native assertion steps 0017/13 and 0017/14 pass; and every table, row and ledger event is present on both replicas when read with queryReplica.
reviews:
  - kind: model
    reviewer: process:claude-code
    reviewed_at: "2026-11-08T00:00:15Z"
    document_timestamp: "2026-11-08T00:00:15Z"
    scope: content-and-metadata
    outcome: commented
    provider: anthropic
    model: claude-opus-5-5
    effort: unspecified
    context: >-
      Author review against Kansoku 2008b67 (ClickHouseMigration/Config.hs and the executed
      steps under kansoku-server/migrations/clickhouse/steps), clickhouse-migrate 0e75c4c
      (TargetTypes.hs, Target.hs, Preflight.hs, ServerProfile.hs, docs/user/authoring.md,
      operations.md and compatibility.md) and tan-infrastructure plan 6's production
      replication check. Nothing was run against a server; no independent verification
      attestation is claimed.
---

# Run ClickHouse migrations on a replicated cluster

**Authored by:** a `claude-code` session in `mori://tan/tan-app-infrastructure`, planning
Kansoku's production onboarding
(`mori://tan/tan-app-infrastructure/plans/45-onboard-kansoku-to-production-on-the-replicated-clickhouse-cluster`).
**Addressed to:** `shinzui/kansoku` agents.
**Created:** 2026-11-08.

**Implementation plan:** [ExecPlan 62: Run ClickHouse migrations on a replicated cluster](../plans/62-run-clickhouse-migrations-on-a-replicated-cluster.md).
Completed by Plan 62 on 2026-11-08; see `resolution` (status reconciled on 2026-11-13).

This is the first of a set filed together for production onboarding. The other two are IR-11 in
this bundle (runtime and maintenance jobs on a replicated cluster) and IR-12 (accepting the
production target). The requesting plan's Milestone 1 consumes all three.


## Why

TAN's production ClickHouse is `tan-production` on Altinity.Cloud: one shard, two replicas,
`26.3.60.10002.altinitystable`, and replicated Keeper. tan-app-infrastructure creates every
app database there with the `Replicated` engine `ON CLUSTER`. Every app role gets a settings
profile that fixes `database_replicated_allow_only_replicated_engine = 1`. The point is that no
table can quietly keep its rows on just one replica. tan-infrastructure plan 6 checked this
live on 2026-11-06: in such a database, plain `MergeTree` is refused with Code 56, and a
`ReplicatedMergeTree` row reads back on both replicas.

Kansoku cannot migrate that cluster today, for these reasons:

- **The target is always direct.**
  `kansoku-server/src/Kansoku/ClickHouseMigration/Config.hs:73-77` always calls
  `T.targetConfig`, with one `KANSOKU_CH_MIGRATION_SERVER_ID`. The 0.1.1.0 upgrade (`2008b67`)
  says so itself: "adopting this dependency does not enable its new replicated-target mode."
- **Every table would be refused.** The executed steps create 22 `AggregatingMergeTree` and 9
  `ReplacingMergeTree` tables, and ClickHouse does not convert plain engines to replicated ones.
- **The first three steps would be refused.** Steps `0001_events_raw`, `0002_identity` and
  `0003_rollups` begin with `CREATE DATABASE IF NOT EXISTS analytics`. clickhouse-migrate's
  replicated preflight refuses a pending `CREATE DATABASE`
  (`clickhouse-migrate/src/ClickHouseMigrate/Internal/Preflight.hs:56-64`).
- **The bound history cannot simply be edited.** A replicated target requires a fresh checksum
  v2 ledger and refuses to adopt older history (clickhouse-migrate `docs/user/operations.md:150`).
  Staging's applied v1 history binds today's SQL by checksum.
- **The fresh-initialization check covers one server.** `ensureFreshInitialization`
  (`Config.hs:106-112`) compares one `serverUUID()` with one configured ID.

TAN keeps staging (`tan-staging`, one replica) on its existing `Atomic` databases and direct
target. That was the operator's choice on 2026-11-07. So staging will keep running today's
history, and production needs the replicated path next to it.


## Requested change

- **Select the topology from the environment.** Add `KANSOKU_CH_MIGRATION_CLUSTER` (the
  cluster macro, for example `tan-production`) and `KANSOKU_CH_MIGRATION_REPLICA_IDS` (every
  replica's `serverUUID()`, comma-separated). When both are set, build
  `replicatedTargetConfig`. When neither is set, keep today's direct target byte-for-byte. Any
  other combination is a configuration error. The names are a proposal. If Kansoku picks
  others, tell the requesting plan, whose Interfaces section names them.
- **Ship a separate replicated baseline.** Its schema matches today's history, but it uses
  argument-free `Replicated*MergeTree` engines and has no `CREATE DATABASE`. The databases
  already exist, because the platform creates them. Select it by topology, and keep the
  original 25-migration history untouched for direct targets. clickhouse-migrate's
  `docs/user/authoring.md:79-94` recommends this kind of explicit replicated baseline.
  Extend the source-conversion and embedding checks to cover both sets.
- **Initialise a fresh v2 ledger** in the existing `kansoku_migration_ledger` database on
  replicated targets, and make the fresh-initialization check cover every listed replica.
- **Add two-replica acceptance.** Kansoku's test suite already depends on
  `clickhouse-migrate-test-support ==0.1.1.0`, which exports `withReplicatedCandidate`,
  `queryReplica`, `stopReplica` and `startReplica`. Its `replicated_fixture.py` creates its own
  app and ledger database names, so the recipe needs a way to point the baseline at them, or
  the fixture needs `analytics`. Today `just ch-migrations-component` and
  `just ch-migrations-acceptance` run on one server only.
- **Document the topology.** Update `docs/guides/clickhouse-migrations.md` and
  `docs/evidence/clickhouse-migrate-adoption.md` to describe both topologies and record the
  replicated evidence.


## Notes

- **The `Memory` assertion tables are probably allowed.** The native assertions create
  `analytics.__chm_legacy_assert_0017_13` and `_14` with `ENGINE=Memory`. Code 56's text
  allows "tables which do not store data on disk", and SQL envelope v2 does not refuse them,
  but nothing has tested this. AC-5 asks for proof. Rows inserted by the matching `-check`
  steps exist only on the replica that served the insert, which looks harmless because nothing
  reads them back.
- **The managed endpoint is not certified.** clickhouse-migrate treats a single load-balanced
  endpoint as a design target and exercises one in its fixture, but does not certify managed
  clouds (`docs/user/compatibility.md:36-41`). It checks every connection's UUID and refuses on
  a mismatch, so it fails closed. The requesting plan's first contact with `tan-production` is
  a read-only `status` Job before anything is initialised. IR-12 covers accepting this risk.
- **The deployment side stays in TAN.** The requesting plan passes the cluster, replica UUIDs
  and a newly allocated ledger UUID through its reviewed operation inputs. Kansoku should not
  discover them at run time.
