---
type: Term
title: "source service"
description: "The optional producer name that distinguishes applications or properties inside an account."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-5
status: current
tags: [events]
aliases:
  - "sourceService"
related:
  - TERM-4
  - TERM-6
  - TERM-53
anchors:
  - kind: doc
    resource: "docs/guides/query-metrics.md"
  - kind: file
    resource: "kansoku-api/src/Kansoku/Event/Types.hs"
---

# source service

The optional producer name that distinguishes applications or properties inside an account.

For example, marketing-site and billing-worker can share an account while remaining separately filterable. Session identity includes source service, so equal session IDs from different services remain separate. It does not establish shared browser identity or an authorization boundary.

Related: [event source](event-source.md), [account](account.md), [web session](web-session.md).

## References

- [docs/guides/query-metrics.md](../../docs/guides/query-metrics.md).
- [kansoku-api/src/Kansoku/Event/Types.hs](../../kansoku-api/src/Kansoku/Event/Types.hs).
