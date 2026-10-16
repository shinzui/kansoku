---
type: Term
title: "reader projection"
description: "A documented ClickHouse view exposed to trusted SQL consumers with an explicit analytical column contract."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-76
status: current
tags: [operations]
related:
  - TERM-6
  - TERM-22
  - TERM-70
anchors:
  - kind: doc
    resource: "docs/guides/consume-clickhouse.md"
  - kind: file
    resource: "scripts/reader_acceptance.py"
---

# reader projection

A documented ClickHouse view exposed to trusted SQL consumers with an explicit analytical column contract.

The reader role grants only documented projections, with read-only time/memory/result limits. Events_analytics_v1 takes account and UTC bounds, while compatibility views expose documented resolved columns. Reader access spans accounts and bypasses the HTTP fence; it is an operator integration, not tenant-authorized end-user SQL.

Related: [account](account.md), [canonical fact](canonical-fact.md), [maintenance fence](maintenance-fence.md).

## References

- [docs/guides/consume-clickhouse.md](../../docs/guides/consume-clickhouse.md).
- [scripts/reader_acceptance.py](../../scripts/reader_acceptance.py).
