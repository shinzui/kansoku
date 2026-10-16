---
type: Term
title: "account"
description: "The credential-derived boundary within which Kansoku accepts events and authorizes analytical reads."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-6
status: current
tags: [access]
related:
  - TERM-7
  - TERM-8
  - TERM-34
anchors:
  - kind: doc
    resource: "docs/guides/send-events.md"
  - kind: doc
    resource: "docs/guides/consume-clickhouse.md"
---

# account

The credential-derived boundary within which Kansoku accepts events and authorizes analytical reads.

The authenticated credential determines accountId; producer-supplied account values are overwritten. Event identity, evidence, cohorts and saved metric names are account scoped. An organisation is a business grouping inside that boundary and does not replace it. Trusted direct SQL can read across accounts.

Related: [write key](write-key.md), [service token](service-token.md), [organisation](organisation.md).

## References

- [docs/guides/send-events.md](../../docs/guides/send-events.md).
- [docs/guides/consume-clickhouse.md](../../docs/guides/consume-clickhouse.md).
