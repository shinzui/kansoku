---
type: Term
title: "complete-or-error answer"
description: "A metric response policy that returns the whole aggregate within public limits or fails without a partial metric payload."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-42
status: current
tags: [queries]
related:
  - TERM-37
  - TERM-41
  - TERM-79
anchors:
  - kind: doc
    resource: "docs/guides/query-metrics.md"
  - kind: doc
    resource: "docs/adr/0009-bounded-complete-aggregate-responses.md"
---

# complete-or-error answer

A metric response policy that returns the whole aggregate within public limits or fails without a partial metric payload.

An answer exceeding 10,000 points fails rather than truncating source events or silently returning a partial aggregate. Execution and native memory limits can fail a request independently. Cohort and saved-definition resource lists use cursor pages instead; those are not pages of an evolving aggregate.

Related: [metric point](metric-point.md), [half-open range](half-open-range.md), [problem details](problem-details.md).

## References

- [docs/guides/query-metrics.md](../../docs/guides/query-metrics.md).
- [docs/adr/0009-bounded-complete-aggregate-responses.md](../../docs/adr/0009-bounded-complete-aggregate-responses.md).
