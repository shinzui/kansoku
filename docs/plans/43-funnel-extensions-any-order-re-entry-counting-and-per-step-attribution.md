---
id: 43
slug: funnel-extensions-any-order-re-entry-counting-and-per-step-attribution
title: "Funnel extensions: any-order, re-entry counting, and per-step attribution"
kind: exec-plan
created_at: 2026-10-15T15:14:00Z
intention: "intention_01m4zwwdrjesytazp5tb39fe3n"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-15T15:14:00Z
---

# Funnel extensions: any-order, re-entry counting, and per-step attribution

This ExecPlan is a living document. Update its living sections and durable ADRs as work
proceeds. It is a standalone plan, independent of
`docs/masterplans/5-act-on-rev-1-close-silent-loss-paths-add-metric-filters-and-enrich-web-analytics.md`,
that completes the funnel semantics
`docs/reviews/2026-10-15-architecture-and-feature-set-against-comparable-products.md`
(finding E1) listed as differentiators of PostHog, Mixpanel and Amplitude.


## Purpose / Big Picture

Funnels will answer three more questions. Any-order: "did the user do all of these, in
whatever sequence", for checklists and onboarding tasks. Re-entry counting: "how many times
was this funnel attempted, not how many users attempted it", for repeat flows such as checkout.
Per-step attribution: "break the funnel down by the plan chosen at step three, not at step
one", so a breakdown property can come from the step where it is set.


## Progress

- [ ] M1: `mode=any_order` counts users who completed any subset of steps within the window from their earliest step, proven against fixtures where order differs from sequential.
- [ ] M2: `counting=totals` counts funnel entries, re-entering after completion or window expiry, with uniques unchanged.
- [ ] M3: `attribution=first_touch|last_touch|step:<n>` for `groupBy=prop:` on funnels, with `other` for users lacking the value.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: All three features run on the array-walk engine from EP-36, never on
  `windowFunnel`, and the sequential-uniques default keeps using `windowFunnel`.
  Rationale: `windowFunnel` cannot express re-entry or any-order levels with step times; the
  array engine already carries per-step timestamps and exclusions.
  Date: 2026-10-15
- Decision: Any-order levels count distinct steps completed within the window that opens at
  the user's earliest step event; a user reaching level N has done N distinct steps.
  Rationale: Amplitude's "Any order" and PostHog's "any order" both define completion as all
  steps within the window; reporting intermediate levels keeps the point shape identical.
  Date: 2026-10-15


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

`docs/plans/36-funnel-modes-and-experiment-exposure-diagnostics.md` adds `mode=strict`,
`exclude=`, `measure=time_to_convert` and a first-touch breakdown, introducing
`buildFunnelArraySQL` in `kansoku-core/src/Kansoku/Metrics/Query.hs`: per user, a sorted
`groupArray` of `(occurred_at, event_name)` walked by a lambda that records each step's reach
time. This plan extends that lambda and its parameters. Funnel routes and bounds (20 steps,
90-day window) are in `kansoku-api/src/Kansoku/Metrics/Api.hs` and
[ADR 9](../adr/0009-bounded-complete-aggregate-responses.md); experiment funnels apply the same
engine after first exposure ([ADR 6](../adr/0006-exposure-based-experiment-analytics.md)). Property
compilation follows [ADR 4](../adr/0004-queryable-event-properties-and-identity-resolved-projection.md).
No cross-repository ADR applies.


## Plan of Work

### M1: Any order

Add `mode=any_order`. In the array walk, open the window at the first event matching any
step, collect the set of distinct steps seen until the window closes, and report
`level = size of the set`; exclusions still abort. Apply to `/metrics/funnel` and
`/metrics/experiments/funnel`.

### M2: Totals

Add `counting=uniques|totals` (default `uniques`). Under `totals`, after a chain completes the
last step or its window expires, the walk resumes from the next step-one event and starts a
new chain; each chain contributes to the per-step counts, so `value` becomes chains rather
than users. Report `entries` as an extra unbucketed point so consumers can compute per-user
attempt rates. Mixpanel's 2-second grace for exclusions is not adopted; document it.

### M3: Attribution

Add `attribution=first_touch|last_touch|step:<n>` (default `first_touch`) for
`groupBy=prop:<name>` on funnels: take the property value from the user's first step-one
event, from the last matched step event, or from the event matching step `n`; `other` when
absent. Regenerate OpenAPI and the client, document all three features in the query guide,
and extend ADR 6's mode vocabulary.


## Concrete Steps

```bash
cabal test kansoku-core --test-options='--match "Funnel"'
just openapi && just openapi-check
```


## Validation and Acceptance

1. M1: a user with `b, a` within the window reaches level 2 in any-order mode and level 1 in
   sequential mode; the same with `b` outside the window reaches 1.
2. M2: a user who completes the funnel twice counts twice at every step under `totals`, once
   under `uniques`; `entries` equals 2.
3. M3: with `plan` set at step three, `attribution=step:3` groups by that value while
   `first_touch` yields `other`; the random-sequence property test from EP-36 still holds for
   the sequential-uniques path.
4. Bounds and codes from EP-26 apply; the experiment funnel honours all three parameters.


## Idempotence and Recovery

Additive parameters; defaults unchanged.


## Interfaces and Dependencies

Hard dependencies: `docs/plans/26-bound-analytics-query-inputs-and-result-cardinality.md`
and `docs/plans/36-funnel-modes-and-experiment-exposure-diagnostics.md` Complete. Soft:
`docs/plans/31-metric-property-filters-and-dual-grouping.md`. Claims the `counting` and
`attribution` parameters and the `any_order` mode value.
