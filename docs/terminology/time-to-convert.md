---
type: Term
title: "time to convert"
description: "The elapsed selected-chain time from funnel start to a reached step, reported as exact percentile measures."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-62
status: current
tags: [journeys]
related:
  - TERM-59
  - TERM-60
  - TERM-61
anchors:
  - kind: doc
    resource: "docs/guides/query-metrics.md"
---

# time to convert

The elapsed selected-chain time from funnel start to a reached step, reported as exact percentile measures.

Measure=time_to_convert emits reached steps from two onward using nearest-rank p50_seconds and p90_seconds. The timeline has millisecond precision and the output is seconds. No reached chains means no timing rows. Totals uses per-attempt timing rather than choosing one user chain.

Related: [funnel](funnel.md), [selected chain](selected-chain.md), [funnel attempt](funnel-attempt.md).

## References

- [docs/guides/query-metrics.md](../../docs/guides/query-metrics.md).
