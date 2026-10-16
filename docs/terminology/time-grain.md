---
type: Term
title: "time grain"
description: "The calendar unit used to bucket supported metric results in UTC."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-40
status: current
tags: [queries]
aliases:
  - "timeGrain"
related:
  - TERM-37
  - TERM-41
  - TERM-44
anchors:
  - kind: doc
    resource: "docs/guides/query-metrics.md"
---

# time grain

The calendar unit used to bucket supported metric results in UTC.

Hour, day, week and month are available where the endpoint permits them; the usual default is day. A calendar week is not a trailing seven-day window. Rolling and closed-day activity families restrict grain to day, and some ratios are unbucketed and reject timeGrain.

Related: [metric point](metric-point.md), [half-open range](half-open-range.md), [rolling window](rolling-window.md).

## References

- [docs/guides/query-metrics.md](../../docs/guides/query-metrics.md).
