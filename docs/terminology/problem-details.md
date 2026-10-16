---
type: Term
title: "problem details"
description: "The structured application/problem+json error contract carrying HTTP status, stable code and retryability."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-79
status: current
tags: [queries]
related:
  - TERM-16
  - TERM-42
  - TERM-70
anchors:
  - kind: doc
    resource: "docs/guides/send-events.md"
  - kind: doc
    resource: "docs/guides/query-metrics.md"
  - kind: file
    resource: "kansoku-api/src/Kansoku/Api/Response.hs"
---

# problem details

The structured application/problem+json error contract carrying HTTP status, stable code and retryability.

Problems carry type, title, status, detail, code and retryable; clients should act on code/retryable rather than human detail. Retryable 429 uses Retry-After, while permanent query-limit errors require changed input. Relay pagination faults deliberately use their distinct JSON error shape.

Related: [partial batch acknowledgement](partial-batch-acknowledgement.md), [complete-or-error answer](complete-or-error.md), [maintenance fence](maintenance-fence.md).

## References

- [docs/guides/send-events.md](../../docs/guides/send-events.md).
- [docs/guides/query-metrics.md](../../docs/guides/query-metrics.md).
- [kansoku-api/src/Kansoku/Api/Response.hs](../../kansoku-api/src/Kansoku/Api/Response.hs).
