---
type: Capability
title: "Exposure-based experiment analytics"
description: "Compare variant exposures, post-exposure conversion and funnels while exposing contamination and exclusive first-observed assignment diagnostics."
generated:
  by: process:codex
  at: "2026-10-16T13:11:11Z"
capabilityId: CAP-11
provider: mori://shinzui/kansoku
status: shipped
stability: experimental
since: unreleased
packages:
  - "kansoku-api"
  - "kansoku-core"
  - "kansoku-client"
interface:
  - "GET /metrics/experiments"
  - "GET /metrics/experiments/conversion"
  - "GET /metrics/experiments/funnel"
tags: [analytics]
requires:
  - CAP-9
evidence:
  - kind: test
    resource: "kansoku-core/test/Kansoku/Metrics/FunnelIntegrationSpec.hs"
    proves: "Checks exposure-gated funnels and contamination versus exclusive assignment shares."
  - kind: guide
    resource: "docs/guides/query-metrics.md"
    proves: "Separates approximate raw exposure sketches from exact resolved conversion and diagnostics."
---

# Exposure-based experiment analytics

Use experiment_viewed facts to establish variant exposure. Conversion and funnels count exact resolved subjects only at or after each variant exposure. Diagnostics count users seeing multiple variants and assign each user exclusively to their earliest observed variant per scope. Default unsegmented exposures retain the raw-identity sketch.

## Compatibility

Available in the current checkout. No release tags establish a released version, so since is unreleased. This experimental interface has no stable compatibility promise; pin the server and clients to a reviewed revision and regenerate contracts together.

## Limits

There is no randomization service, significance test or winner selection. Multi-variant users remain in every observed variant for conversion/funnels. Approximate raw exposure denominators differ from exact stitched users; first observed exposure is not an authoritative assignment log.

## Requires

- [CAP-9 — Deterministic funnels and conversion](deterministic-funnels.md).

## Evidence

- [FunnelIntegrationSpec.hs](../../kansoku-core/test/Kansoku/Metrics/FunnelIntegrationSpec.hs) — Checks exposure-gated funnels and contamination versus exclusive assignment shares.
- [query-metrics.md](../../docs/guides/query-metrics.md) — Separates approximate raw exposure sketches from exact resolved conversion and diagnostics.
