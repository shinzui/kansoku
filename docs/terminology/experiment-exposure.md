---
type: Term
title: "experiment exposure"
description: "An experiment_viewed observation that records a user seeing a named experiment variant."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-64
status: current
tags: [experiments]
related:
  - TERM-65
  - TERM-66
  - TERM-67
anchors:
  - kind: doc
    resource: "docs/guides/query-metrics.md"
  - kind: file
    resource: "kansoku-api/src/Kansoku/Event/Registry.hs"
---

# experiment exposure

An experiment_viewed observation that records a user seeing a named experiment variant.

Post-exposure conversion and funnels begin at the user’s first exposure to each variant in range. A conversion before exposure does not qualify. A user seeing multiple variants can still count in each variant’s conversion/funnel result. Kansoku records observations and does not randomize or assign users.

Related: [exposure contamination](exposure-contamination.md), [first-observed assignment](first-observed-assignment.md), [exposure sketch](exposure-sketch.md).

## References

- [docs/guides/query-metrics.md](../../docs/guides/query-metrics.md).
- [kansoku-api/src/Kansoku/Event/Registry.hs](../../kansoku-api/src/Kansoku/Event/Registry.hs).
