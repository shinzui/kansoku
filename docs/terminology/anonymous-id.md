---
type: Term
title: "anonymous ID"
description: "The producer identifier for activity without a directly asserted user identity."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-26
status: current
tags: [identity]
aliases:
  - "anonymousId"
related:
  - TERM-27
  - TERM-29
  - TERM-30
anchors:
  - kind: doc
    resource: "docs/guides/send-events.md"
  - kind: file
    resource: "scripts/identity_acceptance.py"
---

# anonymous ID

The producer identifier for activity without a directly asserted user identity.

Browser cookies commonly supply anonymousId. Conservative evidence may later bind those observations to a user. Unresolved anonymous text stays in an anonymous: namespace, so an anonymous value alice is distinct from user alice. A cookie shared by several users is not resolved by simply picking the latest user.

Related: [explicit user ID](explicit-user-id.md), [identity evidence](identity-evidence.md), [canonical subject](canonical-subject.md).

## References

- [docs/guides/send-events.md](../../docs/guides/send-events.md).
- [scripts/identity_acceptance.py](../../scripts/identity_acceptance.py).
