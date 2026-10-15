---
id: 36
slug: funnel-modes-and-experiment-exposure-diagnostics
title: "Funnel modes and experiment exposure diagnostics"
kind: exec-plan
created_at: 2026-10-15T13:44:34Z
intention: "intention_01m4zwwdrjesytazp5tb39fe3n"
master_plan: "docs/masterplans/5-act-on-rev-1-close-silent-loss-paths-add-metric-filters-and-enrich-web-analytics.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-15T13:44:34Z
---

# Funnel modes and experiment exposure diagnostics

This ExecPlan is a living document. Update its living sections and durable ADRs as work
proceeds. It is a child of
`docs/masterplans/5-act-on-rev-1-close-silent-loss-paths-add-metric-filters-and-enrich-web-analytics.md`
and acts on findings E1 and E5 of
`docs/reviews/2026-10-15-architecture-and-feature-set-against-comparable-products.md`.


## Purpose / Big Picture

Funnels will support the two modes products default to besides sequential: strict order,
where no other event may intervene, and exclusion events that remove a user who did something
disqualifying between two steps. They will report time to convert, and they will break down
by a declared property attributed to the user's first step. Experiment consumers will see how
many users were exposed to more than one variant and each variant's share of exposures, so a
sample-ratio check can be run outside Kansoku.


## Progress

- [ ] M1: `mode=strict` on `/metrics/funnel` and `/metrics/experiments/funnel` proven against fixtures where an intervening event changes the answer.
- [ ] M2: `exclude=` and `measure=time_to_convert` via an array-walk funnel engine that agrees with the `windowFunnel` path on every existing fixture.
- [ ] M3: `groupBy=prop:<name>` on funnels with first-step attribution.
- [ ] M4: `/metrics/experiments` returns `multiple_exposure` and `variant_share` points per experiment, documented with a sample-ratio recipe.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Keep `windowFunnel` for the default sequential path and add an array-walk engine
  only for exclusions and time to convert; both must agree on the shared fixtures.
  Rationale: `windowFunnel` returns only the reached level, not step times, so exclusions and
  durations need per-user ordered arrays; running both lets the cheaper path stay default.
  Date: 2026-10-15
- Decision: Funnel breakdown attributes the property value from the user's first step-one
  event (first touch) and reports `other` for users without the property.
  Rationale: First touch is PostHog's schema default and Mixpanel's "first step defined";
  per-step attribution is deferred.
  Date: 2026-10-15


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

`buildFunnelSQLAggregate` in `kansoku-core/src/Kansoku/Metrics/Query.hs` runs one
`windowFunnel(window)(toDateTime(occurred_at), cond_1, …)` per user over
`analytics.events_resolved`, then counts users at each level; equal timestamps may satisfy
consecutive steps and repeated step names mean repeated events. The experiment funnel applies
the same engine after each user's first exposure
([ADR 6](../adr/0006-exposure-based-experiment-analytics.md)). ClickHouse's `windowFunnel`
accepts the modes `strict_order` (no intervening events), `strict_deduplication` and
`strict_increase`. Exposure counts come from `analytics.experiment_exposures`
(`db/clickhouse/migrations/0014_experiment_exposures.sql`), a daily `uniqCombined` rollup per
account, experiment and variant over raw identity. Bounds (20 steps, 90-day window) are from
`docs/plans/26-bound-analytics-query-inputs-and-result-cardinality.md` and
[ADR 9](../adr/0009-bounded-complete-aggregate-responses.md). Property compilation follows
[ADR 4](../adr/0004-queryable-event-properties-and-identity-resolved-projection.md). No
cross-repository ADR applies.


## Plan of Work

### M1: Strict mode

Add `mode` (`sequential` default, `strict`) to both funnel routes; `strict` passes
`'strict_order'` and `'strict_deduplication'` to `windowFunnel`. Document that strict order
counts any other event by the same user, including automatic ones such as `page_view`, as an
interruption, and point to `exclude=` for the narrower rule.

### M2: Exclusions and time to convert

Implement `buildFunnelArraySQL`: per user, `groupArray` of `(occurred_at, event_name)` for
step and excluded events within the range, `arraySort` by time, and an `arrayFold` or
`arrayReduce` lambda that walks the chain honouring the window, recording the reach time of
each step, and aborting when an excluded event falls between the current step time and the
next matched step. Use it whenever `exclude=` or `measure=time_to_convert` is present.
`measure=time_to_convert` returns, per step index ≥ 2, the median and 90th percentile seconds
from step one, computed with `quantiles(0.5, 0.9)`. Add a property test over random event
sequences asserting that without exclusions the array engine's levels equal `windowFunnel`'s.

### M3: Breakdown

Accept `groupBy=prop:<name>` on `/metrics/funnel`, requiring every step event to declare the
property (ADR 4 rule), attributing the value from the first step-one event per user, and
emitting one point per (step, value) under the point cap.

### M4: Exposure diagnostics

In `buildExperimentExposuresSQL`, add two unbucketed points per experiment:
`multiple_exposure` (exact `uniqExact` of users with more than one variant over the range,
from `events_raw`) and `variant_share` per variant (users over total exposed). Document a
chi-square sample-ratio check in `docs/guides/query-metrics.md` and note that users in
`multiple_exposure` are still counted in each variant, as ADR 6 states.


## Concrete Steps

```bash
cabal test kansoku-core --test-options='--match "Funnel"'
cabal test kansoku-core --test-options='--match "Experiments"'
just openapi && just openapi-check
```

Example:

```bash
curl -s --get http://localhost:8080/metrics/funnel -H "Authorization: Bearer $TOKEN" \
  --data-urlencode from=2026-07-01 --data-urlencode to=2026-08-01 \
  --data-urlencode steps=signup_started,signup_completed --data-urlencode exclude=support_ticket_opened \
  --data-urlencode measure=time_to_convert
```


## Validation and Acceptance

1. M1: a user with `signup_started`, `page_view`, `signup_completed` reaches step 2 in
   sequential mode and step 1 in strict mode.
2. M2: a user with an excluded event between steps is removed from step 2; without
   exclusions the array engine equals `windowFunnel` on all funnel fixtures and on 1,000
   random sequences; time to convert for a two-event fixture equals their difference.
3. M3: breakdown by `plan` over two users on different plans yields two groups; a user
   without the property lands in `other`.
4. M4: a fixture with one user exposed to A and B reports `multiple_exposure = 1`, and
   variant shares sum to 1 within rounding; existing exposure counts are unchanged.


## Idempotence and Recovery

Additive parameters; defaults preserve current behaviour. No schema change. If the array
engine proves slow, the plan's Decision Log records limiting it to requests that need it,
which is already the design.


## Interfaces and Dependencies

Hard dependency: `docs/plans/26-bound-analytics-query-inputs-and-result-cardinality.md`
Complete. Soft dependency: `docs/plans/31-metric-property-filters-and-dual-grouping.md`
(property compile helpers reused for M3). Update ADR 6 with the diagnostics and the mode
vocabulary.
