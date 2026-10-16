---
type: Term
title: "lifecycle"
description: "The classification of daily activity into new, returning, resurrecting and dormant populations using retained matching history."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-46
status: current
tags: [activity]
related:
  - TERM-43
  - TERM-48
anchors:
  - kind: doc
    resource: "docs/guides/query-metrics.md"
  - kind: file
    resource: "kansoku-core/test/Kansoku/Metrics/ActivityIntegrationSpec.hs"
---

# lifecycle

The classification of daily activity into new, returning, resurrecting and dormant populations using retained matching history.

The lifecycle endpoint emits nonnegative counts with group.status. First activity means first matching retained activity, so deletion or retention can change who appears new. Profile-only events do not move a subject into activity. These are analytical classifications, not account lifecycle commands.

Related: [active user](active-user.md), [retained-history lifetime](retained-history-lifetime.md).

## References

- [docs/guides/query-metrics.md](../../docs/guides/query-metrics.md).
- [kansoku-core/test/Kansoku/Metrics/ActivityIntegrationSpec.hs](../../kansoku-core/test/Kansoku/Metrics/ActivityIntegrationSpec.hs).
