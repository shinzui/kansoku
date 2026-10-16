---
type: Capability
title: "Durable delivery and recovery"
description: "Drain a durable PostgreSQL queue into replay-safe ClickHouse facts with supervised batching and bounded storage-outage recovery."
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
---

# Durable delivery and recovery

Batch accepted events through the supervised writer, retain an unchanged batch during storage failure and pause further source consumption. Canonical logical reads and distinct event-ID states prevent physical redelivery changing analytical counts and sums. Malformed queued payloads are archived for inspection. See [operations](../guides/operations.md).

## Compatibility

Available in the current checkout. No release tags establish a released version, so since is unreleased. This experimental interface has no stable compatibility promise; pin the server and clients to a reviewed revision and regenerate contracts together.

## Limits

Delivery is at-least-once and depends on finite PostgreSQL disk/WAL capacity and eventual recovery. Acceptance is asynchronous; there is no fixed freshness SLA, global ordering or exactly-once physical insertion. External backup and database replication are operator owned.

## Requires

- [CAP-2 — Immutable event ingestion](immutable-event-ingestion.md).

## Evidence

- [outage-acceptance.py](../../scripts/outage-acceptance.py) — Defines the owned-store outage/restart acceptance and measured queue recovery.
- [RecoverySpec.hs](../../kansoku-core/test/Kansoku/Writer/RecoverySpec.hs) — Checks storage recovery behavior.
- [operations.md](../../docs/guides/operations.md) — Describes retained batches, backpressure, restart and dead-letter semantics.
