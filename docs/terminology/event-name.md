---
type: Term
title: "event name"
description: "The behaviour label used to select an event’s schema and analytical meaning."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-3
status: current
tags: [events]
aliases:
  - "eventName"
related:
  - TERM-2
  - TERM-9
anchors:
  - kind: doc
    resource: "docs/guides/send-events.md"
  - kind: file
    resource: "kansoku-api/src/Kansoku/Event/Registry.hs"
---

# event name

The behaviour label used to select an event’s schema and analytical meaning.

For example, page_view selects the declared page-view contract, while payment_completed drives revenue. An undeclared name can be accepted without property-schema checks. The name does not uniquely identify an occurrence; many events share it.

Related: [event ID](event-id.md), [schema version](schema-version.md).

## References

- [docs/guides/send-events.md](../../docs/guides/send-events.md).
- [kansoku-api/src/Kansoku/Event/Registry.hs](../../kansoku-api/src/Kansoku/Event/Registry.hs).
