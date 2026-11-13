---
type: Term
title: "retention offset"
description: "A number of UTC calendar periods after a retention cohort’s start at which return activity is evaluated."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
timestamp: 2026-11-13T14:03:22Z
termId: TERM-49
status: current
tags: [activity]
related:
  - TERM-47
  - TERM-48
anchors:
  - kind: doc
    resource: "docs/guides/query-metrics.md"
  - kind: file
    resource: "kansoku-core/test/Kansoku/Metrics/ActivityIntegrationSpec.hs"
---

# retention offset

A number of UTC calendar periods after a retention cohort’s start at which return activity is evaluated.

Offsets are at most 32 distinct values: 1..365 for day (default), 1..52 for Monday weeks, or 1..12 for actual calendar months. An implicit zero always gives observed cohort size. Mode=on tests the full target period. On_or_after tests from that period through the end of the largest requested period, including unrequested periods. Exact subjects count once despite several return days. Immature target periods, or all cumulative offsets before the full horizon closes, are omitted rather than reported as zero.

Related: [retention cohort](retention-cohort.md), [retained-history lifetime](retained-history-lifetime.md).

## References

- [docs/guides/query-metrics.md](../../docs/guides/query-metrics.md).
- [kansoku-core/test/Kansoku/Metrics/ActivityIntegrationSpec.hs](../../kansoku-core/test/Kansoku/Metrics/ActivityIntegrationSpec.hs).
