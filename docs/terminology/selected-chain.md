---
type: Term
title: "selected chain"
description: "The deterministic matched event sequence used to report a unique participant’s funnel reach and timing."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-60
status: current
tags: [journeys]
related:
  - TERM-59
  - TERM-61
  - TERM-62
anchors:
  - kind: doc
    resource: "docs/guides/query-metrics.md"
  - kind: file
    resource: "kansoku-core/test/Kansoku/Metrics/FunnelIntegrationSpec.hs"
---

# selected chain

The deterministic matched event sequence used to report a unique participant’s funnel reach and timing.

For sequential/strict uniques, the evaluator chooses greatest reach, earliest completion, earliest start, then event IDs. Any-order uniques opens at the earliest matching event and does not search later windows. Timing must come from that same selection rather than an independently faster chain.

Related: [funnel](funnel.md), [funnel attempt](funnel-attempt.md), [time to convert](time-to-convert.md).

## References

- [docs/guides/query-metrics.md](../../docs/guides/query-metrics.md).
- [kansoku-core/test/Kansoku/Metrics/FunnelIntegrationSpec.hs](../../kansoku-core/test/Kansoku/Metrics/FunnelIntegrationSpec.hs).
