---
okf_version: "0.2"
---

# Kansoku capabilities

What Kansoku provides in the current checkout, with evidence a reader can inspect. Status shipped means implemented here; every capability remains experimental and unreleased. Evidence entries identify existing tests and contracts; adoption does not attest a fresh run of the full service acceptance suite.

The shared [profile](profile.dhall) is pinned to [coordination.capabilities](mori://shinzui/okf-profiles/profiles/capabilities) v0.20.0. Stable CAP handles are bundle scoped; for example, `mori://shinzui/kansoku/okf/capabilities/concepts/CAP-1`. Agent-authored records have no independent review or verification attestation.

See the [terminology](../terminology/index.md) for vocabulary, the [guides](../README.md) for usage, and the [adoption log](log.md) for changes. Validate with `just capabilities-check`.

## Ingestion and contracts

| ID | Capability | Description |
| --- | --- | --- |
| CAP-1 | [Account-scoped credentials](account-scoped-credentials.md) | Authenticate producers and analytics consumers with revocable write keys and service tokens scoped to one account. |
| CAP-2 | [Immutable event ingestion](immutable-event-ingestion.md) | Accept single events, partial batches and browser exit beacons with durable event identity and explicit retry outcomes. |
| CAP-3 | [Versioned event contracts](versioned-event-contracts.md) | Publish governed event schemas and OpenAPI from the same typed contracts used by the running service. |
| CAP-4 | [Durable delivery and recovery](durable-delivery-recovery.md) | Drain a durable PostgreSQL queue into replay-safe ClickHouse facts with supervised batching and bounded storage-outage recovery. |

## Identity and traits

| ID | Capability | Description |
| --- | --- | --- |
| CAP-5 | [Conservative identity resolution](conservative-identity-resolution.md) | Resolve analytical subjects from explicit users and account-scoped identifier evidence without choosing arbitrary users for ambiguous signals. |
| CAP-12 | [Governed current person traits](current-person-traits.md) | Set or initialize declared person traits and segment supported metrics by the resolved user’s current values. |

## Analytics and segmentation

| ID | Capability | Description |
| --- | --- | --- |
| CAP-6 | [Filtered semantic metrics](filtered-semantic-metrics.md) | Query event, page-view, feature-adoption and revenue aggregates through typed dimensions and bounded parameterized filters. |
| CAP-7 | [Web sessions and acquisition](web-sessions-acquisition.md) | Compute whole retained web-session counts, bounce, observed duration and first-touch acquisition using preserved server enrichment. |
| CAP-8 | [Activity and retention analytics](activity-retention.md) | Compute exact active users, stickiness, lifecycle and retention over consistent resolved populations and closed UTC observation days. |
| CAP-9 | [Deterministic funnels and conversion](deterministic-funnels.md) | Measure exact funnel reach, attempts and conversion timing with sequential, strict and any-order event matching. |
| CAP-10 | [Event paths and page flows](paths-flows.md) | Explore forward or reverse canonical-user transitions from event or route anchors with bounded top-K folding. |
| CAP-11 | [Exposure-based experiment analytics](experiment-analytics.md) | Compare variant exposures, post-exposure conversion and funnels while exposing contamination and exclusive first-observed assignment diagnostics. |
| CAP-13 | [Saved behavioural and static cohorts](saved-cohorts.md) | Manage account-scoped user segments and select metric populations using query-time behaviour or uploaded membership. |
| CAP-14 | [Custom and saved metric definitions](custom-metric-definitions.md) | Compute ad-hoc counts, unique users, numeric sums, averages and ratios, or save typed account-scoped definitions for reuse. |
| CAP-15 | [Organisation analytics and current membership](organization-analytics.md) | Count organisations, combine member activity in supported metrics and segment by current organisation traits. |

## Operations

| ID | Capability | Description |
| --- | --- | --- |
| CAP-16 | [Resumable administration and data lifecycle](administrative-lifecycle.md) | Preview and confirm fenced erasure, retention and archive maintenance with durable job status and safe resumption. |
| CAP-17 | [Operational probes and telemetry](operational-observability.md) | Expose dependency-aware readiness, liveness, pipeline metrics and bounded correlated request telemetry for operating the service. |

## Clients and consumption

| ID | Capability | Description |
| --- | --- | --- |
| CAP-18 | [Haskell producer SDK and typed clients](haskell-producer-clients.md) | Buffer and retry producer events in Haskell and call ingestion, schema, metric and resource routes through shared typed clients. |
| CAP-19 | [Trusted SQL analytics consumption](trusted-sql-consumption.md) | Expose constrained ClickHouse reader projections and executable recipes for trusted dashboard and experiment consumers. |
