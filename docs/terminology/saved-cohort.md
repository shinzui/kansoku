---
type: Term
title: "saved cohort"
description: "An account-scoped named definition of an identified-user segment reusable in metric selection and grouping."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-50
status: current
tags: [segments]
related:
  - TERM-47
  - TERM-51
  - TERM-52
anchors:
  - kind: doc
    resource: "docs/guides/query-metrics.md"
  - kind: file
    resource: "kansoku-api/src/Kansoku/Cohort/Types.hs"
---

# saved cohort

An account-scoped named definition of an identified-user segment reusable in metric selection and grouping.

A saved cohort has a UUID and either behavioural or static kind, preserved on updates. It can select members with cohort:eq or split groups into in/out. Anonymous-only subjects are out. Membership is read under current identity/traits and is not a permanently materialized historical snapshot.

Related: [retention cohort](retention-cohort.md), [behavioural cohort](behavioural-cohort.md), [static cohort](static-cohort.md).

## References

- [docs/guides/query-metrics.md](../../docs/guides/query-metrics.md).
- [kansoku-api/src/Kansoku/Cohort/Types.hs](../../kansoku-api/src/Kansoku/Cohort/Types.hs).
