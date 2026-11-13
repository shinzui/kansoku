---
type: Term
title: "liveness"
description: "The operational check that the HTTP process responds independently of dependency health."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-78
status: current
tags: [operations]
related:
  - TERM-77
anchors:
  - kind: doc
    resource: "docs/guides/operations.md"
  - kind: file
    resource: "kansoku-core/test/Kansoku/HealthSpec.hs"
---

# liveness

The operational check that the HTTP process responds independently of dependency health.

Use /health/live for orchestration process checks. Admission dependency failures belong to /health/ready; storage/delivery failures belong to /health/pipeline. Neither makes liveness fail.

Related: [readiness](readiness.md).

## References

- [docs/guides/operations.md](../../docs/guides/operations.md).
- [kansoku-core/test/Kansoku/HealthSpec.hs](../../kansoku-core/test/Kansoku/HealthSpec.hs).
