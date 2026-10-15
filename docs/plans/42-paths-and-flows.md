---
id: 42
slug: paths-and-flows
title: "Paths and flows"
kind: exec-plan
created_at: 2026-10-15T15:14:00Z
intention: "intention_01m4zwwdrjesytazp5tb39fe3n"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-15T15:14:00Z
---

# Paths and flows

This ExecPlan is a living document. Update its living sections and durable ADRs as work
proceeds. It is a standalone plan, independent of
`docs/masterplans/5-act-on-rev-1-close-silent-loss-paths-add-metric-filters-and-enrich-web-analytics.md`,
that implements the path analysis the product vision lists as later scope and the
2026-10-15 assessment named as a remaining product-analytics gap.


## Purpose / Big Picture

`GET /metrics/paths` will answer "what do users do after X" and "how do users get to Y":
starting from an event (or ending at one), it returns the most common sequences as weighted
transitions, step by step, with a drop-off node where sequences end. With `by=route` it
becomes a page-flow report over `page_view` events, the "where do visitors go from the
pricing page" view every web-analytics tool offers.


## Progress

- [ ] M1: Start-anchored event paths return per-step transitions with user counts, top-K per step and an `(other)` fold, proven against fixtures.
- [ ] M2: `by=route` page flows with `(end)` nodes and an entry mode when `start` is omitted.
- [ ] M3: End-anchored paths (`end=`) and documentation, OpenAPI, client and the ordering rule recorded in ADR 9.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Paths are computed per user from `analytics.events_resolved` with array
  functions, bounded by `steps` (1 to 10, default 5), `top` (1 to 20 per step, default 10),
  a window of at most 90 days from the anchor, and the global point cap; the first anchor
  occurrence per user is used.
  Rationale: Per-user arrays are the ClickHouse idiom for sequences; the bounds keep the
  answer complete-or-error under ADR 9 instead of streaming an unbounded graph.
  Date: 2026-10-15
- Decision: Transitions are counted in unique users, not occurrences, and a user contributes
  one sequence per query.
  Rationale: Matches PostHog's paths and keeps counts comparable with funnels.
  Date: 2026-10-15


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Funnels already compute per-user ordered behaviour with `windowFunnel` in
`buildFunnelSQLAggregate` (`kansoku-core/src/Kansoku/Metrics/Query.hs`), and
`docs/plans/36-funnel-modes-and-experiment-exposure-diagnostics.md` adds an array-walk engine
(`groupArray` of `(occurred_at, event_name)` per user, sorted) that this plan reuses as its
starting shape. Routes, bounds and the closed ordering rules are in
`kansoku-api/src/Kansoku/Metrics/Api.hs` and
[ADR 9](../adr/0009-bounded-complete-aggregate-responses.md); result points carry `bucket`,
`group` and `value`. The `route` dimension is `path(url)` ([ADR 4](../adr/0004-queryable-event-properties-and-identity-resolved-projection.md)
describes the projection), and filters come from
`docs/plans/31-metric-property-filters-and-dual-grouping.md`. No cross-repository ADR applies.

A "transition" is an ordered pair of consecutive events in one user's sequence at a given
step index. "Top-K fold" means that, per step, only the K most common transitions are
returned and the rest are summed into a single `(other)` target.


## Plan of Work

### M1: Start-anchored event paths

Add `paths` to the metrics route record with `from`, `to`, `start` (event name), `steps`,
`top`, `window` (seconds, max 7,776,000), `events` (optional comma allowlist), `exclude`
(optional comma list), `filter`, and `by` (`event` default). Implement
`buildPathsSQLAggregate`: per user, the sorted array of `(occurred_at, event_name)` within the
range and allowlist; find the first `start`; take the following events within `window` up to
`steps`; emit `(step_index, from, to)` pairs with `arrayZip` and `arrayJoin`; a sequence that
ends before `steps` emits a final pair to `(end)`. Aggregate `uniqExact(canonical_user)` per
triple, keep the top-K per step with `(other)` for the remainder, and order by step then value
descending then names. Points: `group = {step, from, to}`, `value = users`.

### M2: Page flows

With `by=route`, the sequence is `path(url)` of `page_view` events; consecutive identical
routes collapse. When `start` is omitted, sequences begin at each user's first page view in
the range, which gives an entry-page flow; `(end)` marks the last page. Exclude bot-flagged
rows when `is_bot` exists (`docs/plans/33-acquisition-and-device-enrichment-with-bot-flagging.md`).

### M3: End-anchored paths and contract

With `end=` instead of `start=`, reverse the window: take the `steps` events before the last
occurrence of `end` per user within the window. Regenerate OpenAPI and the client, document
the route in `docs/guides/query-metrics.md` ("Paths") with an event example and a page-flow
example, and add the paths ordering to ADR 9's closed list.


## Concrete Steps

```bash
cabal test kansoku-core --test-options='--match "Paths"'
just openapi && just openapi-check
```

Example:

```bash
curl -s --get http://localhost:8080/metrics/paths -H "Authorization: Bearer $TOKEN" \
  --data-urlencode from=2026-07-01 --data-urlencode to=2026-08-01 \
  --data-urlencode start=signup_completed --data-urlencode steps=4 --data-urlencode top=5
```


## Validation and Acceptance

1. M1: a fixture with users following `signup_completed → onboarding_started →
   feature_used` and `signup_completed → (end)` returns two step-1 transitions with the right
   user counts; `top=1` folds the second into `(other)`; `exclude=page_view` removes page views
   from sequences; `steps=11` returns 400.
2. M2: page flows from `/pricing` list `/signup` and `(end)` with correct counts; identical
   consecutive routes collapse.
3. M3: end-anchored paths into `payment_completed` list the preceding steps in reverse order.
4. Point cap, account predicate test and problem codes hold.


## Idempotence and Recovery

New route only; no schema change.


## Interfaces and Dependencies

Hard dependency: `docs/plans/26-bound-analytics-query-inputs-and-result-cardinality.md`
Complete. Soft: `docs/plans/36-funnel-modes-and-experiment-exposure-diagnostics.md` (shared
array helpers), `docs/plans/31-metric-property-filters-and-dual-grouping.md` (filters),
`docs/plans/32-time-aware-identity-bindings-and-bounded-resolution-cost.md` (cost). Claims
`/metrics/paths` and the `(end)` and `(other)` node names.
