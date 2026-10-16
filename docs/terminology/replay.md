---
type: Term
title: "replay"
description: "A repeated delivery of existing accepted facts that preserves their logical event identity."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-24
status: current
tags: [ingestion]
related:
  - TERM-17
  - TERM-21
  - TERM-23
  - TERM-70
anchors:
  - kind: doc
    resource: "docs/guides/administration.md"
  - kind: doc
    resource: "docs/guides/operations.md"
---

# replay

A repeated delivery of existing accepted facts that preserves their logical event identity.

Queue redelivery and administrative archive replay may create another physical insert attempt without another logical event. Confirmed archive replay records sends transactionally so concurrent/retried commands cannot republish completed archive rows. It respects dispositions, fences and applied retention rather than restoring erased history.

Related: [immutable acceptance](immutable-acceptance.md), [at-least-once delivery](at-least-once-delivery.md), [archive](archive.md), [maintenance fence](maintenance-fence.md).

## References

- [docs/guides/administration.md](../../docs/guides/administration.md).
- [docs/guides/operations.md](../../docs/guides/operations.md).
