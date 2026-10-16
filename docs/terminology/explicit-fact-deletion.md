---
type: Term
title: "explicit-fact deletion"
description: "The confirmed erasure mode that additionally removes the target account/user’s explicitly attributed event facts."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-73
status: current
tags: [operations]
related:
  - TERM-18
  - TERM-71
  - TERM-72
anchors:
  - kind: doc
    resource: "docs/guides/administration.md"
---

# explicit-fact deletion

The confirmed erasure mode that additionally removes the target account/user’s explicitly attributed event facts.

Erase-user --delete-events extends unlinking under the maintenance job. Minimal accepted hashes/dispositions still reserve logical IDs so old retries cannot restore removed payloads. New event IDs can establish new observations; this is not a permanent user ban or a search for unknown personal text throughout arbitrary JSON.

Related: [acceptance ledger](acceptance-ledger.md), [maintenance job](maintenance-job.md), [identity unlinking](identity-unlinking.md).

## References

- [docs/guides/administration.md](../../docs/guides/administration.md).
