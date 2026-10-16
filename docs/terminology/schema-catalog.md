---
type: Term
title: "schema catalog"
description: "The published machine-readable registry of governed event versions, property constraints and identifier kinds."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-10
status: current
tags: [events]
related:
  - TERM-9
anchors:
  - kind: doc
    resource: "docs/guides/send-events.md"
  - kind: doc
    resource: "docs/event-schema-governance.md"
  - kind: file
    resource: "docs/contracts/events.json"
---

# schema catalog

The published machine-readable registry of governed event versions, property constraints and identifier kinds.

Read it from GET /v1/schemas or the generated committed events.json artifact. Its catalogVersion versions the publication format, separately from each event schemaVersion. The Haskell registry is authoritative; maintainers generate the artifact and release schema changes with the service.

Related: [schema version](schema-version.md).

## References

- [docs/guides/send-events.md](../../docs/guides/send-events.md).
- [docs/event-schema-governance.md](../../docs/event-schema-governance.md).
- [docs/contracts/events.json](../../docs/contracts/events.json).
