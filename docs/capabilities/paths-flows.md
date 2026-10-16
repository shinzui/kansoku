---
type: Capability
title: "Event paths and page flows"
description: "Explore forward or reverse canonical-user transitions from event or route anchors with bounded top-K folding."
generated:
  by: process:codex
  at: "2026-10-16T13:11:11Z"
capabilityId: CAP-10
provider: mori://shinzui/kansoku
status: shipped
stability: experimental
since: unreleased
packages:
  - "kansoku-api"
  - "kansoku-core"
  - "kansoku-client"
interface:
  - "GET /metrics/paths"
  - "Kansoku.Client.Metrics.pathsClient"
tags: [analytics]
requires:
  - CAP-5
  - CAP-6
evidence:
  - kind: conformance
    resource: "scripts/paths-acceptance.py"
    proves: "Defines HTTP proof for event paths, route flows, reverse traversal and bounds."
  - kind: test
    resource: "kansoku-core/test/Kansoku/Metrics/PathsSpec.hs"
    proves: "Checks path option validation and selection."
---

# Event paths and page flows

Build one ordered sequence per canonical user. Start at a first matching anchor, or walk backward from the last matching end anchor. Route mode uses nonbot page views and collapses consecutive identical paths, with optional entry mode. Report ranked transitions and fold lower-ranked transitions into an explicit other point.

## Compatibility

Available in the current checkout. No release tags establish a released version, so since is unreleased. This experimental interface has no stable compatibility promise; pin the server and clients to a reviewed revision and regenerate contracts together.

## Limits

These are per-user interval flows, not per-session paths. Filters select before anchoring. At most 10 transitions and top 20 per step, with a 90-day maximum window. The synthetic end marker means observed exhaustion within the window, not permanent abandonment.

## Requires

- [CAP-5 — Conservative identity resolution](conservative-identity-resolution.md).
- [CAP-6 — Filtered semantic metrics](filtered-semantic-metrics.md).

## Evidence

- [paths-acceptance.py](../../scripts/paths-acceptance.py) — Defines HTTP proof for event paths, route flows, reverse traversal and bounds.
- [PathsSpec.hs](../../kansoku-core/test/Kansoku/Metrics/PathsSpec.hs) — Checks path option validation and selection.
