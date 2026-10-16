---
type: Capability
title: "Resumable administration and data lifecycle"
description: "Preview and confirm fenced erasure, retention and archive maintenance with durable job status and safe resumption."
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
    resource: "scripts/admin_acceptance.py"
    proves: "Exercises fenced maintenance, replay, revocation, rejection inspection and lifecycle cleanup."
  - kind: guide
    resource: "docs/guides/administration.md"
    proves: "Specifies confirmation, receipts, cutoffs, failure fences and resumption."
---

# Resumable administration and data lifecycle

Persist maintenance jobs and a global fence across both stores. Distinguish identity unlinking from explicit-fact deletion, scrub replayable inputs and rebuild current projections before completion. Apply an event cutoff and separate fingerprint cleanup. Transactionally replay archives with a permanent replay ledger; inspect and purge bounded rejection/archive sets.

## Compatibility

Available in the current checkout. No release tags establish a released version, so since is unreleased. This experimental interface has no stable compatibility promise; pin the server and clients to a reviewed revision and regenerate contracts together.

## Limits

Destructive commands preview until --confirm. Failures retain the fence and require resume; receipts cannot restore deleted data. Retention configuration alone performs no maintenance. Logical acceptance identities remain indefinitely. External SQL consumers, exports and backups require separate lifecycle coordination.

## Requires

- [CAP-4 — Durable delivery and recovery](durable-delivery-recovery.md).

## Evidence

- [admin_acceptance.py](../../scripts/admin_acceptance.py) — Exercises fenced maintenance, replay, revocation, rejection inspection and lifecycle cleanup.
- [administration.md](../../docs/guides/administration.md) — Specifies confirmation, receipts, cutoffs, failure fences and resumption.
