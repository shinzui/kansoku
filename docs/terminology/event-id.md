---
type: Term
title: "event ID"
description: "The producer-generated key that permanently identifies one logical event within an account."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-2
status: current
tags: [events]
aliases:
  - "eventId"
related:
  - TERM-6
  - TERM-17
  - TERM-18
anchors:
  - kind: doc
    resource: "docs/guides/send-events.md"
  - kind: file
    resource: "kansoku-core/test/Kansoku/Ingest/AcceptanceSpec.hs"
---

# event ID

The producer-generated key that permanently identifies one logical event within an account.

Retry an uncertain delivery with the same eventId and the same original producer content. Equal retries acknowledge the existing event; changed content under an accepted ID conflicts. IDs may repeat in different accounts. They are distinct from physical queue message IDs and ClickHouse insert attempts.

Related: [account](account.md), [immutable acceptance](immutable-acceptance.md), [acceptance ledger](acceptance-ledger.md).

## References

- [docs/guides/send-events.md](../../docs/guides/send-events.md).
- [kansoku-core/test/Kansoku/Ingest/AcceptanceSpec.hs](../../kansoku-core/test/Kansoku/Ingest/AcceptanceSpec.hs).
