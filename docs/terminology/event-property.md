---
type: Term
title: "event property"
description: "A value in an event’s properties object describing that particular observation."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-14
status: current
tags: [events]
related:
  - TERM-9
  - TERM-32
  - TERM-35
  - TERM-38
anchors:
  - kind: doc
    resource: "docs/guides/query-metrics.md"
  - kind: doc
    resource: "docs/guides/send-events.md"
---

# event property

A value in an event’s properties object describing that particular observation.

For example, payment_completed.amount describes a payment fact. Registered compatible scalar declarations make properties eligible for prop: filters and grouping. A historical event property differs from a current user: or org: trait, which can reclassify old events after later updates. Arbitrary stored JSON is not automatically a dimension.

Related: [schema version](schema-version.md), [current person trait](current-person-trait.md), [current organisation trait](current-organisation-trait.md), [dimension](dimension.md).

## References

- [docs/guides/query-metrics.md](../../docs/guides/query-metrics.md).
- [docs/guides/send-events.md](../../docs/guides/send-events.md).
