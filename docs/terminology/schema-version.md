---
type: Term
title: "schema version"
description: "The producer-selected version of a declared event’s property contract."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-9
status: current
tags: [events]
aliases:
  - "schemaVersion"
related:
  - TERM-3
  - TERM-10
  - TERM-32
anchors:
  - kind: doc
    resource: "docs/guides/send-events.md"
  - kind: doc
    resource: "docs/event-schema-governance.md"
---

# schema version

The producer-selected version of a declared event’s property contract.

Omitting schemaVersion means version 1, never the latest. For example, identify v1 records identity only, while identify v2 can write governed traits. A new catalog version does not silently upgrade an event. Valid explicit versions are in 1..65535; declared unknown versions are rejected.

Related: [event name](event-name.md), [schema catalog](schema-catalog.md), [current person trait](current-person-trait.md).

## References

- [docs/guides/send-events.md](../../docs/guides/send-events.md).
- [docs/event-schema-governance.md](../../docs/event-schema-governance.md).
