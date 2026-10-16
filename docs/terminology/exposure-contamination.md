---
type: Term
title: "exposure contamination"
description: "The condition in which a resolved user has observed more than one variant of an experiment within the diagnostic scope."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-65
status: current
tags: [experiments]
related:
  - TERM-64
  - TERM-66
anchors:
  - kind: doc
    resource: "docs/guides/query-metrics.md"
  - kind: file
    resource: "kansoku-core/test/Kansoku/Metrics/FunnelIntegrationSpec.hs"
---

# exposure contamination

The condition in which a resolved user has observed more than one variant of an experiment within the diagnostic scope.

Diagnostics expose this as multiple_exposure. A user seeing A then B contributes one contaminated user, even though conversion/funnels can count them in both variants. Contamination complicates sample-ratio interpretation and cannot be removed by treating first observed assignment as a proven randomization record.

Related: [experiment exposure](experiment-exposure.md), [first-observed assignment](first-observed-assignment.md).

## References

- [docs/guides/query-metrics.md](../../docs/guides/query-metrics.md).
- [kansoku-core/test/Kansoku/Metrics/FunnelIntegrationSpec.hs](../../kansoku-core/test/Kansoku/Metrics/FunnelIntegrationSpec.hs).
