---
type: Capability
title: "Web sessions and acquisition"
description: "Compute whole retained web-session counts, bounce, observed duration, contained-event selection and first-touch acquisition and conversion using preserved server enrichment."
timestamp: 2026-11-11T16:18:51Z
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
  - "containsEvent"
  - "conversionEvents"
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
  - kind: conformance
    resource: "scripts/session_contains_acceptance.py"
    proves: "Exercises public contained-event selection over complete retained web sessions."
  - kind: test
    resource: "kansoku-core/test/Kansoku/Metrics/SessionIntegrationSpec.hs"
    proves: "Checks native contained-event session selection and measures."
  - kind: test
    resource: "kansoku-core/test/Kansoku/Ingest/EnrichmentSpec.hs"
    proves: "Checks assistant channel version 2 signals and preserved queued classifications."
---

# Web sessions and acquisition

Classify bounded request user agents and campaign/referrer signals at acceptance. Assemble sessions over all retained web facts before selecting start dates and attributes. Count sessions, bounce fractions and last-minus-first duration; acquisition uses first-page attribution and exact primary-subject users. Optional trusted country lookup stores a country code. Channel enrichment version 2 classifies bounded AI-assistant referrers and exact sources as `ai_assistant`; replay preserves earlier accepted classifications. `client_error` and `web_vital` never count as engagement, regardless of version, while their timestamps still extend observed duration. Migration 0026 corrects all retained session aggregates under maintenance.

## Compatibility

Available in the current checkout. No release tags establish a released version, so since is unreleased. This experimental interface has no stable compatibility promise; pin the server and clients to a reviewed revision and regenerate contracts together.

## Limits

The producer supplies session IDs; the server does not create sessions or add an inactivity timeout. A session key includes account and source service. Any bot event excludes the session by default. Classifiers are deterministic approximations; country lookup is opt-in. Late facts, erasure and retention can change session start and attribution. Contained-event matching sees only web events with session IDs, and arbitrary `prop:` session filters remain unsupported. Upgrade queue consumers before producers for enrichment version 2.

## Requires

- [CAP-6 — Filtered semantic metrics](filtered-semantic-metrics.md).

## Evidence

- [enrichment_acceptance.py](../../scripts/enrichment_acceptance.py) — Exercises request enrichment and acquisition against owned stores.
- [AcquisitionIntegrationSpec.hs](../../kansoku-core/test/Kansoku/Metrics/AcquisitionIntegrationSpec.hs) — Checks native whole-session acquisition semantics.
- [web-enrichment.md](../../docs/guides/web-enrichment.md) — Defines device, bot, channel and optional country rules.
- [session_contains_acceptance.py](../../scripts/session_contains_acceptance.py) — Exercises public contained-event selection over complete retained web sessions.
- [SessionIntegrationSpec.hs](../../kansoku-core/test/Kansoku/Metrics/SessionIntegrationSpec.hs) — Checks native contained-event session selection and measures.
- [EnrichmentSpec.hs](../../kansoku-core/test/Kansoku/Ingest/EnrichmentSpec.hs) — Checks assistant channel version 2 signals and preserved queued classifications.

## Whole-range queries

Explicit `timeGrain=none` returns one null-bucket point per populated group on calendar users, simple custom metrics, acquisition, events, page views and sessions. Exact distinct identities are counted over the whole range; session rates and averages use selected sessions directly. Omission preserves defaults; saved simple grains can be overridden explicitly. See [query metrics](../guides/query-metrics.md#whole-range-totals) for the route matrix and empty-result semantics.

## Sessions containing an event

`containsEvent` on `/metrics/sessions` selects whole sessions with at least one retained web event among 1..20 named events (any-of) for count, bounce and duration. Matching uses complete retained session history, so a witness after `to` can select a session that started in range; dates and buckets still follow the session start. Comparing selected and unselected counts reports, for example, the share of visits with a client error; the two requests are not an atomic snapshot. See [query metrics](../guides/query-metrics.md#sessions-containing-an-event).

## Acquisition conversions

On `/metrics/acquisition`, `converted_users` and `conversion_rate` take `conversionEvents` (1..20 names, OR) and assign each resolved person to their first selected session in the range after session filters, traits, cohorts and bot exclusion. Conversions from any source or service count when they occur in `[from,to)` at or after that session start, in that session's bucket. First touch means first selected session in the range, not lifetime first visit; use `timeGrain=none` rather than summing rates. See [query metrics](../guides/query-metrics.md#acquisition-conversions).
