---
type: Term
title: "event source"
description: "The origin category of an observation, chosen from web, app, service, worker, email or agent."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-4
status: current
tags: [events]
aliases:
  - "source"
related:
  - TERM-5
  - TERM-53
anchors:
  - kind: doc
    resource: "docs/guides/send-events.md"
  - kind: file
    resource: "kansoku-api/src/Kansoku/Event/Types.hs"
---

# event source

The origin category of an observation, chosen from web, app, service, worker, email or agent.

Use source=web for browser observations and source=service for backend observations. This fixed category differs from sourceService, which names a particular producer. Web source determines eligibility for session assembly and request-derived web classifications.

Related: [source service](source-service.md), [web session](web-session.md).

## References

- [docs/guides/send-events.md](../../docs/guides/send-events.md).
- [kansoku-api/src/Kansoku/Event/Types.hs](../../kansoku-api/src/Kansoku/Event/Types.hs).
