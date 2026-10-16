---
type: Term
title: "write key"
description: "An account-scoped producer credential that admits events but cannot query metrics or manage analytical resources."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-7
status: current
tags: [access]
related:
  - TERM-6
  - TERM-8
  - TERM-16
anchors:
  - kind: doc
    resource: "docs/guides/send-events.md"
---

# write key

An account-scoped producer credential that admits events but cannot query metrics or manage analytical resources.

Write keys use the ksk_w_ prefix. Normal ingest uses a header; the browser beacon route requires a write key inside its body envelope and forbids credential headers. A public browser key is not an application-user identity or a secret capable of metric reads.

Related: [account](account.md), [service token](service-token.md), [partial batch acknowledgement](partial-batch-acknowledgement.md).

## References

- [docs/guides/send-events.md](../../docs/guides/send-events.md).
