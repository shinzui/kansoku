---
type: Term
title: "current organisation membership"
description: "The latest explicit-user group observation used as optional fallback for an event missing an organisation ID."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-36
status: current
tags: [identity]
aliases:
  - "current organization membership"
related:
  - TERM-27
  - TERM-34
  - TERM-35
anchors:
  - kind: doc
    resource: "docs/guides/query-metrics.md"
  - kind: file
    resource: "scripts/organizations_acceptance.py"
---

# current organisation membership

The latest explicit-user group observation used as optional fallback for an event missing an organisation ID.

Attribution=user_organization fills only missing IDs from the resolved user’s current membership. An event’s explicit organisation always wins; unresolved anonymous subjects inherit nothing. Later moves can reclassify history. There is no implicit ungroup event, and default event attribution does not apply membership fallback.

Related: [explicit user ID](explicit-user-id.md), [organisation](organisation.md), [current organisation trait](current-organisation-trait.md).

## References

- [docs/guides/query-metrics.md](../../docs/guides/query-metrics.md).
- [scripts/organizations_acceptance.py](../../scripts/organizations_acceptance.py).
