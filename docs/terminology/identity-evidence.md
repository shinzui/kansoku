---
type: Term
title: "identity evidence"
description: "Retained account-scoped observations linking identifier signals or session contexts to explicit users."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-29
status: current
tags: [identity]
related:
  - TERM-28
  - TERM-30
  - TERM-31
anchors:
  - kind: doc
    resource: "docs/guides/send-events.md"
  - kind: file
    resource: "scripts/identity_acceptance.py"
---

# identity evidence

Retained account-scoped observations linking identifier signals or session contexts to explicit users.

Evidence is consulted at query time rather than overwriting raw event identities. Unambiguous session evidence can distinguish users sharing a cookie; other eligible unique signals compete by confidence. Ties between users and shared ambiguous bindings do not authorize an arbitrary merge. New retained evidence can change historical resolution.

Related: [identifier signal](identifier-signal.md), [canonical subject](canonical-subject.md), [identity conflict](identity-conflict.md).

## References

- [docs/guides/send-events.md](../../docs/guides/send-events.md).
- [scripts/identity_acceptance.py](../../scripts/identity_acceptance.py).
