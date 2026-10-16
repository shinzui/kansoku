---
type: Capability
title: "Saved behavioural and static cohorts"
description: "Manage account-scoped user segments and select metric populations using query-time behaviour or uploaded membership."
generated:
  by: process:codex
  at: "2026-10-16T13:11:11Z"
capabilityId: CAP-13
provider: mori://shinzui/kansoku
status: shipped
stability: experimental
since: unreleased
packages:
  - "kansoku-api"
  - "kansoku-core"
  - "kansoku-client"
interface:
  - "/cohorts"
  - "/cohorts/{id}/members"
  - "/cohorts/{id}/size"
  - "cohort: filters and grouping"
tags: [analytics]
requires:
  - CAP-5
  - CAP-6
evidence:
  - kind: conformance
    resource: "scripts/cohorts_acceptance.py"
    proves: "Checks definition CRUD, member replacement, pages, selection, erasure and account isolation."
  - kind: module
    resource: "kansoku-api/src/Kansoku/Cohort/Api.hs"
    proves: "Declares the served service-token routes and Relay page responses."
---

# Saved behavioural and static cohorts

Save behavioural conditions and current-trait selectors, or replace explicit static user lists. Resolve behavioural membership over each condition’s window anchored on query to. Include/exclude cohorts or group metric results into in/out. Return cursor pages for definitions/members and a separate size resource.

## Compatibility

Available in the current checkout. No release tags establish a released version, so since is unreleased. This experimental interface has no stable compatibility promise; pin the server and clients to a reviewed revision and regenerate contracts together.

## Limits

Cohorts contain identified users; anonymous-only subjects are out. Up to four behavioural event conditions, no nested cohorts or sequence criteria. Static replacement accepts at most 50,000 IDs subject to body limits. Page walks and historical membership have no snapshot guarantee; current identity/traits can change answers.

## Requires

- [CAP-5 — Conservative identity resolution](conservative-identity-resolution.md).
- [CAP-6 — Filtered semantic metrics](filtered-semantic-metrics.md).

## Evidence

- [cohorts_acceptance.py](../../scripts/cohorts_acceptance.py) — Checks definition CRUD, member replacement, pages, selection, erasure and account isolation.
- [Api.hs](../../kansoku-api/src/Kansoku/Cohort/Api.hs) — Declares the served service-token routes and Relay page responses.
