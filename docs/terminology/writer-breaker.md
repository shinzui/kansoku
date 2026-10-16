---
type: Term
title: "writer breaker"
description: "The writer recovery state that parks an unchanged batch and pauses source consumption when insertion cannot proceed."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-25
status: current
tags: [ingestion]
related:
  - TERM-21
  - TERM-23
anchors:
  - kind: doc
    resource: "docs/guides/operations.md"
  - kind: file
    resource: "kansoku-core/src/Kansoku/Writer/Recovery.hs"
---

# writer breaker

The writer recovery state that parks an unchanged batch and pauses source consumption when insertion cannot proceed.

Storage unavailability triggers probes and retry while the batch is retained. A successful ping permits another insert attempt; only a successful insert reopens consumption. A rejected schema/SQL insert has a distinct breaker state and requires repair. Queue disk/WAL capacity still bounds survivable outage duration.

Related: [at-least-once delivery](at-least-once-delivery.md), [archive](archive.md).

## References

- [docs/guides/operations.md](../../docs/guides/operations.md).
- [kansoku-core/src/Kansoku/Writer/Recovery.hs](../../kansoku-core/src/Kansoku/Writer/Recovery.hs).
