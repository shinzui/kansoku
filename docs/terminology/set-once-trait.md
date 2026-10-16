---
type: Term
title: "set-once trait"
description: "A governed user-trait initialization used only when no set observation exists for that key."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-33
status: current
tags: [identity]
related:
  - TERM-12
  - TERM-32
broader:
  - TERM-32
anchors:
  - kind: doc
    resource: "docs/guides/query-metrics.md"
  - kind: file
    resource: "scripts/traits_acceptance.py"
---

# set-once trait

A governed user-trait initialization used only when no set observation exists for that key.

Identify_once v1 supplies initial values. The earliest set-once observation wins among initializations, but any set observation overrides set-once for the key. This is not first arrival at the server: accepted occurrence/receipt/event-ID ordering determines the winner. Duplicate replay cannot introduce a new value.

Related: [current person trait](current-person-trait.md), [receipt time](receipt-time.md).

## References

- [docs/guides/query-metrics.md](../../docs/guides/query-metrics.md).
- [scripts/traits_acceptance.py](../../scripts/traits_acceptance.py).
