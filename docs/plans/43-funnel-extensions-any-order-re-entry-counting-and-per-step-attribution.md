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
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-16T11:50:40Z
      mode: "implement"
      note: "Implement any-order windows, nonoverlapping entries and property attribution on the deterministic evaluator."
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

- [x] M1 (2026-10-16): `mode=any_order` reports distinct-position reach within the earliest matching window on both routes. Native reversed-order and millisecond expiry fixtures pass, with 2000 seeded any-order comparisons.
- [x] M2 (2026-10-16): `counting=totals` reports nonoverlapping entries and preserves uniques. Native repeated-completion/expiry/exclusion, per-attempt timing, replay, empty-population and point-limit checks pass; 2000 seeded ordered-totals comparisons pass.
- [x] M3 (2026-10-16): Both routes support first/last/requested-step property attribution, including missing/unreached `other`, any-order named positions and per-attempt ownership. Native fixtures, regenerated OpenAPI/client compilation and packaged public producer acceptance pass; guide and ADR-4/6/15 are updated.

The final focused native run passes 25 examples with no pending cases, including attribution,
numeric ordering, literal/missing `other` merging and 6000 total reference/native comparisons.
`nix develop -c just check` passes 375 core examples, 20 client examples, four probes,
generated contract checks, strict ADR validation and all telemetry lifecycle modes.
`nix develop -c just acceptance` passes 447 core examples, 21 live-client examples, native
recovery/limits/replay/identity, Hurl, administration, and public workflows in all three
telemetry modes. The expanded funnel producer workflow passes in each mode. Evidence is
retained under `.dev/acceptance/identity-validation/ep43-{native,check,acceptance}.log`;
packaged sanitized evidence is in `.dev/acceptance/run-d7f60rwf/sanitized/`.


## Surprises & Discoveries

EP-36 is complete, but its final implementation differs from this plan's original
premise: `kansoku-core/src/Kansoku/Metrics/Query/Funnel.hs` and ADR-15 own a deterministic
array evaluator for every funnel, including sequential uniques. Native `windowFunnel`
was rejected for repeated step names and timestamp ties. Preserve this established path.
Route wiring lives in `kansoku-core/src/Kansoku/Metrics/Handler.hs`, parameter allowlists
in `kansoku-core/src/Kansoku/Metrics/RequestValidation.hs`, and scalar property validation
in `kansoku-core/src/Kansoku/Metrics/Query/Property.hs`.


## Decision Log

- Decision: Extend the deterministic native array engine for all features, preserving
  EP-36's selected-chain path for sequential/strict uniques.
  Rationale: ADR-15 and the completed EP-36 native counterexamples rule out `windowFunnel`
  even for the default; the original plan's fallback premise was stale.
  Date: 2026-10-16
- Decision: Any-order levels count distinct steps completed within the window that opens at
  the user's earliest step event; a user reaching level N has done N distinct steps.
  Rationale: Amplitude's "Any order" and PostHog's "any order" both define completion as all
  steps within the window; reporting intermediate levels keeps the point shape identical.
  Date: 2026-10-15
- Decision: Totals uses nonoverlapping attempts, and any-order attribution names requested
  positions independently of chronological reach ranks. Entries points are ungrouped per
  variant, include partial attempts, and count toward the final response limit.
  Rationale: Avoid sharing events across attempts, preserve cumulative reach, and keep
  property ownership and the denominator explicit. Missing and literal `other` strings
  merge into one breakdown; numeric/boolean sort types remain intact.
  Date: 2026-10-16


## Outcomes & Retrospective

Complete on 2026-10-16. Both ordinary and experiment funnels expose all three controls,
with deterministic chronological reach, nonoverlapping totals, explicit entries points,
and property attribution that does not drop partial participants. Sequential/strict
uniques retains its existing selected-chain counts and timing. The implementation adds
no persistence or migration and retains account isolation, native work budgets and the
complete 10000-point response limit.

The stale windowFunnel premise was corrected against completed EP-36 and native evidence.
One reference evaluator and equivalent compiler-owned fold cover extended paths; native
comparison of complete event IDs and millisecond durations caught an accumulator tuple
error before public acceptance. Typed sort values must survive missing-label rendering
and the entries union; native numeric and literal/missing-other fixtures verify both.
Durable contracts are distilled into [ADR-15](../adr/0015-deterministic-selected-funnel-chains-and-exclusive-exposure-diagnostics.md),
with the funnel property exception in [ADR-4](../adr/0004-queryable-event-properties-and-identity-resolved-projection.md)
and exposure vocabulary in [ADR-6](../adr/0006-exposure-based-experiment-analytics.md).
All required acceptance gates pass; no work remains in this plan.


## Context and Orientation

`docs/plans/36-funnel-modes-and-experiment-exposure-diagnostics.md` adds `mode=strict`,
`exclude=`, `measure=time_to_convert` and a first-touch breakdown. Its completed evaluator
is `evaluateFunnel`/`selectedChainSQL` in `kansoku-core/src/Kansoku/Metrics/Query/Funnel.hs`,
called by `compileFunnel`/`funnelAggregate` in `kansoku-core/src/Kansoku/Metrics/Query.hs`.
Each canonical user's immutable events are ordered by stored milliseconds and event ID;
one physical event satisfies at most one step. [ADR-15](../adr/0015-deterministic-selected-funnel-chains-and-exclusive-exposure-diagnostics.md)
selects greatest reach, earliest completion, earliest start and event IDs for ordered
uniques. This plan retains that contract and adds an entry evaluator for any-order/totals.
Funnel routes and bounds (20 steps,
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
last step or its window expires, the walk resumes from the next eligible start and starts a
new chain; each chain contributes to the per-step counts, so `value` becomes chains rather
than users. Strict interruptions and exclusions close an attempt while preserving its
reached prefix. The closing event can itself start the next eligible attempt.
Sequential/strict starts require step one; any-order starts permit any requested step.
Completion consumes its event. Repeated names require separate events and occupy distinct
requested positions. Report `measure=entries` as an extra unbucketed point per variant,
with null index/step and breakdown labels; totals count rows use `measure=count`. Include
partial attempts and apply the final point limit after adding entries.
Mixpanel's 2-second grace for exclusions is not adopted; document it.

### M3: Attribution

Add `attribution=first_touch|last_touch|step:<n>` (default `first_touch`) for
`groupBy=prop:<name>` on funnels: take the property value from the user's earliest eligible
start (per attempt for totals), from the last matched step event, or from the event matching
requested step position `n`; `other` when absent or unreached. Any-order positions retain
their requested identities even when chronological reach rank differs. Other dimensions
keep start ownership. Preserve nullable typed sort columns; only labels render missing as
`other`. Validate `step:n` against that step's schema; varying touches use compatible
declarations among the finite step scope, retaining first-step validation when first touch
is fixed. Regenerate OpenAPI and the client, document all three features in the query guide,
and extend ADR 6's mode vocabulary.


## Concrete Steps

Run from the repository root inside `nix develop`. Use an owned temporary ClickHouse
instance, apply migrations, and require nonzero executed tests with no pending cases:

```bash
cabal build all --enable-tests
python3 - <<'PY'
import sys
sys.path.insert(0, 'scripts')
from isolated_clickhouse import isolated_clickhouse, apply_migrations
from test_support import binary, hspec
with isolated_clickhouse() as env:
    apply_migrations(env)
    hspec([binary('kansoku-core:test:kansoku-core-test'), '--match=Kansoku.Funnel'], env=env)
PY
just openapi
just openapi-check
just check
just acceptance
```

The focused run compares 1000 seeded timelines for each of four new mode/counting
combinations, plus the existing 2000 selected-chain comparisons. Public producer fixtures
live in `scripts/funnel_acceptance.py`, exercised by owned packaged acceptance.


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


Revision note (2026-10-16): Reconcile the stale windowFunnel premise with completed EP-36,
define nonoverlapping restart and any-order attribution behavior, and make native and public
validation reproducible without an ambient database. These clarify the existing three-feature
scope; defaults preserve deterministic sequential uniques.
