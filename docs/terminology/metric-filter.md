---
type: Term
title: "metric filter"
description: "A typed population predicate applied through bounded conjoined groups of optional alternatives."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-39
status: current
tags: [queries]
related:
  - TERM-38
  - TERM-50
anchors:
  - kind: doc
    resource: "docs/guides/query-metrics.md"
  - kind: file
    resource: "kansoku-api/src/Kansoku/Metrics/Filter.hs"
---

# metric filter

A typed population predicate applied through bounded conjoined groups of optional alternatives.

Separate filter parameters are ANDed; alternatives inside one JSON or shorthand group are ORed. For example, pro OR enterprise can be combined with source=web. There are at most eight groups with eight terms each. Null operands, nested groups and incompatible property types fail; unset values do not satisfy neq comparisons.

Related: [dimension](dimension.md), [saved cohort](saved-cohort.md).

## References

- [docs/guides/query-metrics.md](../../docs/guides/query-metrics.md).
- [kansoku-api/src/Kansoku/Metrics/Filter.hs](../../kansoku-api/src/Kansoku/Metrics/Filter.hs).
