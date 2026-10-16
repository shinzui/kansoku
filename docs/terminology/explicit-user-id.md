---
type: Term
title: "explicit user ID"
description: "The producer’s direct assertion of which user performed an event."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-27
status: current
tags: [identity]
aliases:
  - "userId"
related:
  - TERM-26
  - TERM-30
  - TERM-32
anchors:
  - kind: doc
    resource: "docs/guides/send-events.md"
  - kind: doc
    resource: "docs/guides/query-metrics.md"
---

# explicit user ID

The producer’s direct assertion of which user performed an event.

Top-level userId takes precedence over inferred signal bindings. Governed person-trait writes require it to be nonempty. This is a producer analytics assertion, not authenticated end-user authorization. An anonymous ID with identical text does not inherit its traits or organisation membership without resolution.

Related: [anonymous ID](anonymous-id.md), [canonical subject](canonical-subject.md), [current person trait](current-person-trait.md).

## References

- [docs/guides/send-events.md](../../docs/guides/send-events.md).
- [docs/guides/query-metrics.md](../../docs/guides/query-metrics.md).
