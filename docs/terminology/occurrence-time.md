---
type: Term
title: "occurrence time"
description: "The accepted time at which an observation happened, used for analytical ordering and buckets."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-11
status: current
tags: [events]
aliases:
  - "occurredAt"
related:
  - TERM-12
  - TERM-13
  - TERM-17
anchors:
  - kind: doc
    resource: "docs/guides/send-events.md"
---

# occurrence time

The accepted time at which an observation happened, used for analytical ordering and buckets.

The occurredAt field originates with the producer. Ingest preserves past occurrences, can correct future clock skew using sentAt, and otherwise clamps a future value within tolerance or rejects it. Storage keeps milliseconds. Equal retries reuse first acceptance rather than recalculating the time.

Related: [receipt time](receipt-time.md), [send time](send-time.md), [immutable acceptance](immutable-acceptance.md).

## References

- [docs/guides/send-events.md](../../docs/guides/send-events.md).
