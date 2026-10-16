---
type: Term
title: "first-observed assignment"
description: "The exclusive diagnostic allocation of a resolved user to their earliest valid observed experiment variant in a scope."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-66
status: current
tags: [experiments]
related:
  - TERM-64
  - TERM-65
anchors:
  - kind: doc
    resource: "docs/guides/query-metrics.md"
---

# first-observed assignment

The exclusive diagnostic allocation of a resolved user to their earliest valid observed experiment variant in a scope.

Occurrence time then event ID breaks ties per experiment and requested bucket. Assigned user counts and variant_share are exclusive; shares sum to one for nonempty populations. The observation is not authoritative randomization, and zero-assigned but observed variants remain visible.

Related: [experiment exposure](experiment-exposure.md), [exposure contamination](exposure-contamination.md).

## References

- [docs/guides/query-metrics.md](../../docs/guides/query-metrics.md).
