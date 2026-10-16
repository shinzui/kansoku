---
type: Term
title: "applied retention cutoff"
description: "The persisted UTC event boundary advanced by a confirmed retention job and enforced by analytical reads and later writes."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-74
status: current
tags: [operations]
related:
  - TERM-18
  - TERM-48
  - TERM-71
  - TERM-75
anchors:
  - kind: doc
    resource: "docs/guides/administration.md"
---

# applied retention cutoff

The persisted UTC event boundary advanced by a confirmed retention job and enforced by analytical reads and later writes.

Apply-retention snapshots command time minus configured event-retention days, scrubs expired raw/replayable payloads and rebuilds derived state before releasing the fence. Configuration alone does nothing. TTL is physical cleanup, not the analytical predicate. Returning to unlimited cannot recover removed data; acceptance identities remain reserved.

Related: [acceptance ledger](acceptance-ledger.md), [retained-history lifetime](retained-history-lifetime.md), [maintenance job](maintenance-job.md), [fingerprint expiry](fingerprint-expiry.md).

## References

- [docs/guides/administration.md](../../docs/guides/administration.md).
