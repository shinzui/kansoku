---
type: Term
title: "funnel"
description: "A bounded progression through requested event steps for a canonical user or supported organisation timeline."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-59
status: current
tags: [journeys]
related:
  - TERM-60
  - TERM-61
  - TERM-62
  - TERM-63
anchors:
  - kind: doc
    resource: "docs/guides/query-metrics.md"
  - kind: file
    resource: "kansoku-core/test/Kansoku/Metrics/FunnelIntegrationSpec.hs"
---

# funnel

A bounded progression through requested event steps for a canonical user or supported organisation timeline.

Sequential permits intervening events, strict requires adjacency and any_order matches distinct requested positions in one window. Repeated step names need separate immutable events. The same mechanism supports post-exposure experiment funnels, with a gated timeline. A funnel is distinct from exploratory paths with discovered next steps.

Related: [selected chain](selected-chain.md), [funnel attempt](funnel-attempt.md), [time to convert](time-to-convert.md), [path](path.md).

## References

- [docs/guides/query-metrics.md](../../docs/guides/query-metrics.md).
- [kansoku-core/test/Kansoku/Metrics/FunnelIntegrationSpec.hs](../../kansoku-core/test/Kansoku/Metrics/FunnelIntegrationSpec.hs).
