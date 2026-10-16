---
type: Term
title: "dimension"
description: "A validated attribute by which a metric selects or groups its population."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-38
status: current
tags: [queries]
related:
  - TERM-14
  - TERM-32
  - TERM-35
  - TERM-39
anchors:
  - kind: doc
    resource: "docs/guides/query-metrics.md"
---

# dimension

A validated attribute by which a metric selects or groups its population.

Built-ins include source and route; prop: names refer to governed event properties, user: to current person traits, org: to current organisation traits and cohort:<uuid> to membership grouping. The prefix matters: source and prop:source are distinct. Most supported requests permit up to two group dimensions.

Related: [event property](event-property.md), [current person trait](current-person-trait.md), [current organisation trait](current-organisation-trait.md), [metric filter](metric-filter.md).

## References

- [docs/guides/query-metrics.md](../../docs/guides/query-metrics.md).
