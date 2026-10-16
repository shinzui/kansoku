---
type: Term
title: "organisation"
description: "A business grouping of analytics activity and users within a Kansoku account."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-34
status: current
tags: [identity]
aliases:
  - "organization"
related:
  - TERM-6
  - TERM-35
  - TERM-36
anchors:
  - kind: doc
    resource: "docs/guides/query-metrics.md"
  - kind: file
    resource: "scripts/organizations_acceptance.py"
---

# organisation

A business grouping of analytics activity and users within a Kansoku account.

Events can carry organizationId, and supported metrics can count distinct organisations or combine member timelines. One member may start a funnel and another finish it. The credential account still enforces isolation; organisation IDs and reported traits are not authorization facts.

Related: [account](account.md), [current organisation trait](current-organisation-trait.md), [current organisation membership](current-organisation-membership.md).

## References

- [docs/guides/query-metrics.md](../../docs/guides/query-metrics.md).
- [scripts/organizations_acceptance.py](../../scripts/organizations_acceptance.py).
