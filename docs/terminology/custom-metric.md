---
type: Term
title: "custom metric"
description: "A typed ad-hoc or saved analytical calculation over explicitly selected event names."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-68
status: current
tags: [segments]
related:
  - TERM-38
  - TERM-39
  - TERM-69
anchors:
  - kind: doc
    resource: "docs/guides/query-metrics.md"
  - kind: file
    resource: "scripts/custom_metrics_acceptance.py"
---

# custom metric

A typed ad-hoc or saved analytical calculation over explicitly selected event names.

Custom metrics support count, unique_count, declared numeric sum/average and numerator/denominator ratios. Definitions contain no SQL. Counts deduplicate events, unique counts resolve subjects, and ratios are unbucketed with zero for zero denominator. A custom name cannot change builtin route dispatch.

Related: [dimension](dimension.md), [metric filter](metric-filter.md), [saved metric definition](saved-metric-definition.md).

## References

- [docs/guides/query-metrics.md](../../docs/guides/query-metrics.md).
- [scripts/custom_metrics_acceptance.py](../../scripts/custom_metrics_acceptance.py).
