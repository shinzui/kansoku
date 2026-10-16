---
type: Term
title: "analytics event"
description: "A producer observation of behaviour carried in Kansoku’s canonical event envelope."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-1
status: current
tags: [events]
related:
  - TERM-2
  - TERM-3
  - TERM-14
  - TERM-15
anchors:
  - kind: doc
    resource: "docs/guides/send-events.md"
  - kind: file
    resource: "kansoku-api/src/Kansoku/Event/Types.hs"
---

# analytics event

A producer observation of behaviour carried in Kansoku’s canonical event envelope.

An event combines a name, producer event ID, source, timestamps and JSON properties/context, with optional identity and attribution. For example, a payment_completed event observes a payment; Kansoku does not execute the payment or own its business state. Unknown envelope fields are not promised persistence.

Related: [event ID](event-id.md), [event name](event-name.md), [event property](event-property.md), [event context](event-context.md).

## References

- [docs/guides/send-events.md](../../docs/guides/send-events.md).
- [kansoku-api/src/Kansoku/Event/Types.hs](../../kansoku-api/src/Kansoku/Event/Types.hs).
