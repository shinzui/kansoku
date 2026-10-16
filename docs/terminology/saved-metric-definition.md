---
type: Term
title: "saved metric definition"
description: "An account-scoped named custom metric specification stored for repeated execution."
generated:
  by: process:codex
  at: "2026-10-16T13:15:03Z"
termId: TERM-69
status: current
tags: [segments]
related:
  - TERM-50
  - TERM-68
anchors:
  - kind: doc
    resource: "docs/guides/query-metrics.md"
  - kind: file
    resource: "kansoku-api/src/Kansoku/Metrics/DefinitionApi.hs"
---

# saved metric definition

An account-scoped named custom metric specification stored for repeated execution.

Save a simple definition or explicit numerator/denominator components and execute it by name on /metrics/custom. Request filters conjoin with saved filters; simple group/time defaults can be overridden. UUID-keyset list pages are current reads. Deleting a referenced cohort makes execution fail rather than retaining old membership.

Related: [saved cohort](saved-cohort.md), [custom metric](custom-metric.md).

## References

- [docs/guides/query-metrics.md](../../docs/guides/query-metrics.md).
- [kansoku-api/src/Kansoku/Metrics/DefinitionApi.hs](../../kansoku-api/src/Kansoku/Metrics/DefinitionApi.hs).
