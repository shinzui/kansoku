---
type: Term
title: "rejection quarantine"
description: "The optional bounded diagnostic store for individual events rejected during ingest validation."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-19
status: current
tags: [ingestion]
related:
  - TERM-16
  - TERM-18
  - TERM-23
anchors:
  - kind: doc
    resource: "docs/guides/send-events.md"
  - kind: doc
    resource: "docs/guides/administration.md"
---

# rejection quarantine

The optional bounded diagnostic store for individual events rejected during ingest validation.

Quarantine allows metadata inspection and explicit payload access through kansoku-admin. Rejected payloads do not reserve event IDs or establish identity bindings. Envelope-level failures do not become per-event quarantine entries. Its expiry/caps and purge policy are separate from accepted-event retention.

Related: [partial batch acknowledgement](partial-batch-acknowledgement.md), [acceptance ledger](acceptance-ledger.md), [archive](archive.md).

## References

- [docs/guides/send-events.md](../../docs/guides/send-events.md).
- [docs/guides/administration.md](../../docs/guides/administration.md).
