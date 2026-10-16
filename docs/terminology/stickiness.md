---
type: Term
title: "stickiness"
description: "The ratio of daily active subjects to rolling-thirty-day active subjects in the same selected population."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-45
status: current
tags: [activity]
related:
  - TERM-43
  - TERM-44
anchors:
  - kind: doc
    resource: "docs/guides/query-metrics.md"
  - kind: file
    resource: "scripts/activity_acceptance.py"
---

# stickiness

The ratio of daily active subjects to rolling-thirty-day active subjects in the same selected population.

The endpoint returns daily_active, rolling30_active and ratio as separate numeric measures. The ratio stays in [0,1]; empty ungrouped days return zero measures. Interpret the ratio with its underlying counts and current population filters, rather than as a generic product engagement score.

Related: [active user](active-user.md), [rolling window](rolling-window.md).

## References

- [docs/guides/query-metrics.md](../../docs/guides/query-metrics.md).
- [scripts/activity_acceptance.py](../../scripts/activity_acceptance.py).
