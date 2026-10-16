---
type: Term
title: "rolling window"
description: "A trailing activity interval evaluated for each closed daily observation point."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-44
status: current
tags: [activity]
related:
  - TERM-40
  - TERM-43
  - TERM-45
anchors:
  - kind: doc
    resource: "docs/guides/query-metrics.md"
  - kind: file
    resource: "kansoku-core/test/Kansoku/Metrics/ActivityIntegrationSpec.hs"
---

# rolling window

A trailing activity interval evaluated for each closed daily observation point.

Rolling7 and rolling30 count active subjects across trailing seven or thirty days, with day grain. They differ from calendar week/month buckets. Current filters apply throughout the lookback; the service does not compute the numerator from a different selected population.

Related: [time grain](time-grain.md), [active user](active-user.md), [stickiness](stickiness.md).

## References

- [docs/guides/query-metrics.md](../../docs/guides/query-metrics.md).
- [kansoku-core/test/Kansoku/Metrics/ActivityIntegrationSpec.hs](../../kansoku-core/test/Kansoku/Metrics/ActivityIntegrationSpec.hs).
