---
type: Capability
title: "Custom and saved metric definitions"
description: "Compute ad-hoc counts, unique users, numeric sums, averages and ratios, or save typed account-scoped definitions for reuse."
generated:
  by: process:codex
  at: "2026-10-16T13:11:11Z"
capabilityId: CAP-14
provider: mori://shinzui/kansoku
status: shipped
stability: experimental
since: unreleased
packages:
  - "kansoku-api"
  - "kansoku-core"
  - "kansoku-client"
interface:
  - "GET /metrics/custom"
  - "/metric-definitions"
  - "Kansoku.Client.Metrics.metricDefinitionsClient"
tags: [analytics]
requires:
  - CAP-6
evidence:
  - kind: conformance
    resource: "scripts/custom_metrics_acceptance.py"
    proves: "Checks aggregation values, immutable replay, OR selection, saved defaults, cohorts/traits, CRUD and pages."
  - kind: test
    resource: "kansoku-core/test/Kansoku/Metrics/CustomSpec.hs"
    proves: "Checks definition validation, wire shapes and saved/request composition."
---

# Custom and saved metric definitions

Compile typed event selections through the normal bounded metric engine without embedding SQL. Save simple or numerator/denominator definitions, conjoin request filters and override simple grouping/time defaults. List definitions using bidirectional UUID cursor pages. See [custom metrics](../guides/query-metrics.md#custom-metrics).

## Compatibility

Available in the current checkout. No release tags establish a released version, so since is unreleased. This experimental interface has no stable compatibility promise; pin the server and clients to a reviewed revision and regenerate contracts together.

## Limits

Numeric aggregates require compatible declared properties; event scopes have at most 100 names. Ratios are unbucketed, reject event-property grouping and return zero for a zero denominator. Saved filters plus request filters share the eight-group limit. Deleted cohort references fail at execution.

## Requires

- [CAP-6 — Filtered semantic metrics](filtered-semantic-metrics.md).

## Evidence

- [custom_metrics_acceptance.py](../../scripts/custom_metrics_acceptance.py) — Checks aggregation values, immutable replay, OR selection, saved defaults, cohorts/traits, CRUD and pages.
- [CustomSpec.hs](../../kansoku-core/test/Kansoku/Metrics/CustomSpec.hs) — Checks definition validation, wire shapes and saved/request composition.
