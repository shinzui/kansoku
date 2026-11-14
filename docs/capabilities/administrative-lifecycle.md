---
type: Capability
title: "Resumable administration and data lifecycle"
description: "Preview and confirm fenced erasure, retention and archive maintenance with durable job status and safe resumption."
timestamp: 2026-11-14T02:13:45Z
generated:
  by: process:codex
  at: "2026-10-16T13:11:11Z"
capabilityId: CAP-16
provider: mori://shinzui/kansoku
status: shipped
stability: experimental
since: unreleased
packages:
  - "kansoku-core"
  - "kansoku-server"
interface:
  - "kansoku-admin erase-user"
  - "kansoku-admin apply-retention"
  - "kansoku-admin replay-archive"
  - "kansoku-admin resume-job"
  - "kansoku-admin list-rejections"
tags: [operations]
requires:
  - CAP-4
evidence:
  - kind: conformance
    resource: "scripts/shared_clickhouse_maintenance_acceptance.py"
    proves: "Exercises two generic shared-server roles with portable drain, recoverable backups, scoped maintenance and read-only restore inspection."
  - kind: conformance
    resource: "scripts/nagare_shared_clickhouse_maintenance_acceptance.py"
    proves: "Exercises actual reviewed local Nagare quiesce, signed backups and scratch restores while another app continues querying without a server restart."
  - kind: conformance
    resource: "scripts/admin_acceptance.py"
    proves: "Exercises fenced maintenance, replay, revocation, rejection inspection and lifecycle cleanup."
  - kind: guide
    resource: "docs/guides/administration.md"
    proves: "Specifies confirmation, receipts, cutoffs, failure fences and resumption."
  - kind: conformance
    resource: "scripts/clickhouse_replicated_runtime_acceptance.py"
    proves: "Exercises replicated job identity, all-replica drain, rebuild verification and resumption."
---

# Resumable administration and data lifecycle

Persist maintenance jobs and a global fence across both stores. Distinguish identity unlinking from explicit-fact deletion, scrub replayable inputs and rebuild current projections before completion. Apply an event cutoff and separate fingerprint cleanup. Transactionally replay archives with a permanent replay ledger; inspect and purge bounded rejection/archive sets. On a replicated cluster, a confirmed job binds the complete expected replica inventory with its fence, drains and synchronizes every replica before rebuilding, and requires fresh checks on all replicas before release.

The portable shared-server path combines a persistent fence with fresh external
drain bound to the exact maintenance owner. Native pending migrations require a
complete PostgreSQL plus analytics/native-ledger recovery set. Read-only scratch
verification distinguishes current history from physical schema agreement and
grants no mutation authority. Generic and actual local Nagare ceremonies pass;
Nagare is an optional deployment integration.

## Compatibility

Available in the current checkout. No release tags establish a released version, so since is unreleased. This experimental interface has no stable compatibility promise; pin the server and clients to a reviewed revision and regenerate contracts together.

## Limits

Destructive commands preview until --confirm. Failures retain the fence and require resume; receipts cannot restore deleted data. Retention configuration alone performs no maintenance. Logical acceptance identities remain indefinitely. External SQL consumers, exports and backups require separate lifecycle coordination. Replicated maintenance needs an endpoint exposing every expected replica plus synchronization grants; a timeout leaves the fence active until the same replicas resume.

## Requires

- [CAP-4 — Durable delivery and recovery](durable-delivery-recovery.md).

## Evidence

- [admin_acceptance.py](../../scripts/admin_acceptance.py) — Exercises fenced maintenance, replay, revocation, rejection inspection and lifecycle cleanup.
- [administration.md](../../docs/guides/administration.md) — Specifies confirmation, receipts, cutoffs, failure fences and resumption.
- [clickhouse_replicated_runtime_acceptance.py](../../scripts/clickhouse_replicated_runtime_acceptance.py) — Exercises replicated job identity, all-replica drain, rebuild verification and resumption.

- [shared_clickhouse_maintenance_acceptance.py](../../scripts/shared_clickhouse_maintenance_acceptance.py) — Generic joined shared-server proof.
- [nagare_shared_clickhouse_maintenance_acceptance.py](../../scripts/nagare_shared_clickhouse_maintenance_acceptance.py) — Actual reviewed local platform proof.
