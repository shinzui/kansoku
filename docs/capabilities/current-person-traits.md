---
type: Capability
title: "Governed current person traits"
description: "Set or initialize declared person traits and segment supported metrics by the resolved user’s current values."
generated:
  by: process:codex
  at: "2026-10-16T13:11:11Z"
capabilityId: CAP-12
provider: mori://shinzui/kansoku
status: shipped
stability: experimental
since: unreleased
packages:
  - "kansoku-api"
  - "kansoku-core"
  - "kansoku-client"
interface:
  - "identify v2"
  - "identify_once v1"
  - "user: dimensions"
tags: [identity]
requires:
  - CAP-5
  - CAP-6
evidence:
  - kind: conformance
    resource: "scripts/traits_acceptance.py"
    proves: "Exercises trait writes, ordering, segmentation and replay behavior."
  - kind: guide
    resource: "docs/guides/query-metrics.md"
    proves: "Defines governed fields, set/set-once precedence and whole-session ownership."
---

# Governed current person traits

Write supported scalar traits with explicit-user identify v2 or identify_once v1 events. Latest set wins; set-once supplies the earliest value only when no set exists. Segment by user: dimensions after conservative resolution, including attributed whole sessions. Omitted keys remain unchanged.

## Compatibility

Available in the current checkout. No release tags establish a released version, so since is unreleased. This experimental interface has no stable compatibility promise; pin the server and clients to a reviewed revision and regenerate contracts together.

## Limits

Identify v1 has identity effects only. Null is rejected; unknown properties do not become governed traits. Current traits reclassify historical reports and are not event-time snapshots or authorization facts. Unresolved anonymous subjects inherit no user traits.

## Requires

- [CAP-5 — Conservative identity resolution](conservative-identity-resolution.md).
- [CAP-6 — Filtered semantic metrics](filtered-semantic-metrics.md).

## Evidence

- [traits_acceptance.py](../../scripts/traits_acceptance.py) — Exercises trait writes, ordering, segmentation and replay behavior.
- [query-metrics.md](../../docs/guides/query-metrics.md) — Defines governed fields, set/set-once precedence and whole-session ownership.
