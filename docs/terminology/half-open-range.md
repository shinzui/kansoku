---
type: Term
title: "half-open range"
description: "An analytical time interval that includes its from boundary and excludes its to boundary."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-41
status: current
tags: [queries]
related:
  - TERM-40
  - TERM-42
  - TERM-47
  - TERM-53
anchors:
  - kind: doc
    resource: "docs/guides/query-metrics.md"
---

# half-open range

An analytical time interval that includes its from boundary and excludes its to boundary.

From=2026-07-01 and to=2026-08-01 select July in UTC. Positive metric ranges are capped at 366 days. Session start-date selection and cohort lookback have their own population rules within this request contract; a request range is not always the entire history read for a result.

Related: [time grain](time-grain.md), [complete-or-error answer](complete-or-error.md), [retention cohort](retention-cohort.md), [web session](web-session.md).

## References

- [docs/guides/query-metrics.md](../../docs/guides/query-metrics.md).
