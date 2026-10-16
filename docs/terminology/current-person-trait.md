---
type: Term
title: "current person trait"
description: "A governed per-user value joined to analytics according to its current winning observation."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-32
status: current
tags: [identity]
aliases:
  - "current user trait"
related:
  - TERM-14
  - TERM-27
  - TERM-33
anchors:
  - kind: doc
    resource: "docs/guides/query-metrics.md"
  - kind: file
    resource: "scripts/traits_acceptance.py"
---

# current person trait

A governed per-user value joined to analytics according to its current winning observation.

Identify v2 sets declared traits such as plan or company_size. Latest set wins by occurrence time, first accepted receipt time and event ID; omitted keys are unchanged and null is rejected. User:plan can reclassify historical events after a later change. Identify v1 has no governed trait writes.

Related: [event property](event-property.md), [explicit user ID](explicit-user-id.md), [set-once trait](set-once-trait.md).

## References

- [docs/guides/query-metrics.md](../../docs/guides/query-metrics.md).
- [scripts/traits_acceptance.py](../../scripts/traits_acceptance.py).
