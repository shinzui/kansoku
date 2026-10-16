---
type: Term
title: "fingerprint expiry"
description: "The separate 180-day policy limiting eligible fingerprint evidence and cleaning expired fingerprint material."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-75
status: current
tags: [identity]
related:
  - TERM-28
  - TERM-29
  - TERM-74
anchors:
  - kind: doc
    resource: "docs/guides/administration.md"
  - kind: doc
    resource: "docs/guides/send-events.md"
---

# fingerprint expiry

The separate 180-day policy limiting eligible fingerprint evidence and cleaning expired fingerprint material.

Identity lookup excludes expired fingerprints independently of physical TTL cleanup. Confirmed retention jobs also scrub expired fingerprint keys from raw/context and replayable envelopes, even with unlimited event retention, preserving other identifiers. Event retention and fingerprint evidence expiry therefore solve different lifecycle problems.

Related: [identifier signal](identifier-signal.md), [identity evidence](identity-evidence.md), [applied retention cutoff](applied-retention-cutoff.md).

## References

- [docs/guides/administration.md](../../docs/guides/administration.md).
- [docs/guides/send-events.md](../../docs/guides/send-events.md).
