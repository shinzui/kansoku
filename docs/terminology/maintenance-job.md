---
type: Term
title: "maintenance job"
description: "The durable administrative workflow record used to checkpoint, inspect and resume cross-store data maintenance."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-71
status: current
tags: [operations]
related:
  - TERM-70
  - TERM-72
  - TERM-73
  - TERM-74
anchors:
  - kind: doc
    resource: "docs/guides/administration.md"
---

# maintenance job

The durable administrative workflow record used to checkpoint, inspect and resume cross-store data maintenance.

Confirmation persists a job and fence; list-jobs and job-status expose progress, and resume-job continues after failure. PostgreSQL is authoritative for current stage and unfinished discovery. A recovery receipt records redacted checkpoint information and cannot undo deletion. There is no automatic fence-clear command.

Related: [maintenance fence](maintenance-fence.md), [identity unlinking](identity-unlinking.md), [explicit-fact deletion](explicit-fact-deletion.md), [applied retention cutoff](applied-retention-cutoff.md).

## References

- [docs/guides/administration.md](../../docs/guides/administration.md).
