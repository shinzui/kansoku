---
type: Term
title: "canonical subject"
description: "The resolved identity used to count and join an analytical event."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-30
status: current
tags: [identity]
aliases:
  - "canonical_user"
related:
  - TERM-26
  - TERM-27
  - TERM-29
anchors:
  - kind: doc
    resource: "docs/guides/consume-clickhouse.md"
  - kind: file
    resource: "scripts/identity_acceptance.py"
---

# canonical subject

The resolved identity used to count and join an analytical event.

Canonical user text is user:<id> for explicit/resolved users, anonymous:<id> for unresolved anonymous identities, or empty when neither exists. Prefixes preserve the original text rather than merging namespaces. Empty subjects are excluded from user counts. Exact reports use current evidence, so a past event’s subject may change.

Related: [anonymous ID](anonymous-id.md), [explicit user ID](explicit-user-id.md), [identity evidence](identity-evidence.md).

## References

- [docs/guides/consume-clickhouse.md](../../docs/guides/consume-clickhouse.md).
- [scripts/identity_acceptance.py](../../scripts/identity_acceptance.py).
