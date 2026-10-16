---
type: Term
title: "behavioural cohort"
description: "A saved cohort whose membership is evaluated from event conditions and current person traits at query time."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-51
status: current
tags: [segments]
related:
  - TERM-32
  - TERM-50
  - TERM-52
broader:
  - TERM-50
anchors:
  - kind: doc
    resource: "docs/guides/query-metrics.md"
  - kind: file
    resource: "scripts/cohorts_acceptance.py"
---

# behavioural cohort

A saved cohort whose membership is evaluated from event conditions and current person traits at query time.

Each condition has its own lookback ending at the query to date, independently of metric from. Did/didNot and optional occurrence bounds select identified users after resolution. Conditions and trait filters are ANDed. Nested cohorts, sequences and first-ever occurrence criteria are unsupported.

Related: [saved cohort](saved-cohort.md), [current person trait](current-person-trait.md), [static cohort](static-cohort.md).

## References

- [docs/guides/query-metrics.md](../../docs/guides/query-metrics.md).
- [scripts/cohorts_acceptance.py](../../scripts/cohorts_acceptance.py).
