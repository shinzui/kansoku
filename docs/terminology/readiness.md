---
type: Term
title: "readiness"
description: "The operational determination that PostgreSQL and PGMQ can currently admit durable events."
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

The operational determination that PostgreSQL and PGMQ can currently admit durable events.

/health/ready checks PostgreSQL/PGMQ admission reachability. ClickHouse outages, topology mismatches and backlog leave admission healthy. /health/pipeline separately checks writer liveness, PGMQ, fresh topology observation, breaker, query reachability and queue/flush thresholds. Each endpoint uses its own consecutive failingSince timestamp; recovery resets it. A process can remain live and admit events while pipeline health fails.

Related: [writer breaker](writer-breaker.md), [liveness](liveness.md).

## References

- [docs/guides/operations.md](../../docs/guides/operations.md).
- [kansoku-core/test/Kansoku/HealthSpec.hs](../../kansoku-core/test/Kansoku/HealthSpec.hs).
