---
type: Capability
title: "Durable delivery and recovery"
description: "Drain a durable PostgreSQL queue into replay-safe ClickHouse facts with supervised batching and bounded storage-outage recovery."
timestamp: 2026-11-11T16:18:51Z
generated:
  by: process:codex
  at: "2026-10-16T13:11:11Z"
capabilityId: CAP-4
provider: mori://shinzui/kansoku
status: shipped
stability: experimental
since: unreleased
packages:
  - "kansoku-core"
  - "kansoku-server"
interface:
  - "kansoku-server"
  - "PostgreSQL PGMQ queue"
  - "ClickHouse analytics facts"
  - "KANSOKU_CLICKHOUSE_SECURE"
  - "KANSOKU_CH_MIGRATION_REPLICA_IDS"
tags: [ingestion]
requires:
  - CAP-2
evidence:
  - kind: conformance
    resource: "scripts/outage-acceptance.py"
    proves: "Defines the owned-store outage/restart acceptance and measured queue recovery."
  - kind: test
    resource: "kansoku-core/test/Kansoku/Writer/RecoverySpec.hs"
    proves: "Checks storage recovery behavior."
  - kind: guide
    resource: "docs/guides/operations.md"
    proves: "Describes retained batches, backpressure, restart and dead-letter semantics."
  - kind: conformance
    resource: "scripts/native-tls.py"
    proves: "Proves plaintext compatibility, verified native TLS and pre-authentication trust failures."
  - kind: conformance
    resource: "scripts/clickhouse_replicated_runtime_acceptance.py"
    proves: "Exercises the quorum writer policy, ambiguous retries through another replica and synchronized read-back on an owned two-replica cluster."
---

# Durable delivery and recovery

Batch accepted events through the supervised writer, retain an unchanged batch during storage failure and pause further source consumption. Canonical logical reads and distinct event-ID states prevent physical redelivery changing analytical counts and sums. Malformed queued payloads are archived for inspection. Native writer and query connections can require verified TLS (`KANSOKU_CLICKHOUSE_SECURE`) with CA and hostname checks and no plaintext fallback. With the cluster and complete replica-UUID selectors configured, every writer connection checks synchronous quorum insertion across all expected replicas, serial quorum and block deduplication before acknowledging the queue. See [operations](../guides/operations.md).

## Compatibility

Available in the current checkout. No release tags establish a released version, so since is unreleased. This experimental interface has no stable compatibility promise; pin the server and clients to a reviewed revision and regenerate contracts together.

## Limits

Delivery is at-least-once and depends on finite PostgreSQL disk/WAL capacity and eventual recovery. Acceptance is asynchronous; there is no fixed freshness SLA, global ordering or exactly-once physical insertion. On a replicated runtime a stopped replica blocks write acknowledgement, insert deduplication windows are finite and ordinary reads remain eventually consistent. External backup, replica provisioning and replacement are operator owned.

## Requires

- [CAP-2 — Immutable event ingestion](immutable-event-ingestion.md).

## Evidence

- [outage-acceptance.py](../../scripts/outage-acceptance.py) — Defines the owned-store outage/restart acceptance and measured queue recovery.
- [RecoverySpec.hs](../../kansoku-core/test/Kansoku/Writer/RecoverySpec.hs) — Checks storage recovery behavior.
- [operations.md](../../docs/guides/operations.md) — Describes retained batches, backpressure, restart and dead-letter semantics.
- [native-tls.py](../../scripts/native-tls.py) — Proves plaintext compatibility, verified native TLS and pre-authentication trust failures.
- [clickhouse_replicated_runtime_acceptance.py](../../scripts/clickhouse_replicated_runtime_acceptance.py) — Exercises the quorum writer policy, ambiguous retries through another replica and synchronized read-back on an owned two-replica cluster.
