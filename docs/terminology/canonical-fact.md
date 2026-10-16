---
type: Term
title: "canonical fact"
description: "The single logical retained event used by analytics after physical duplicate deliveries are removed."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-22
status: current
tags: [ingestion]
related:
  - TERM-2
  - TERM-17
  - TERM-21
anchors:
  - kind: doc
    resource: "docs/guides/operations.md"
  - kind: doc
    resource: "docs/guides/consume-clickhouse.md"
---

# canonical fact

The single logical retained event used by analytics after physical duplicate deliveries are removed.

ClickHouse can contain duplicate physical raw rows before background merges. Canonical reads select one account/event fact before sums, averages, sessions and identity joins. Logical idempotency therefore does not wait for merging or depend solely on an insert-block deduplication window.

Related: [event ID](event-id.md), [immutable acceptance](immutable-acceptance.md), [at-least-once delivery](at-least-once-delivery.md).

## References

- [docs/guides/operations.md](../../docs/guides/operations.md).
- [docs/guides/consume-clickhouse.md](../../docs/guides/consume-clickhouse.md).
