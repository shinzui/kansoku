---
type: Term
title: "acceptance ledger"
description: "The durable PostgreSQL record of logical event identities, producer hashes, first acceptance times and erasure dispositions."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-18
status: current
tags: [ingestion]
related:
  - TERM-17
  - TERM-22
  - TERM-74
anchors:
  - kind: doc
    resource: "docs/guides/operations.md"
  - kind: doc
    resource: "docs/guides/administration.md"
---

# acceptance ledger

The durable PostgreSQL record of logical event identities, producer hashes, first acceptance times and erasure dispositions.

The ledger lets equal retries acknowledge prior acceptance without publishing another message. It contains no full event payload and has no automatic expiry. Purging a queue or expiring analytical payloads must not erase this identity history, or an old event could be accepted and normalized again.

Related: [immutable acceptance](immutable-acceptance.md), [canonical fact](canonical-fact.md), [applied retention cutoff](applied-retention-cutoff.md).

## References

- [docs/guides/operations.md](../../docs/guides/operations.md).
- [docs/guides/administration.md](../../docs/guides/administration.md).
