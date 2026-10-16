---
type: Term
title: "identity unlinking"
description: "The default erasure operation that removes matching identity links and current traits while preserving explicit historical event facts."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-72
status: current
tags: [operations]
related:
  - TERM-29
  - TERM-71
  - TERM-73
anchors:
  - kind: doc
    resource: "docs/guides/administration.md"
  - kind: doc
    resource: "docs/runbooks/identity-data-deletion.md"
---

# identity unlinking

The default erasure operation that removes matching identity links and current traits while preserving explicit historical event facts.

Erase-user without --delete-events scrubs discovered cookies, mapped identifiers, session links, traits and coordinated replayable sources. Explicit user IDs or arbitrary personal text embedded in event JSON may remain. Probabilistic/shared evidence never authorizes deletion of another user’s anonymous facts. This is narrower than explicit-fact deletion.

Related: [identity evidence](identity-evidence.md), [maintenance job](maintenance-job.md), [explicit-fact deletion](explicit-fact-deletion.md).

## References

- [docs/guides/administration.md](../../docs/guides/administration.md).
- [docs/runbooks/identity-data-deletion.md](../../docs/runbooks/identity-data-deletion.md).
