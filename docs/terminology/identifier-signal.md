---
type: Term
title: "identifier signal"
description: "A typed opaque identifier supplied as evidence for resolving an event’s user."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-28
status: current
tags: [identity]
related:
  - TERM-29
  - TERM-31
  - TERM-75
anchors:
  - kind: doc
    resource: "docs/guides/send-events.md"
  - kind: file
    resource: "kansoku-api/src/Kansoku/Event/Types.hs"
---

# identifier signal

A typed opaque identifier supplied as evidence for resolving an event’s user.

The closed kinds are cookie, device, fingerprint, email_hmac and legacy email_sha256. Values are bounded printable ASCII without whitespace. The kind controls confidence/expiry policy. A keyed email value must be prepared by a trusted backend; the server validates its envelope, not the digest’s construction.

Related: [identity evidence](identity-evidence.md), [identity conflict](identity-conflict.md), [fingerprint expiry](fingerprint-expiry.md).

## References

- [docs/guides/send-events.md](../../docs/guides/send-events.md).
- [kansoku-api/src/Kansoku/Event/Types.hs](../../kansoku-api/src/Kansoku/Event/Types.hs).
