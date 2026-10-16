---
type: Term
title: "web session"
description: "The whole retained set of web events sharing an account, source service and nonempty producer session ID."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-53
status: current
tags: [web]
aliases:
  - "session"
related:
  - TERM-5
  - TERM-54
  - TERM-55
  - TERM-56
anchors:
  - kind: doc
    resource: "docs/guides/query-metrics.md"
  - kind: doc
    resource: "docs/guides/web-enrichment.md"
---

# web session

The whole retained set of web events sharing an account, source service and nonempty producer session ID.

Sessions span batches, hosts and midnight. The server assembles the whole retained session before start-date and attribute selection; it does not infer an inactivity timeout. Late arrivals can move the start or extend duration. Missing IDs and non-web events do not join sessions.

Related: [source service](source-service.md), [first-touch attribution](first-touch-attribution.md), [bounce rate](bounce-rate.md), [observed session duration](observed-session-duration.md).

## References

- [docs/guides/query-metrics.md](../../docs/guides/query-metrics.md).
- [docs/guides/web-enrichment.md](../../docs/guides/web-enrichment.md).
