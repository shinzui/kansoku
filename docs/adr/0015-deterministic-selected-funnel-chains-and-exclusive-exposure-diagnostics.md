---
type: Architecture Decision Record
title: Deterministic selected funnel chains and exclusive exposure diagnostics
description: Share one deterministic chain evaluator for funnel counts, timing and ordered signup conversion; separate experiment contamination from exclusive first-observed assignment shares.
docId: ADR-15
status: Accepted
date: 2026-10-16
timestamp: 2026-10-16T12:10:14Z
generated:
  by: process:codex
  at: 2026-10-16T00:12:46Z
---

# Deterministic selected funnel chains and exclusive exposure diagnostics

## Context

Step-name prefiltering hides strict-mode interruptions. Native windowFunnel can reuse one
physical event for two repeated-name conditions, and its same-timestamp ordering does not
encode immutable event IDs. Unrelated numerator/denominator user sets can produce conversion
above one. Users exposed to multiple variants make overlapping per-variant exposure shares
sum above one. [ADR-6](0006-exposure-based-experiment-analytics.md) owns exposure gating;
[ADR-9](0009-bounded-complete-aggregate-responses.md) owns complete bounded responses.

## Decision

Use one pure reference and equivalent native array evaluator for both funnel routes and
ordered signup conversion. Canonical immutable events are deduplicated before ordering by
stored millisecond occurred_at then event_id. A physical event satisfies at most one step.
Sequential mode permits intervening events; strict mode requires adjacent timeline events,
including automatic events. Strict mode has no implicit deduplication rule. In sequential/strict uniques, consider every
matching start. Select maximum reached level, earliest completion, earliest start and event
ID list in that order. The inclusive window bounds elapsed milliseconds from the start.

An exclusion between matched steps stops extension but preserves the already reached prefix;
exclusions after completion do not undo a chain. Later starts may qualify. Exclusion names
are validated, distinct-count bounded to 20, and cannot overlap step names. Sequential filters
select matching step rows, while excluded rows always remain visible. Strict event filters
are rejected because they could hide interruptions. Future current-trait selection must
select subjects without removing their intervening events.

Any-order uniques opens exactly one window at the earliest event matching any requested
step. Count distinct matched step positions, assigning repeated names to their next unused
position; one physical event still satisfies at most one position. Intermediate indices
report reach ranks, and timing follows that chronological reach. An exclusion or expiry ends
this window without searching later windows.

Totals counting uses nonoverlapping attempts. Start at step one for sequential/strict, or
any matching step for any-order. After completion consume the completing event. On expiry,
exclusion or strict interruption, preserve the reached prefix and allow the closing event
to start a new eligible attempt. Do not add an exclusion grace period. Count each attempt
in cumulative reach and timing; emit an additional unbucketed measure=entries point with
null index/step/breakdown fields (per variant for experiments), and measure=count on totals
reach rows. Include partial attempts. The entries row shares the final result limit.

Group ownership is the earliest eligible start in the selected population, even when
another start wins; totals owns groups per attempt. Only prop dimensions respond to
attribution: first_touch uses that start, last_touch the selected chain's last matched
event, and step:n the event for the named requested position. This remains the named
position in any-order, independent of reach rank. Missing/null/unreached properties render
as other while typed nullable sort columns preserve numeric/boolean ordering. Missing string values coalesce before aggregation so they merge
with a literal other value. Ordered first-touch
validates its first-step schema first, with compatible declarations from other steps as a
fallback for a property absent there. Any-order first-touch and last-touch validate compatible scalar types wherever
declared across the finite step scope. step:n validates that step's schema and must be in
range. Unknown properties remain errors. Built-in/current-trait groups keep start ownership. Exposure-gated timelines include events at or after first exposure for
each user/variant within the requested range; multi-variant users remain in each variant.
Counts and durations use the same selected chain. Exact nearest-rank percentiles sort elapsed
milliseconds/1000 and select ceil(p*N), for p=0.5 and 0.9, on reached steps >=2. No approximate
quantile state or alternate timing chain is used. No reached chains means no timing points.

Signup conversion uses the same sequential two-step chain. The denominator is distinct
starters; the numerator is valid completers among those starters. The default window is the
request length capped at 90 days. Grouping uses first start; prop grouping and timeGrain are
explicit errors. Empty denominator yields zero. Existing service-token isolation, native
memory/time budgets, outer cancellation and final 10000-point limit apply before success.

Experiment measure=exposures retains the approximate raw-identity rollup. Diagnostics use
exact resolved subjects and valid exposure names. Per experiment and requested bucket, each
subject is assigned once to earliest exposure by millisecond time and event ID. Exposed users
and users with multiple observed variants are totals; assigned_users and variant_share use
exclusive assignments. Include observed variants with zero assignments. Empty buckets emit
zero totals and no variant rows; when no experiment is requested and none is observed, the
experiment label is null. Missing/invalid variant exposures do not enter this population.
First observed exposure is not an authoritative randomization log. High contamination
invalidates naive sample-ratio interpretation. Preserve every deduplicated exposure for
existing conversion and external statistics consumers.

## Alternatives considered

Retaining native windowFunnel was rejected after actual packaged-engine counterexamples for
repeated names and timestamp ties. Selecting the fastest chain for timing or the winning
attempt's label for first-touch grouping was rejected because those would describe different
populations. Overlapping observed-variant exposure counts remain useful, but cannot serve as
exclusive assignment shares. No new persisted state is required.

## Consequences

Array construction and evaluation are bounded by shared native work limits, not by truncating
user sequences. Large histories can produce a resource error. Reference/native differential
acceptance must compare full event IDs and millisecond durations for at least 1000 seeded
timelines per path: sequential/strict selected-chain uniques, any-order uniques, and all
three totals modes. Baseline selected-chain native route, packaged public in all three telemetry modes, pinned SDK and ten-million-event
retained-history acceptance pass. All 28 performance cases remain below 2x identity overhead
and the unchanged native memory budget. The diagnostic boundary fixture required grouped
assignment counts, rather than a subject-by-variant array scan. Evidence is recorded in
[EP-36](../plans/36-funnel-modes-and-experiment-exposure-diagnostics.md). Final joint browser,
trait and operational integration remains the MasterPlan's responsibility.
Extended any-order, totals and attribution native/public acceptance is recorded in
[EP-43](../plans/43-funnel-extensions-any-order-re-entry-counting-and-per-step-attribution.md).
