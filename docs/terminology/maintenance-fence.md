---
type: Term
title: "maintenance fence"
description: "The persisted global admission boundary held while a cross-store maintenance job drains and mutates analytical state."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-70
status: current
tags: [operations]
related:
  - TERM-24
  - TERM-71
  - TERM-79
anchors:
  - kind: doc
    resource: "docs/guides/administration.md"
  - kind: doc
    resource: "docs/guides/consume-clickhouse.md"
---

# maintenance fence

The persisted global admission boundary held while a cross-store maintenance job drains and mutates analytical state.

Confirmed jobs wait for admitted reads, inserts and replays, including backend work surviving caller cancellation. Ingest and metrics then return retryable maintenance_unavailable until completion. Failed jobs retain the fence for resumption. Direct SQL consumers do not acquire it and require external pause coordination.

Related: [replay](replay.md), [maintenance job](maintenance-job.md), [problem details](problem-details.md).

## References

- [docs/guides/administration.md](../../docs/guides/administration.md).
- [docs/guides/consume-clickhouse.md](../../docs/guides/consume-clickhouse.md).
