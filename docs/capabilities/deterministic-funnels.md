---
type: Capability
title: "Deterministic funnels and conversion"
description: "Measure exact funnel reach, attempts and conversion timing with sequential, strict and any-order event matching."
generated:
  by: process:codex
  at: "2026-10-16T13:11:11Z"
capabilityId: CAP-9
provider: mori://shinzui/kansoku
status: shipped
stability: experimental
since: unreleased
packages:
  - "kansoku-api"
  - "kansoku-core"
interface:
  - "GET /metrics/funnel"
  - "GET /metrics/conversion"
tags: [analytics]
requires:
  - CAP-5
  - CAP-6
evidence:
  - kind: test
    resource: "kansoku-core/test/Kansoku/Metrics/FunnelIntegrationSpec.hs"
    proves: "Checks any-order reach, attempt restarts, exclusions, attribution, timing and ordered signup conversion."
  - kind: conformance
    resource: "scripts/funnel_acceptance.py"
    proves: "Defines end-to-end funnel and diagnostic requests."
---

# Deterministic funnels and conversion

Evaluate immutable canonical timelines in millisecond occurrence/event-ID order. Select deterministic unique-user chains or nonoverlapping attempts; expose reach and exact nearest-rank p50/p90 elapsed times. Attribute properties to first touch, last touch or a named step. The conversion route measures ordered signup completion among starters.

## Compatibility

Available in the current checkout. No release tags establish a released version, so since is unreleased. This experimental interface has no stable compatibility promise; pin the server and clients to a reviewed revision and regenerate contracts together.

## Limits

At most 20 steps and a 90-day maximum inclusive window, within the bounded request interval. One event cannot satisfy repeated steps. Strict mode rejects event filters that could hide interruptions. Signup conversion rejects time grain and event-property grouping; empty denominators return zero.

## Requires

- [CAP-5 — Conservative identity resolution](conservative-identity-resolution.md).
- [CAP-6 — Filtered semantic metrics](filtered-semantic-metrics.md).

## Evidence

- [FunnelIntegrationSpec.hs](../../kansoku-core/test/Kansoku/Metrics/FunnelIntegrationSpec.hs) — Checks any-order reach, attempt restarts, exclusions, attribution, timing and ordered signup conversion.
- [funnel_acceptance.py](../../scripts/funnel_acceptance.py) — Defines end-to-end funnel and diagnostic requests.
