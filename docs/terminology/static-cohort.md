---
type: Term
title: "static cohort"
description: "A saved cohort whose membership is an explicitly uploaded set of user IDs."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-52
status: current
tags: [segments]
related:
  - TERM-50
  - TERM-51
broader:
  - TERM-50
anchors:
  - kind: doc
    resource: "docs/guides/query-metrics.md"
  - kind: file
    resource: "scripts/cohorts_acceptance.py"
---

# static cohort

A saved cohort whose membership is an explicitly uploaded set of user IDs.

PUT replaces the complete member set; an empty upload clears it and duplicate IDs collapse. The maximum is 50,000 nonempty IDs, subject to body limits. Unlike behavioural member pages, static member pages return uploaded IDs independently of event history. User erasure removes matching membership facts.

Related: [saved cohort](saved-cohort.md), [behavioural cohort](behavioural-cohort.md).

## References

- [docs/guides/query-metrics.md](../../docs/guides/query-metrics.md).
- [scripts/cohorts_acceptance.py](../../scripts/cohorts_acceptance.py).
