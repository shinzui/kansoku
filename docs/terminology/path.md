---
type: Term
title: "path"
description: "An observed sequence of canonical-user transitions explored forward or backward within a bounded interval."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-63
status: current
tags: [journeys]
related:
  - TERM-53
  - TERM-59
anchors:
  - kind: doc
    resource: "docs/guides/query-metrics.md"
  - kind: file
    resource: "scripts/paths-acceptance.py"
---

# path

An observed sequence of canonical-user transitions explored forward or backward within a bounded interval.

Event paths require a start or end anchor. Route flows use nonbot page views and collapse consecutive identical routes, with optional entry mode. Each user contributes one sequence, not one per session. A synthetic end means observed exhaustion; other folds lower-ranked edges and is not a real transition node.

Related: [web session](web-session.md), [funnel](funnel.md).

## References

- [docs/guides/query-metrics.md](../../docs/guides/query-metrics.md).
- [scripts/paths-acceptance.py](../../scripts/paths-acceptance.py).
