---
type: Term
title: "send time"
description: "The optional producer delivery timestamp used to correct future occurrence-time skew at acceptance."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-13
status: current
tags: [events]
aliases:
  - "sentAt"
related:
  - TERM-11
  - TERM-12
  - TERM-17
anchors:
  - kind: doc
    resource: "docs/guides/send-events.md"
---

# send time

The optional producer delivery timestamp used to correct future occurrence-time skew at acceptance.

When sentAt is at or after a future occurredAt, their elapsed difference can be subtracted from the server receipt time. The field is consumed at ingest and not retained in the event queue or ClickHouse. It is excluded from immutable producer identity so uncertain delivery can be retried.

Related: [occurrence time](occurrence-time.md), [receipt time](receipt-time.md), [immutable acceptance](immutable-acceptance.md).

## References

- [docs/guides/send-events.md](../../docs/guides/send-events.md).
