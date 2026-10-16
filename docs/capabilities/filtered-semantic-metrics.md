---
type: Capability
title: "Filtered semantic metrics"
description: "Query event, page-view, feature-adoption and revenue aggregates through typed dimensions and bounded parameterized filters."
generated:
  by: process:codex
  at: "2026-10-16T13:11:11Z"
capabilityId: CAP-6
provider: mori://shinzui/kansoku
status: shipped
stability: experimental
since: unreleased
packages:
  - "kansoku-api"
  - "kansoku-core"
interface:
  - "GET /metrics/events"
  - "GET /metrics/page-views"
  - "GET /metrics/feature-adoption"
  - "GET /metrics/revenue"
tags: [analytics]
requires:
  - CAP-1
  - CAP-4
evidence:
  - kind: test
    resource: "kansoku-core/test/Kansoku/Metrics/FilterIntegrationSpec.hs"
    proves: "Exercises native typed filters and grouping."
  - kind: test
    resource: "kansoku-core/test/Kansoku/Metrics/LimitsSpec.hs"
    proves: "Checks public input and complete-answer limits."
  - kind: guide
    resource: "docs/guides/query-metrics.md"
    proves: "Defines scalar declarations, AND/OR selection and analytical units."
---

# Filtered semantic metrics

Filter by built-in dimensions, governed scalar event properties and supported current traits; group by up to two dimensions. Repeated filters are conjoined, with bounded alternatives within a group. Return complete aggregates or a problem response under date, point, native execution and memory limits. See [query metrics](../guides/query-metrics.md).

## Compatibility

Available in the current checkout. No release tags establish a released version, so since is unreleased. This experimental interface has no stable compatibility promise; pin the server and clients to a reviewed revision and regenerate contracts together.

## Limits

Ranges are positive, half-open UTC intervals of at most 366 days; answers contain at most 10,000 points. Property selectors need compatible declarations and finite event scope. Revenue is a Float64 analytical sum in a producer-normalized unit, with no FX, refund accounting or monetary-ledger guarantee.

## Requires

- [CAP-1 — Account-scoped credentials](account-scoped-credentials.md).
- [CAP-4 — Durable delivery and recovery](durable-delivery-recovery.md).

## Evidence

- [FilterIntegrationSpec.hs](../../kansoku-core/test/Kansoku/Metrics/FilterIntegrationSpec.hs) — Exercises native typed filters and grouping.
- [LimitsSpec.hs](../../kansoku-core/test/Kansoku/Metrics/LimitsSpec.hs) — Checks public input and complete-answer limits.
- [query-metrics.md](../../docs/guides/query-metrics.md) — Defines scalar declarations, AND/OR selection and analytical units.
