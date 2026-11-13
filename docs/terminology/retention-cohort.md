---
type: Term
title: "retention cohort"
description: "The starting population whose later matching activity is measured at requested return offsets."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
timestamp: 2026-11-13T14:03:22Z
termId: TERM-47
status: current
tags: [activity]
related:
  - TERM-48
  - TERM-49
  - TERM-50
anchors:
  - kind: doc
    resource: "docs/guides/query-metrics.md"
---

# retention cohort

The starting population whose later matching activity is measured at requested return offsets.

Window cohorts start at first matching start activity in the query interval; lifetime cohorts use first matching retained start activity. UTC day, Monday week or calendar month determines the label (period first day) and offset unit. startEvent/startFilter and returnEvent/returnFilter select independent activity while shared filters apply to both. Starts supply group values and returns must match them. A partial final cohort counts its observed starters. Offset zero always reports cohort size. This metric population differs from a saved cohort resource, which can independently filter the retention calculation.

Related: [retained-history lifetime](retained-history-lifetime.md), [retention offset](retention-offset.md), [saved cohort](saved-cohort.md).

## References

- [docs/guides/query-metrics.md](../../docs/guides/query-metrics.md).
