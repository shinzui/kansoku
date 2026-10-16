---
type: Term
title: "service token"
description: "An account-scoped credential that permits event ingestion and protected analytics or resource operations."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-8
status: current
tags: [access]
related:
  - TERM-6
  - TERM-7
anchors:
  - kind: doc
    resource: "docs/guides/send-events.md"
  - kind: doc
    resource: "docs/guides/administration.md"
---

# service token

An account-scoped credential that permits event ingestion and protected analytics or resource operations.

Service tokens use the ksk_s_ prefix and authenticate metric, cohort and saved-definition requests. Keep them on trusted servers. They cannot be used on the body-key beacon route, which deliberately accepts only public write keys. Revocation applies on the next authenticated request.

Related: [account](account.md), [write key](write-key.md).

## References

- [docs/guides/send-events.md](../../docs/guides/send-events.md).
- [docs/guides/administration.md](../../docs/guides/administration.md).
