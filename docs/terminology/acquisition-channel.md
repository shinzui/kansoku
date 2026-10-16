---
type: Term
title: "acquisition channel"
description: "The server-derived category of a session’s attributed campaign or external referrer."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-57
status: current
tags: [web]
related:
  - TERM-53
  - TERM-54
anchors:
  - kind: doc
    resource: "docs/guides/web-enrichment.md"
  - kind: file
    resource: "kansoku-core/src/Kansoku/Ingest/Channel.hs"
---

# acquisition channel

The server-derived category of a session’s attributed campaign or external referrer.

Versioned rules choose channels such as paid_social, organic_search, referral or direct using ordered UTM/referrer/click-ID checks. Sessions use their attributed first touch. This is deterministic classification of producer/request evidence, not proof of spend or a configurable multi-touch attribution model.

Related: [web session](web-session.md), [first-touch attribution](first-touch-attribution.md).

## References

- [docs/guides/web-enrichment.md](../../docs/guides/web-enrichment.md).
- [kansoku-core/src/Kansoku/Ingest/Channel.hs](../../kansoku-core/src/Kansoku/Ingest/Channel.hs).
