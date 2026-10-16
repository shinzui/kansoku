---
type: Term
title: "event context"
description: "The event’s JSON context object carrying supplementary producer metadata."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-15
status: current
tags: [events]
aliases:
  - "context"
related:
  - TERM-14
  - TERM-58
anchors:
  - kind: doc
    resource: "docs/guides/send-events.md"
  - kind: doc
    resource: "docs/guides/web-enrichment.md"
---

# event context

The event’s JSON context object carrying supplementary producer metadata.

Context can contain locale, viewport or a producer bot flag. It is separate from properties and from request-derived categorical enrichment. A context.bot Boolean true can flag a bot; false cannot clear a server match. Context is not an unrestricted source of public metric dimensions.

Related: [event property](event-property.md), [bot flag](bot-flag.md).

## References

- [docs/guides/send-events.md](../../docs/guides/send-events.md).
- [docs/guides/web-enrichment.md](../../docs/guides/web-enrichment.md).
