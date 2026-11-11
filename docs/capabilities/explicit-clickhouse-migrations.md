---
type: Capability
title: "Explicit ClickHouse migrations"
description: "Initialize and upgrade direct or replicated ClickHouse targets through fenced, resumable native migration sessions with retained ledger identities."
timestamp: 2026-11-11T16:18:51Z
generated:
  by: process:claude-code
  at: "2026-11-11T16:18:51Z"
capabilityId: CAP-20
provider: mori://shinzui/kansoku
status: shipped
stability: experimental
since: unreleased
packages:
  - "kansoku-core"
  - "kansoku-server"
interface:
  - "kansoku-ch-migrate"
  - "KANSOKU_CH_MIGRATION_SERVER_ID"
  - "KANSOKU_CH_MIGRATION_CLUSTER"
  - "KANSOKU_CH_MIGRATION_REPLICA_IDS"
tags: [operations]
requires:
  - CAP-16
evidence:
  - kind: conformance
    resource: "scripts/clickhouse_migrations_acceptance.py"
    proves: "Exercises the packaged CLI and coordinator boundary on owned stores without ambient targets."
  - kind: conformance
    resource: "scripts/clickhouse_replicated_migrations_acceptance.py"
    proves: "Exercises replicated initialization and replica coverage on an owned two-replica fixture."
  - kind: test
    resource: "kansoku-server/test/ClickHouseMigrationConfig.hs"
    proves: "Checks direct and replicated topology selector parsing and refusal of partial or malformed inventories."
  - kind: guide
    resource: "docs/guides/clickhouse-migrations.md"
    proves: "Specifies fresh initialization, ledger identities, drain, interruption receipts, replicated targets and recovery."
---

# Explicit ClickHouse migrations

Apply compiled native ClickHouse plans with `kansoku-ch-migrate` after PostgreSQL migrations; normal server startup applies neither. Each attempt runs inside a persistent PostgreSQL maintenance session that requires deliberate ledger initialization, predecessor and quiescence evidence and external drain, and retains exact receipts for explicit recovery. Supplying both the cluster and complete replica-UUID selectors selects a separate replicated history and ledger on pre-created Replicated databases; omitting both keeps the direct history. The runtime and data-job CLI reuse the same topology selectors. See [ClickHouse migrations](../guides/clickhouse-migrations.md).

## Compatibility

Available in the current checkout. No release tags establish a released version, so since is unreleased. This experimental interface has no stable compatibility promise; pin the server and clients to a reviewed revision and regenerate contracts together.

## Limits

A direct ledger cannot be adopted or converted to replicated, and changing the cluster or any replica UUID refuses a retained session. Drain evidence must cover every replica and submitting client, including external SQL; failed observations never release the fence. Qualification covers owned self-managed ClickHouse 26.8 and specific Altinity 26.3 servers, not managed-cloud or proxy topologies. The replicated baseline alone does not establish runtime write, read or maintenance consistency.

## Requires

- [CAP-16 — Resumable administration and data lifecycle](administrative-lifecycle.md).

## Evidence

- [clickhouse_migrations_acceptance.py](../../scripts/clickhouse_migrations_acceptance.py) — Exercises the packaged CLI and coordinator boundary on owned stores without ambient targets.
- [clickhouse_replicated_migrations_acceptance.py](../../scripts/clickhouse_replicated_migrations_acceptance.py) — Exercises replicated initialization and replica coverage on an owned two-replica fixture.
- [ClickHouseMigrationConfig.hs](../../kansoku-server/test/ClickHouseMigrationConfig.hs) — Checks direct and replicated topology selector parsing and refusal of partial or malformed inventories.
- [clickhouse-migrations.md](../../docs/guides/clickhouse-migrations.md) — Specifies fresh initialization, ledger identities, drain, interruption receipts, replicated targets and recovery.
