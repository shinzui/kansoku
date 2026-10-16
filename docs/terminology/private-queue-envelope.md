---
type: Term
title: "private queue envelope"
description: "The versioned internal delivery record that preserves an accepted event and its ingestion-derived decisions for the writer."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-20
status: current
tags: [ingestion]
related:
  - TERM-17
  - TERM-21
  - TERM-24
anchors:
  - kind: doc
    resource: "docs/guides/web-enrichment.md"
  - kind: file
    resource: "kansoku-core/src/Kansoku/Ingest/QueuedEvent.hs"
---

# private queue envelope

The versioned internal delivery record that preserves an accepted event and its ingestion-derived decisions for the writer.

The queue envelope retains accepted enrichment and schema eligibility rather than letting replay reinterpret original requests under new rules. It is not the public producer JSON contract. Earlier development envelopes remain readable with their documented version-zero/unknown categories.

Related: [immutable acceptance](immutable-acceptance.md), [at-least-once delivery](at-least-once-delivery.md), [replay](replay.md).

## References

- [docs/guides/web-enrichment.md](../../docs/guides/web-enrichment.md).
- [kansoku-core/src/Kansoku/Ingest/QueuedEvent.hs](../../kansoku-core/src/Kansoku/Ingest/QueuedEvent.hs).
