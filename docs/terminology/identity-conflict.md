---
type: Term
title: "identity conflict"
description: "Evidence that one signal or session context refers to multiple users and cannot choose a unique binding by itself."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-31
status: current
tags: [identity]
related:
  - TERM-28
  - TERM-29
  - TERM-30
anchors:
  - kind: doc
    resource: "docs/guides/send-events.md"
  - kind: file
    resource: "scripts/identity_acceptance.py"
---

# identity conflict

Evidence that one signal or session context refers to multiple users and cannot choose a unique binding by itself.

A shared device or cookie can produce conflicts. Eligible unique evidence may still resolve an event, but an equal-confidence tie retains the anonymous subject. Conflict diagnostics are not a list of users that should be merged and do not supersede an explicit user ID.

Related: [identifier signal](identifier-signal.md), [identity evidence](identity-evidence.md), [canonical subject](canonical-subject.md).

## References

- [docs/guides/send-events.md](../../docs/guides/send-events.md).
- [scripts/identity_acceptance.py](../../scripts/identity_acceptance.py).
