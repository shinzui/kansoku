---
type: Capability
title: "Organisation analytics and current membership"
description: "Count organisations, combine member activity in supported metrics and segment by current organisation traits."
generated:
  by: process:codex
  at: "2026-10-16T13:11:11Z"
capabilityId: CAP-15
provider: mori://shinzui/kansoku
status: shipped
stability: experimental
since: unreleased
packages:
  - "kansoku-api"
  - "kansoku-core"
  - "kansoku-client"
interface:
  - "GET /metrics/organizations"
  - "aggregate=organizations"
  - "group v2"
  - "org: dimensions"
  - "attribution=user_organization"
tags: [analytics]
requires:
  - CAP-5
  - CAP-6
evidence:
  - kind: conformance
    resource: "scripts/organizations_acceptance.py"
    proves: "Checks joint-member funnels, retention, current traits, attribution, replay and account boundaries."
  - kind: guide
    resource: "docs/adr/0021-organization-aggregation-and-current-membership.md"
    proves: "Defines organisation timelines and membership fallback."
---

# Organisation analytics and current membership

Count nonempty organisation IDs and aggregate users, funnels, retention, conversion and feature adoption by organisation. Govern current traits through group v2. Optionally fill missing event organisation IDs from an identified user’s current group membership; explicit event IDs win. Members can jointly satisfy a funnel.

## Compatibility

Available in the current checkout. No release tags establish a released version, so since is unreleased. This experimental interface has no stable compatibility promise; pin the server and clients to a reviewed revision and regenerate contracts together.

## Limits

Organisations are analytics grouping units within a credential account, not authentication tenants. Current traits and membership can reclassify history; no implicit ungroup is defined. Sessions, acquisition, paths, experiments, stickiness and lifecycle reject organisation aggregation. Missing organisation IDs contribute no organisation.

## Requires

- [CAP-5 — Conservative identity resolution](conservative-identity-resolution.md).
- [CAP-6 — Filtered semantic metrics](filtered-semantic-metrics.md).

## Evidence

- [organizations_acceptance.py](../../scripts/organizations_acceptance.py) — Checks joint-member funnels, retention, current traits, attribution, replay and account boundaries.
- [0021-organization-aggregation-and-current-membership.md](../../docs/adr/0021-organization-aggregation-and-current-membership.md) — Defines organisation timelines and membership fallback.
