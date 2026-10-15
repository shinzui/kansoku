---
id: 35
slug: rolling-active-users-retention-modes-and-lifetime-cohorts
title: "Rolling active users, retention modes, and lifetime cohorts"
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

# Rolling active users, retention modes, and lifetime cohorts

This ExecPlan is a living document. Update its living sections and durable ADRs as work
proceeds. It is a child of
`docs/masterplans/5-act-on-rev-1-close-silent-loss-paths-add-metric-filters-and-enrich-web-analytics.md`
and acts on findings E2 and E3 of
`docs/reviews/2026-10-15-architecture-and-feature-set-against-comparable-products.md`.


## Purpose / Big Picture

A reader of `/metrics/users` will get the number every other analytics product calls WAU or
MAU: users active in the trailing seven or thirty days, evaluated per bucket, alongside the
existing calendar counts, and a stickiness ratio derived from them. Retention will offer the
cumulative "on or after" reading and cohorts by lifetime first activity, and a lifecycle
breakdown will say how many of a day's users are new, returning, resurrecting or dormant.


## Progress

- [ ] M1: `/metrics/users?window=rolling7|rolling30` and `/metrics/stickiness` return exact identity-resolved counts proven against fixtures; calendar semantics are stated in the guide and OpenAPI.
- [ ] M2: `/metrics/retention` accepts `mode=on|on_or_after` and `cohort=window|lifetime`; lifetime cohorts use first activity across the account's history.
- [ ] M3: `/metrics/lifecycle` classifies users per day as new, returning, resurrecting or dormant with counts that reconcile to the daily active count.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Rolling windows and lifetime cohorts are computed at query time over
  `analytics.events_resolved`, bounded by EP-26's 366-day range plus the window length, and
  not from new rollups.
  Rationale: Exactness requires stitched identity, which rollups cannot carry (ADR 6); the
  cost is bounded by `docs/plans/32-…`'s resolution work. A `first_seen` rollup over raw
  identity would be approximate and is deferred until the exact path proves too slow.
  Date: 2026-10-15
- Decision: Lifecycle definitions follow PostHog and Amplitude: new is first activity ever on
  that day, returning is active on the day and on the previous day, resurrecting is active on
  the day after at least one inactive day since first activity, dormant is active on the
  previous day and not on the day (reported as a negative count, as both products do).
  Rationale: Matching the published definitions makes the numbers comparable.
  Date: 2026-10-15


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

`/metrics/users` reads the `dau` and `wau` rollups at day and week grain (`uniqCombined`
sketches over raw identity, about 0.8 percent error) and `events_resolved` with `uniqExact`
at other grains; `toMonday` defines the week (`db/clickhouse/migrations/0006_rollups_v2.sql`,
`kansoku-core/src/Kansoku/Metrics/Query.hs`). Retention (`buildRetentionSQLAggregate`) defines
the cohort as first activity inside the requested range and counts a user at offset N only when
active exactly N days later. The guide `docs/guides/query-metrics.md` and the route description
in `kansoku-api/src/Kansoku/Metrics/Api.hs` state these semantics. Bounds and stable error codes
come from `docs/plans/26-bound-analytics-query-inputs-and-result-cardinality.md` and
[ADR 9](../adr/0009-bounded-complete-aggregate-responses.md); the accuracy map lives in
[ADR 6](../adr/0006-exposure-based-experiment-analytics.md). No cross-repository ADR applies.


## Plan of Work

### M1: Rolling windows and stickiness

Add `window` to the users route with values `calendar` (default) and `rolling7`, `rolling30`.
For rolling windows the builder selects per bucket day `d` the `uniqExact(canonical_user)`
over events in `(d - window + 1 day, d]`, reading `events_resolved` with the range extended
backwards by the window; `timeGrain` must be `day` for rolling windows, otherwise 400. Add
`/metrics/stickiness` returning, per day, rolling1 divided by rolling30 as `value` with the
two counts in `group`. State in the guide and route descriptions that `timeGrain=week` is a
calendar week starting Monday and `month` a calendar month.

### M2: Retention modes and lifetime cohorts

Add `mode` (`on` default, `on_or_after`) and `cohort` (`window` default, `lifetime`). For
`on_or_after`, a user counts at offset N when active at any offset ≥ N up to the largest
requested offset; implement as a running maximum over the per-user activity offsets. For
`lifetime`, `first_seen` is `min(toDate(occurred_at))` over the account's entire history, and
the cohort rows are those whose first day falls inside the requested range. Document the
scan cost and point to EP-32.

### M3: Lifecycle

Add `/metrics/lifecycle` over `events_resolved`: per day, compute each user's first day ever
and their activity on the day and the previous day, classify per the Decision Log, and return
four points per day with `group.status`. Verify that new plus returning plus resurrecting
equals the exact daily active count.


## Concrete Steps

```bash
cabal test kansoku-core --test-options='--match "Users"'
cabal test kansoku-core --test-options='--match "Retention"'
cabal test kansoku-core --test-options='--match "Lifecycle"'
just openapi && just openapi-check
```

Example:

```bash
curl -s --get http://localhost:8080/metrics/users -H "Authorization: Bearer $TOKEN" \
  --data-urlencode from=2026-07-01 --data-urlencode to=2026-07-08 --data-urlencode window=rolling7
```


## Validation and Acceptance

1. Fixture with users active on days 1, 3 and 9: rolling7 on day 7 is 2, on day 9 is 3 if
   they are distinct users, calendar week counts match the existing rollup; stickiness on a
   day equals rolling1 over rolling30.
2. Retention `on_or_after` with offsets 1,7: a user active on day 5 only counts at offset 1;
   `cohort=lifetime` excludes a user whose first activity precedes the range.
3. Lifecycle sums reconcile to the daily exact active users for every fixture day; dormant
   is reported as a negative value.
4. Bounds: a rolling30 query over 366 days reads at most 396 days and still obeys the point
   cap; EP-26's problem codes apply.


## Idempotence and Recovery

Additive parameters and one new route; defaults preserve existing answers. No schema change.


## Interfaces and Dependencies

Hard dependency: `docs/plans/26-bound-analytics-query-inputs-and-result-cardinality.md`
Complete. Soft dependency: `docs/plans/32-time-aware-identity-bindings-and-bounded-resolution-cost.md`
for acceptable cost on large accounts and
`docs/plans/31-metric-property-filters-and-dual-grouping.md` for filters on the new routes.
Update ADR 6's accuracy map with the rolling and lifecycle semantics.
