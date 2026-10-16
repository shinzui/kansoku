---
type: Term
title: "exposure sketch"
description: "The approximate raw-identity aggregate used for default unsegmented experiment exposure counts."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-67
status: current
tags: [experiments]
related:
  - TERM-30
  - TERM-64
  - TERM-66
anchors:
  - kind: doc
    resource: "docs/guides/query-metrics.md"
---

# exposure sketch

The approximate raw-identity aggregate used for default unsegmented experiment exposure counts.

UniqCombined exposure rollups have about 0.8 percent relative error at scale and can be exact for small sets. Their raw identity population differs from exact resolved conversion, diagnostics and selected exposures. Do not interchange the denominators or label all experiment numbers approximate.

Related: [canonical subject](canonical-subject.md), [experiment exposure](experiment-exposure.md), [first-observed assignment](first-observed-assignment.md).

## References

- [docs/guides/query-metrics.md](../../docs/guides/query-metrics.md).
