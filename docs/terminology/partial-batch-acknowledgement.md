---
type: Term
title: "partial batch acknowledgement"
description: "An HTTP 202 response that reports acceptance and indexed rejection outcomes for individual submitted events."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-16
status: current
tags: [ingestion]
related:
  - TERM-17
  - TERM-21
anchors:
  - kind: doc
    resource: "docs/guides/send-events.md"
  - kind: file
    resource: "kansoku-api/src/Kansoku/Ingest/Api.hs"
---

# partial batch acknowledgement

An HTTP 202 response that reports acceptance and indexed rejection outcomes for individual submitted events.

A syntactically valid batch can accept good events while rejecting invalid ones. Original indexes let producers identify rejected items. HTTP 202 alone does not mean every event succeeded or that ClickHouse already contains accepted events. Beacon callers cannot read this acknowledgement from sendBeacon.

Related: [immutable acceptance](immutable-acceptance.md), [at-least-once delivery](at-least-once-delivery.md).

## References

- [docs/guides/send-events.md](../../docs/guides/send-events.md).
- [kansoku-api/src/Kansoku/Ingest/Api.hs](../../kansoku-api/src/Kansoku/Ingest/Api.hs).
