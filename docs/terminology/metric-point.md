---
type: Term
title: "metric point"
description: "One numeric analytical result with a nullable bucket and a dimension-value group object."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-37
status: current
tags: [queries]
related:
  - TERM-38
  - TERM-40
  - TERM-42
anchors:
  - kind: doc
    resource: "docs/guides/query-metrics.md"
  - kind: file
    resource: "kansoku-api/src/Kansoku/Metrics/Definition.hs"
---

# metric point

One numeric analytical result with a nullable bucket and a dimension-value group object.

A point might report 42 page views for one UTC day and route. Bucket is null for an unbucketed result. Group values are nullable strings; null, empty text and the literal other remain distinct. Multi-measure endpoints put measure labels in the group rather than changing the numeric value’s type.

Related: [dimension](dimension.md), [time grain](time-grain.md), [complete-or-error answer](complete-or-error.md).

## References

- [docs/guides/query-metrics.md](../../docs/guides/query-metrics.md).
- [kansoku-api/src/Kansoku/Metrics/Definition.hs](../../kansoku-api/src/Kansoku/Metrics/Definition.hs).
