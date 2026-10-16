---
type: Term
title: "readiness"
description: "The operational determination that the process and required pipeline dependencies can currently serve traffic within configured thresholds."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-77
status: current
tags: [operations]
related:
  - TERM-25
  - TERM-78
anchors:
  - kind: doc
    resource: "docs/guides/operations.md"
  - kind: file
    resource: "kansoku-core/test/Kansoku/HealthSpec.hs"
---

# readiness

The operational determination that the process and required pipeline dependencies can currently serve traffic within configured thresholds.

Health/ready checks writer liveness, PostgreSQL, ClickHouse query reachability, sampled queue depth and flush freshness in order. The first failure determines a 503 with its consecutive failingSince timestamp; recovery resets it. A process can remain live while storage readiness fails.

Related: [writer breaker](writer-breaker.md), [liveness](liveness.md).

## References

- [docs/guides/operations.md](../../docs/guides/operations.md).
- [kansoku-core/test/Kansoku/HealthSpec.hs](../../kansoku-core/test/Kansoku/HealthSpec.hs).
