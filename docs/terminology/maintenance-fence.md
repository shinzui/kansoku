---
type: Term
title: "maintenance fence"
description: "The persisted global admission boundary held while a cross-store maintenance job drains and mutates analytical state."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-70
status: current
timestamp: 2026-11-14T02:13:45Z
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

The fence alone does not stop earlier native requests or clients using migration
credentials. Maintenance also requires fresh external drain evidence for its exact
owner and predecessor. A shared deployment excludes only Kansoku submitters and
conflicting schedules; it can preserve the shared server process and other apps'
queries. A dedicated owned server may use restart as its drain procedure.

Related: [replay](replay.md), [maintenance job](maintenance-job.md), [problem details](problem-details.md).

## References

- [docs/guides/administration.md](../../docs/guides/administration.md).
- [docs/guides/consume-clickhouse.md](../../docs/guides/consume-clickhouse.md).
