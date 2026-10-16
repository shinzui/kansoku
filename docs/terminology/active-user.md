---
type: Term
title: "active user"
description: "A nonempty canonical subject with matching non-profile activity in the requested activity population."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-43
status: current
tags: [activity]
related:
  - TERM-30
  - TERM-44
  - TERM-46
anchors:
  - kind: doc
    resource: "docs/guides/query-metrics.md"
  - kind: file
    resource: "kansoku-core/test/Kansoku/Metrics/ActivityIntegrationSpec.hs"
---

# active user

A nonempty canonical subject with matching non-profile activity in the requested activity population.

Users counts exact resolved subjects, including unresolved anonymous subjects with IDs, rather than only logged-in accounts. Profile/identity-only events do not create activity. Bot activity is excluded by default. Current filters and grouping define the same population across lookback for rolling, retention, stickiness and lifecycle.

Related: [canonical subject](canonical-subject.md), [rolling window](rolling-window.md), [lifecycle](lifecycle.md).

## References

- [docs/guides/query-metrics.md](../../docs/guides/query-metrics.md).
- [kansoku-core/test/Kansoku/Metrics/ActivityIntegrationSpec.hs](../../kansoku-core/test/Kansoku/Metrics/ActivityIntegrationSpec.hs).
