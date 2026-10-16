---
type: Term
title: "immutable acceptance"
description: "The rule that an account/event ID retains its first accepted producer payload and normalization across retries."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-17
status: current
tags: [ingestion]
related:
  - TERM-2
  - TERM-18
  - TERM-24
anchors:
  - kind: doc
    resource: "docs/guides/send-events.md"
  - kind: file
    resource: "kansoku-core/test/Kansoku/Ingest/AcceptanceSpec.hs"
---

# immutable acceptance

The rule that an account/event ID retains its first accepted producer payload and normalization across retries.

Acceptance records a canonical hash and publishes to the queue in one PostgreSQL transaction. Object key order and equivalent JSON numbers do not cause conflicts; delivery clocks and the ignored producer account are excluded. Other changed producer fields, including unknown fields, require a new ID. Erasure preserves minimal identity to prevent replay restoration.

Related: [event ID](event-id.md), [acceptance ledger](acceptance-ledger.md), [replay](replay.md).

## References

- [docs/guides/send-events.md](../../docs/guides/send-events.md).
- [kansoku-core/test/Kansoku/Ingest/AcceptanceSpec.hs](../../kansoku-core/test/Kansoku/Ingest/AcceptanceSpec.hs).
