---
type: Term
title: "bot flag"
description: "The accepted classification marking an event as automated traffic under server or producer rules."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-58
status: current
tags: [web]
related:
  - TERM-15
  - TERM-53
anchors:
  - kind: doc
    resource: "docs/guides/web-enrichment.md"
  - kind: doc
    resource: "docs/guides/query-metrics.md"
---

# bot flag

The accepted classification marking an event as automated traffic under server or producer rules.

Server user-agent matches or Boolean context.bot=true set the flag. Producer false cannot clear a match. Page views default to row-level exclusion; sessions/acquisition exclude a whole session if any event is flagged. Event/revenue metrics have their own documented populations, so bot exclusion is not globally uniform.

Related: [event context](event-context.md), [web session](web-session.md).

## References

- [docs/guides/web-enrichment.md](../../docs/guides/web-enrichment.md).
- [docs/guides/query-metrics.md](../../docs/guides/query-metrics.md).
