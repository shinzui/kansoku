---
type: Term
title: "first-touch attribution"
description: "The selection of an initial eligible observation as the owner of analytical attributes."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-54
status: current
tags: [web]
related:
  - TERM-53
  - TERM-57
  - TERM-60
anchors:
  - kind: doc
    resource: "docs/guides/query-metrics.md"
  - kind: doc
    resource: "docs/guides/web-enrichment.md"
---

# first-touch attribution

The selection of an initial eligible observation as the owner of analytical attributes.

Whole-session acquisition uses the first page view, otherwise earliest web event, with occurrence/event-ID tie ordering. Funnel property first_touch instead follows its documented eligible-start/selected-attempt rules. These are related contextual policies; neither means an immutable first-ever marketing touch for a person.

Related: [web session](web-session.md), [acquisition channel](acquisition-channel.md), [selected chain](selected-chain.md).

## References

- [docs/guides/query-metrics.md](../../docs/guides/query-metrics.md).
- [docs/guides/web-enrichment.md](../../docs/guides/web-enrichment.md).
