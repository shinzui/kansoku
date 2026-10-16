---
type: Term
title: "archive"
description: "The queue’s retained message store for dead-lettered or otherwise archived delivery envelopes."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-23
status: current
tags: [ingestion]
related:
  - TERM-19
  - TERM-24
anchors:
  - kind: doc
    resource: "docs/guides/operations.md"
  - kind: doc
    resource: "docs/guides/administration.md"
---

# archive

The queue’s retained message store for dead-lettered or otherwise archived delivery envelopes.

Inspect an archived malformed payload and its producing version before replay. Archive replay republishes unchanged eligible envelopes under a transactional replay ledger; archive rows remain until purge or retention cleanup. The archive is neither a backup of all events nor the rejection quarantine.

Related: [rejection quarantine](rejection-quarantine.md), [replay](replay.md).

## References

- [docs/guides/operations.md](../../docs/guides/operations.md).
- [docs/guides/administration.md](../../docs/guides/administration.md).
