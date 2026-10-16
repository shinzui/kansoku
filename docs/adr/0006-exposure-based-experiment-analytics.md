---
type: Architecture Decision Record
title: Exposure-based experiment analytics
description: Define exposure-based experiment analytics using an approximate daily rollup for exposure counts and exact query-time resolution for conversion and funnels.
timestamp: 2026-10-16T12:10:14Z
generated:
  by: human:kansoku-maintainers
  at: 2026-07-19T00:00:00Z
docId: ADR-6
status: Accepted
date: 2026-07-19
---

# ADR 0006: Exposure-based experiment analytics

- Deciders: Kansoku maintainers

## Context

Product experiments need stable answers to three related questions: how many users saw
each variant, how many converted afterward, and how far exposed users progressed through
an ordered funnel. Treating assignment as exposure, counting conversions that predate an
exposure, or silently applying different identity semantics to these answers would make
the resulting comparison misleading.

ADR 0003 requires authenticated account scoping for analytics. ADR 0004 makes native JSON
properties and the ordered `analytics.events_resolved` projection shared query contracts.
ADR 0005 defines query-time canonical identity resolution. Experiment analytics must
compose those boundaries without freezing identity bindings into insert-time rollups.

## Decision

The canonical experiment event is `experiment_viewed`, emitted when a user is actually
shown a variant. Its required string properties `experiment` and `variant` use the same
non-empty, 128-character `[a-z0-9_.:-]` name rule as metric SQL inputs. Assignment that is
never rendered is not an exposure event.

The high-frequency exposure endpoint reads an account-scoped daily
`AggregatingMergeTree` rollup keyed by experiment and variant. It stores
`uniqCombined` states over raw identity (`user_id`, otherwise `anonymous_id`). Merging
daily states unions users, so re-exposure and at-least-once replay do not double-count.
This endpoint documents its approximate and pre-stitch identity semantics.

Conversion and funnel endpoints read `analytics.events_resolved` at query time and count
exact canonical users. Conversion requires a conversion event at or after the user's
first exposure to that variant. The experiment funnel similarly ignores step events
before first exposure and then applies [ADR-15](0015-deterministic-selected-funnel-chains-and-exclusive-exposure-diagnostics.md)'s
deterministic selected-chain semantics over millisecond time and event IDs. One physical event
cannot satisfy repeated steps. A user exposed to multiple variants
counts in every variant observed; all funnel modes, attempt resets and attribution use only
the exposure-gated timeline under ADR-15; cross-variant exposure is retained as a data-quality
signal rather than silently reassigned.

All endpoints inherit service-token authentication and bind account and validated names
as native ClickHouse parameters. Stored experiment and variant values are guarded by the
same anchored name pattern before they become composite group keys. A syntactically valid
experiment with no data returns HTTP 200 with an empty point list for exposure counts and
conversion; diagnostics instead emit zero totals without variant rows.

The API returns exposure counts, conversion counts and rates, funnel counts/timing with sequential, strict or any_order mode, uniques or totals counting,
and first_touch, last_touch or step:n property attribution,
and exact contamination and exclusive first-observed assignment diagnostics under ADR-15.
It does not calculate statistical significance, confidence intervals, sample-size
adequacy, or winner recommendations.

## Alternatives considered

- Assignment-based denominators were rejected because users who never saw a treatment
  could not have been affected by it and would dilute the observed effect.
- Using the raw exposure rollup for conversion and funnel answers was rejected because it
  cannot apply ADR 0005's query-time identity stitching or event ordering.
- Joining identity bindings inside the exposure materialized view was rejected because it
  would freeze stale resolutions and scale insert work with identity state.
- Counting any conversion inside the requested range was rejected because pre-exposure
  outcomes cannot be attributed to a variant.
- Embedding significance tests was rejected because test choice, multiple-comparison and
  peeking policy, and minimum detectable effect belong to a deliberate statistics layer.

## Consequences

Exposure dashboards are inexpensive and replay-tolerant, but may count an anonymous user
again after identification and are approximate at high cardinality. Conversion and funnel
answers are exact under current identity policy but cost query-time resolution and joins.
Consumers must not compare the rollup's raw-identity exposure number directly with an
exact stitched denominator without acknowledging that distinction.

Producers must emit `experiment_viewed` at render time with contract-conforming names.
Experiment, variant and step names retain their bounded name grammar. Native metadata groups
are JSON arrays decoded to nullable text maps, never delimiter-split strings; typed experiment,
variant, measure and numeric-step columns determine ordering. Full prop: dimension names remain distinct from reserved metadata keys; user: is reserved
for the later trait-dimension contract. Unsupported filter/group parameters are explicit
400 errors until their route contract supports the corresponding population. Future
significance reporting must build on these counts and explicitly document its statistical
policy rather than changing the meaning of the existing endpoints.
