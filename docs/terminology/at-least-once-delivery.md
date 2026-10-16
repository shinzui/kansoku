---
type: Term
title: "at-least-once delivery"
description: "The queue-to-writer policy under which an accepted event can be delivered physically more than once."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-21
status: current
tags: [ingestion]
related:
  - TERM-2
  - TERM-22
  - TERM-25
anchors:
  - kind: doc
    resource: "docs/guides/operations.md"
  - kind: doc
    resource: "docs/guides/send-events.md"
---

# at-least-once delivery

The queue-to-writer policy under which an accepted event can be delivered physically more than once.

A restart or lost insert acknowledgement can cause redelivery. Canonical event identity and replay-safe aggregates keep those copies from inflating analytical values. This does not promise exactly-once physical storage, unlimited outage tolerance or immediate visibility after HTTP acceptance.

Related: [event ID](event-id.md), [canonical fact](canonical-fact.md), [writer breaker](writer-breaker.md).

## References

- [docs/guides/operations.md](../../docs/guides/operations.md).
- [docs/guides/send-events.md](../../docs/guides/send-events.md).
