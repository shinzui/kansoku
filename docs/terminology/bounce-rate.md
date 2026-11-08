---
type: Term
title: "bounce rate"
description: "The fraction of selected sessions with exactly one distinct page view and no engagement event."
timestamp: 2026-11-08T06:55:25Z
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-55
status: current
tags: [web]
related:
  - TERM-53
  - TERM-56
anchors:
  - kind: doc
    resource: "docs/guides/query-metrics.md"
---

# bounce rate

The fraction of selected sessions with exactly one distinct page view and no engagement event.

The names `session_start`, `page_leave`, `identify`, `identify_once`, `alias`, `group`, `experiment_viewed`, `client_error` and `web_vital` do not count as engagement, regardless of version; other application events such as purchase do. Zero-page sessions remain in the denominator but are not bounces. A page leave can give a bounced session positive observed duration. Empty ungrouped buckets return zero.

Related: [web session](web-session.md), [observed session duration](observed-session-duration.md).

## References

- [docs/guides/query-metrics.md](../../docs/guides/query-metrics.md).
