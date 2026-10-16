---
type: Capability
title: "Web sessions and acquisition"
description: "Compute whole retained web-session counts, bounce, observed duration and first-touch acquisition using preserved server enrichment."
generated:
  by: process:codex
  at: "2026-10-16T13:11:11Z"
capabilityId: CAP-7
provider: mori://shinzui/kansoku
status: shipped
stability: experimental
since: unreleased
packages:
  - "kansoku-core"
interface:
  - "GET /metrics/sessions"
  - "GET /metrics/acquisition"
  - "web enrichment dimensions"
tags: [analytics]
requires:
  - CAP-6
evidence:
  - kind: conformance
    resource: "scripts/enrichment_acceptance.py"
    proves: "Exercises request enrichment and acquisition against owned stores."
  - kind: test
    resource: "kansoku-core/test/Kansoku/Metrics/AcquisitionIntegrationSpec.hs"
    proves: "Checks native whole-session acquisition semantics."
  - kind: guide
    resource: "docs/guides/web-enrichment.md"
    proves: "Defines device, bot, channel and optional country rules."
---

# Web sessions and acquisition

Classify bounded request user agents and campaign/referrer signals at acceptance. Assemble sessions over all retained web facts before selecting start dates and attributes. Count sessions, bounce fractions and last-minus-first duration; acquisition uses first-page attribution and exact primary-subject users. Optional trusted country lookup stores a country code.

## Compatibility

Available in the current checkout. No release tags establish a released version, so since is unreleased. This experimental interface has no stable compatibility promise; pin the server and clients to a reviewed revision and regenerate contracts together.

## Limits

The producer supplies session IDs; the server does not create sessions or add an inactivity timeout. A session key includes account and source service. Any bot event excludes the session by default. Classifiers are deterministic approximations; country lookup is opt-in. Late facts, erasure and retention can change session start and attribution.

## Requires

- [CAP-6 — Filtered semantic metrics](filtered-semantic-metrics.md).

## Evidence

- [enrichment_acceptance.py](../../scripts/enrichment_acceptance.py) — Exercises request enrichment and acquisition against owned stores.
- [AcquisitionIntegrationSpec.hs](../../kansoku-core/test/Kansoku/Metrics/AcquisitionIntegrationSpec.hs) — Checks native whole-session acquisition semantics.
- [web-enrichment.md](../../docs/guides/web-enrichment.md) — Defines device, bot, channel and optional country rules.
