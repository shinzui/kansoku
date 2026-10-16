---
type: Term
title: "funnel attempt"
description: "A nonoverlapping entry tracked when funnel counting is set to totals."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-61
status: current
tags: [journeys]
related:
  - TERM-59
  - TERM-60
anchors:
  - kind: doc
    resource: "docs/guides/query-metrics.md"
  - kind: file
    resource: "kansoku-core/test/Kansoku/Metrics/FunnelIntegrationSpec.hs"
---

# funnel attempt

A nonoverlapping entry tracked when funnel counting is set to totals.

An attempt opens at step one for sequential/strict or any matching step for any-order. Completion, expiry, exclusion or strict interruption closes it while preserving reached progress. The closing event can open another eligible attempt. Totals counts attempts and emits entries separately, so it is not a unique-user count.

Related: [funnel](funnel.md), [selected chain](selected-chain.md).

## References

- [docs/guides/query-metrics.md](../../docs/guides/query-metrics.md).
- [kansoku-core/test/Kansoku/Metrics/FunnelIntegrationSpec.hs](../../kansoku-core/test/Kansoku/Metrics/FunnelIntegrationSpec.hs).
