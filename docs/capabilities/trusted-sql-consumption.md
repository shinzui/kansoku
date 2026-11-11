---
type: Capability
title: "Trusted SQL analytics consumption"
description: "Expose constrained ClickHouse reader projections and executable recipes for trusted dashboard and experiment consumers."
timestamp: 2026-11-11T16:18:51Z
generated:
  by: process:codex
  at: "2026-10-16T13:11:11Z"
capabilityId: CAP-19
provider: mori://shinzui/kansoku
status: shipped
stability: experimental
since: unreleased
packages:
  - "kansoku-core"
  - "kansoku-server"
interface:
  - "analytics.events_resolved"
  - "analytics.events_resolved_v3"
  - "analytics.events_analytics_v1"
  - "kansoku_reader role"
  - "Kansoku.ClickHouse.Consistency.withConsistentReadback"
tags: [clients]
requires:
  - CAP-5
evidence:
  - kind: conformance
    resource: "scripts/reader_acceptance.py"
    proves: "Defines reader grants, projection/recipe agreement and actual consumer integration checks."
  - kind: guide
    resource: "docs/guides/consume-clickhouse.md"
    proves: "Documents projection columns, role bounds, SQL recipes and supported consumer configurations."
---

# Trusted SQL analytics consumption

Provide explicit reader views, a constrained read-only role and parameterized user/revenue/funnel/experiment-input recipes. The acceptance harness includes real Grafana and GrowthBook adapter checks. Ordinary SQL reads are eventually consistent; owned verification uses `withConsistentReadback`, which synchronizes the schema and reviewed tables on one checked connection before selecting. See [ClickHouse consumption](../guides/consume-clickhouse.md) and [consumer conformance](../guides/consumer-conformance.md).

## Compatibility

Available in the current checkout. No release tags establish a released version, so since is unreleased. This experimental interface has no stable compatibility promise; pin the server and clients to a reviewed revision and regenerate contracts together.

## Limits

Direct SQL is a trusted operator surface across all accounts; account predicates do not enforce tenant authorization. SQL readers do not acquire the HTTP maintenance fence and must pause externally for maintenance. External readers needing read-back must implement the same replica barriers; a fixed sleep proves nothing. Only documented projections are stable surfaces; recipes do not add experiment statistics or all HTTP semantics.

## Requires

- [CAP-5 — Conservative identity resolution](conservative-identity-resolution.md).

## Evidence

- [reader_acceptance.py](../../scripts/reader_acceptance.py) — Defines reader grants, projection/recipe agreement and actual consumer integration checks.
- [consume-clickhouse.md](../../docs/guides/consume-clickhouse.md) — Documents projection columns, role bounds, SQL recipes and supported consumer configurations.
