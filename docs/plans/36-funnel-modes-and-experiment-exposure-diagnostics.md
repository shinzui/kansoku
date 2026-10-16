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
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-15T15:43:15Z
      verdict: "changes-requested"
      note: "Original draft review found correctness gaps; findings corrected by the accompanying update, with native acceptance still required."
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-15T15:43:15Z
      mode: "update"
      note: "Reconcile first-release APIs, domain semantics, dependencies and acceptance with the source-validated MP-5 review."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-15T23:49:10Z
      mode: "implement"
      note: "Begin deterministic funnel reference/native parity, shared selected-chain timing and breakdown, ordered conversion and exact exposure diagnostics after EP-35 acceptance."
---

# Funnel modes and experiment exposure diagnostics


## Purpose / Big Picture


Make funnel modes, conversion time and exposure diagnostics agree with their advertised
meaning. Strict mode must see intervening events; variant shares must name a denominator that
actually sums to one without hiding multi-variant users.

## Progress


- [x] M1: Strict/sequential funnels have a deterministic reference evaluator and native parity.
- [ ] M2: Exclusions, durations and first-touch breakdown use the same selected-chain semantics.
- [ ] M3: Exposure diagnostics distinguish contamination from mutually exclusive assignment share.

## Surprises & Discoveries


Both existing funnel builders filter event_name to the requested steps before windowFunnel;
strict_order cannot observe excluded rows. strict_deduplication is an additional rule, not a
synonym for strict order. Per-variant users divided by unique experiment users exceed one when
users see multiple variants. A first-touch label must not drift to a later converting attempt.

Native acceptance on the pinned ClickHouse 26.8.2.7 proves a single A can satisfy two
windowFunnel A,A conditions. Use the common array evaluator for every mode, rather than
maintain two subtly different algorithms. Stored millisecond values and event IDs are the
ordering source of truth. Early owned engine startup attempts stalled even on --version;
after startup recovered, all differential assertions executed (no skipped or fake green runs).

The first diagnostic implementation scanned a subject array for every variant. The 4999-variant
10000-point fixture hit the shared memory budget; replace it with grouped assignment counts
and observed-variant joins, preserving zero-assignment variants without a quadratic matrix.

## Decision Log


On 2026-10-15 define a common deterministic funnel reference first, then use windowFunnel only
where it proves equivalent. New diagnostics use exact resolved identities; existing approximate
exposure counts remain explicitly separate. Only exclusive assignment counts support a simple
sample-ratio diagnostic.

On 2026-10-16 choose exact nearest-rank p50/p90 over selected-chain elapsed milliseconds/1000,
using ceil(p*N). Exclusions stop extension while preserving the already reached prefix; later
starts may qualify. Empty diagnostic buckets emit zero totals without variant rows, including
a null experiment label when no experiment is selected and none is observed. Current-trait
population integration remains EP-40's responsibility; strict event filters are rejected.
[ADR-15](../adr/0015-deterministic-selected-funnel-chains-and-exclusive-exposure-diagnostics.md)
records these decisions (Proposed pending all acceptance gates).

Dependency lookup used Mori's registered ClickHouse client corpus and the vendored driver;
DateTime64 conversion stores floor(POSIX*1000), so native integer milliseconds match the
reference. The engine itself is not registered by Mori. The pinned target is upstream
v26.8.2.7-lts (commit c2930599c56702022276de06657ed51d83f31a05). The current authoritative
upstream release was checked as v26.9.19.9-stable (commit
4388bba75927a5367dc8169b667110ffefe06f98); no engine pin or dependency bound changes are needed.
Primary upstream arrayFold examples and windowFunnel documentation were read before the
native implementation; current-release-only modes were not assumed on the pinned engine.


## Outcomes & Retrospective


M1 native/reference parity passes 1000 seeded timelines in both modes (2000 full selected-ID
and millisecond-duration comparisons), alongside ten explicit semantic fixtures. M2/M3
functional native cases pass, including both 10000-point boundaries and native resource
classification (18 focused examples, zero failures). The full source gate passes 356 core
examples, 17 client examples, four probes, regenerated contracts, strict 15-ADR validation,
three HTTP telemetry modes and four lifecycle cases. Public packaged, SDK and expanded
performance gates remain pending. The diagnostics cost issue is corrected with grouped
assignment counts; no budget was raised. Private logs are under
`.dev/acceptance/identity-validation/ep36-{native,check}.log`.

## Context and Orientation


`buildFunnelSQLAggregate` and `buildExperimentFunnelSQLAggregate` in `Metrics/Query.hs` currently
use second-resolution windowFunnel and IN(step names). Public responses use MetricPoint.
`0014_experiment_exposures.sql` stores approximate raw-identity sketches.
Read [ADR-6](../adr/0006-exposure-based-experiment-analytics.md) and
[ClickHouse windowFunnel documentation](https://clickhouse.com/docs/sql-reference/aggregate-functions/parametric-functions).

## Plan of Work


### M1: Funnel semantics


Add mode=sequential|strict to both funnel routes. Build a pure reference evaluator over canonical
user timelines ordered by millisecond occurred_at then event_id; duplicate events are removed
first, and one physical event cannot satisfy two repeated-name steps. Sequential permits
intervening events; strict requires adjacent events in the eligible timeline to match consecutive
steps, including interruption by automatic events. Remove step-name prefiltering in strict mode.
Do not add strict_deduplication implicitly. Bound each chain by window seconds from its start;
consider subsequent starts so one failed early attempt cannot hide a valid later chain.
Per user choose maximum reached level, then earliest chain completion, then earliest start and
event IDs for ties. The same evaluator defines all modes and duration/breakdown behavior.
Default native windowFunnel is retained only after parity on repeated names and same-time events;
if parity fails, use the array evaluator for those cases rather than alter the public rule.

### M2: Exclusions, timing and breakdown


Add repeatable exclude event names, at most 20 distinct validated names. An excluded event
strictly between matched steps invalidates that chain; later chains may qualify. Conflicting
step/exclusion names return 400. For strict requests keep the full timeline; for sequential
array evaluation retain steps plus exclusions. Global event filters must not hide strict
interruptions: apply user-trait filters to eligible subjects; reject event-level filters on
strict funnels until an explicit selection contract exists. Preserve experiment exposure gating:
all eligible chain events occur at/after first exposure for that user/variant and inside range.

`measure=count|time_to_convert` defaults to count. For time, emit per reached step >=2 points
with group.measure=p50_seconds|p90_seconds using exact deterministic quantiles of elapsed
milliseconds/1000 for the selected chains. Include step index/name and variant where relevant.
Use first step-one event per user in the query population for first-touch prop breakdown,
even if the chosen converting chain starts later. Require that property on the first-step schema,
not every later step; missing is null under EP-31. Keep final typed ordering and point cap.
Apply EP-31's finite memory/time limits before materializing user arrays; overflow yields an
error, never truncated sequences. Tests must exercise all parameter combinations on both routes.

The existing `/metrics/conversion` also divides unrelated signup-completed and signup-started
user sets, so it may exceed one and count completion before start. Bring it onto the same
ordered two-step contract: denominator is distinct users with signup_started in range; numerator
is those users with signup_completed after a valid start within the same bounded default window
(range length capped at 90 days). Use the common chain evaluator, return zero for empty denominator,
and group by the starting population's supported dimensions/current traits. Explicitly reject
unsupported timeGrain/event-property grouping instead of silently ignoring it. Test completion-only,
completion-before-start, retry, and unrelated starters; the ratio must stay in [0,1].

### M3: Experiment diagnostics


Expose diagnostics through an explicit measure=exposures|diagnostics selector, default exposures,
so existing exposure points are not silently mixed with other values. Diagnostics use canonical
resolved users and emit multiple_exposure (users with >1 variant), exposed_users, and for each
variant assigned_users and variant_share. Assign each user once to their earliest observed
exposure ordered by occurred_at,event_id; share is assigned_users / exposed_users. Repeated
exposures do not increase assignment counts. Multi-exposure users remain in every variant for
existing conversion analytics, but only first assignment for these shares. With zero users,
emit zero totals and no variant-share rows. Match requested bucket scope for every diagnostic.
Document that first observed exposure is not an authoritative randomization log; high contamination
invalidates a naive sample-ratio interpretation. GrowthBook receives all deduplicated exposures.

## Validation and Acceptance


A/B interrupted by page_view fails strict and passes sequential. Test A,A,B; repeated requested
A,A; equal milliseconds; duplicate replay; excluded events; failed early/valid late starts; exact
window boundary; and pre-exposure steps. Differential tests cover at least 1000 seeded random
sequences and the actual packaged engine. Timing/breakdown fixtures prove chain selection and
first-touch ownership. One user exposed A then B yields multiple_exposure=1, A assignment=1,
B assignment=0 and shares summing to one. Test account isolation, multiple buckets, missing
variants, zero data, native block ordering and 10000/10001 results.

## Concrete Steps


Run commands from the repository root inside `nix develop`. Use the private databases owned
by `scripts/acceptance.sh` and `Kansoku.ClickHouseTestSupport`, not an ambient development
stack: native fixtures mutate tables. Extend that harness for the scenarios in this plan.

```bash
cabal build all --enable-tests
just openapi
just contracts
just check
just acceptance
```

Use focused Hspec examples while developing. Before marking Complete, require nonzero example
counts, no pending required integration tests, regenerated contract checks, and the packaged
executable acceptance above. Record only the relevant evidence here. This follows
[ADR-10](../adr/0010-owned-executable-acceptance-environments.md).

## Idempotence and Recovery


No new persisted state is required. Keep old semantic fixtures only when their intended behavior remains valid; explicitly replace tests that accidentally let one event satisfy repeated steps.

## Interfaces and Dependencies


Required complete child artifacts: `docs/plans/26-bound-analytics-query-inputs-and-result-cardinality.md`, `docs/plans/31-metric-property-filters-and-dual-grouping.md`, `docs/plans/32-time-aware-identity-bindings-and-bounded-resolution-cost.md`.

Hard dependencies: EP-26, EP-31 and EP-32 Complete. EP-31 owns group encoding; EP-32 canonical users. EP-38 consumes the final diagnostics in its statistics guide. Relevant paths: `docs/plans/31-metric-property-filters-and-dual-grouping.md`, `docs/plans/32-time-aware-identity-bindings-and-bounded-resolution-cost.md`.

Revision note (2026-10-15): reviewed against the current source and revised for first deployment.
[ADR-11](../adr/0011-initial-release-analytics-contracts.md) records the proposed cross-plan
contracts; implementation must supply the acceptance evidence before those contracts become
accepted runtime guarantees.
