---
type: Capability
title: "Activity and retention analytics"
description: "Compute exact active users, stickiness, lifecycle and retention over consistent resolved populations and closed UTC observation days."
generated:
  by: process:codex
  at: "2026-10-16T13:11:11Z"
capabilityId: CAP-8
provider: mori://shinzui/kansoku
status: shipped
stability: experimental
since: unreleased
packages:
  - "kansoku-core"
interface:
  - "GET /metrics/users"
  - "GET /metrics/stickiness"
  - "GET /metrics/lifecycle"
  - "GET /metrics/retention"
tags: [analytics]
requires:
  - CAP-5
  - CAP-6
evidence:
  - kind: test
    resource: "kansoku-core/test/Kansoku/Metrics/ActivityIntegrationSpec.hs"
    proves: "Checks rolling boundaries, consistent lookback selection, immature offsets, lifecycle and resource failures."
  - kind: conformance
    resource: "scripts/activity_acceptance.py"
    proves: "Defines end-to-end activity and retention acceptance."
---

# Activity and retention analytics

Count calendar or rolling7/rolling30 active subjects, report daily/rolling30 stickiness and classify lifecycle activity. Retention supports exact-day and on-or-after return modes with window or retained-history lifetime cohorts. Reuse the same filters, identity and default bot exclusion across lookback. See [query metrics](../guides/query-metrics.md).

## Compatibility

Available in the current checkout. No release tags establish a released version, so since is unreleased. This experimental interface has no stable compatibility promise; pin the server and clients to a reviewed revision and regenerate contracts together.

## Limits

Rolling, retention, stickiness and lifecycle use day grain and closed UTC days. Lifetime means first matching activity still retained, not first ever. Immature retention horizons are omitted. Profile-only events are excluded from activity; retention accepts at most 32 distinct offsets in 1..365.

## Requires

- [CAP-5 — Conservative identity resolution](conservative-identity-resolution.md).
- [CAP-6 — Filtered semantic metrics](filtered-semantic-metrics.md).

## Evidence

- [ActivityIntegrationSpec.hs](../../kansoku-core/test/Kansoku/Metrics/ActivityIntegrationSpec.hs) — Checks rolling boundaries, consistent lookback selection, immature offsets, lifecycle and resource failures.
- [activity_acceptance.py](../../scripts/activity_acceptance.py) — Defines end-to-end activity and retention acceptance.
