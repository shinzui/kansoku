---
type: Term
title: "receipt time"
description: "The server-assigned time of first event acceptance."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-12
status: current
tags: [events]
aliases:
  - "receivedAt"
related:
  - TERM-11
  - TERM-17
  - TERM-32
anchors:
  - kind: doc
    resource: "docs/guides/send-events.md"
  - kind: doc
    resource: "docs/guides/query-metrics.md"
---

# receipt time

The server-assigned time of first event acceptance.

Kansoku replaces receivedAt at ingest. The first accepted receipt time participates in current-trait tie breaking after occurrence time; later delivery attempts do not change it. Receipt time differs from when the writer commits the event to ClickHouse and from occurrence time.

Related: [occurrence time](occurrence-time.md), [immutable acceptance](immutable-acceptance.md), [current person trait](current-person-trait.md).

## References

- [docs/guides/send-events.md](../../docs/guides/send-events.md).
- [docs/guides/query-metrics.md](../../docs/guides/query-metrics.md).
