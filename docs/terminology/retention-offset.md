---
type: Term
title: "retention offset"
description: "A number of days after a retention cohort’s start at which return activity is evaluated."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
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

A number of days after a retention cohort’s start at which return activity is evaluated.

Offsets are distinct values in 1..365, at most 32, with an implicit zero cohort point. Mode=on tests the exact day. On_or_after tests any day from that offset through the largest requested offset, including unrequested intervening days. Immature horizons are omitted rather than reported as zero.

Related: [retention cohort](retention-cohort.md), [retained-history lifetime](retained-history-lifetime.md).

## References

- [docs/guides/query-metrics.md](../../docs/guides/query-metrics.md).
- [kansoku-core/test/Kansoku/Metrics/ActivityIntegrationSpec.hs](../../kansoku-core/test/Kansoku/Metrics/ActivityIntegrationSpec.hs).
