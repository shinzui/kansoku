---
type: Term
title: "current organisation trait"
description: "A governed value from group v2 observations used to classify an organisation’s historical activity."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-35
status: current
tags: [identity]
aliases:
  - "current organization trait"
related:
  - TERM-14
  - TERM-34
  - TERM-36
anchors:
  - kind: doc
    resource: "docs/guides/query-metrics.md"
  - kind: file
    resource: "scripts/organizations_acceptance.py"
---

# current organisation trait

A governed value from group v2 observations used to classify an organisation’s historical activity.

Supported traits include plan, industry, country and seats. Latest occurrence/first-receipt/event-ID order wins per account/organisation/key. Group v1 supplies context only. Org: dimensions use current traits, so an upgrade from starter to pro can change the grouping of an older payment.

Related: [event property](event-property.md), [organisation](organisation.md), [current organisation membership](current-organisation-membership.md).

## References

- [docs/guides/query-metrics.md](../../docs/guides/query-metrics.md).
- [scripts/organizations_acceptance.py](../../scripts/organizations_acceptance.py).
