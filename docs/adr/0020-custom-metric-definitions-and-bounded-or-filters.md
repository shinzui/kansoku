---
type: Architecture Decision Record
title: Custom metric definitions and bounded OR filters
description: Compile account-scoped saved and ad-hoc metric definitions through the builtin query rules, with bounded alternatives inside each conjoined filter group.
docId: ADR-20
status: Accepted
date: 2026-10-16
timestamp: 2026-11-06T14:31:34Z
generated:
  by: process:codex
  at: 2026-10-16T12:30:07Z
originatingPlan: docs/plans/44-custom-metric-definitions-and-or-filter-groups.md
---

# Custom metric definitions and bounded OR filters

## Context

Applications need metric definitions without a service release and alternatives within
one filter condition. [ADR-4](0004-queryable-event-properties-and-identity-resolved-projection.md)
owns declared property extraction and identity projection;
[ADR-9](0009-bounded-complete-aggregate-responses.md) owns complete bounded aggregates;
[ADR-19](0019-saved-query-time-cohorts-and-static-membership.md) owns reusable account-scoped
cohort references and resource pagination. These rules also govern custom metrics.

## Decision

`Kansoku.Metrics.Definition` in the shared API package owns the wire representation.
A simple definition contains name, description, eventNames, aggregation,
aggregationProperty, optional quantile, filters as a list of grammar strings, groupBy as full dimension
names, and timeGrain. A ratio contains name, description, numerator and denominator;
its components are simple definitions with no independent grouping or time grain.
Each component can count distinct events, count resolved subjects, sum, or average.
Ratios are unbucketed and reject event-property grouping; zero denominator yields zero.
Numeric aggregates require compatible numeric declarations across every selected event.
There are 1..100 validated event names per component; unregistered names are queryable
without property dimensions. Definition names are labels, never builtin dispatch keys.

`/metrics/custom` builds ad-hoc definitions or loads a saved name. PostgreSQL
`kansoku.metric_definitions` owns UUIDs, account-scoped unique names, JSON definitions
and timestamps. Authenticated CRUD validates on write and execution; lists use the
existing released `mori://shinzui/relay-pagination` keyset engine in UUID order. Saved
simple filters are conjoined with request filters; request grouping and grain override
saved defaults. Ratio component filters select their own side, while request filters
select both sides. Trait and cohort discovery includes saved defaults and both ratio
components before selecting raw/resolved sources or loading memberships. Missing or
foreign definitions return metric_not_found. Missing cohorts remain cohort_not_found.

A repeated filter is one AND condition. Inside it, at most eight full shorthand
`dimension:op:value` terms separated by `|` are alternatives. Existing JSON terms remain
supported, including arbitrary literal punctuation; JSON `{or:[term,...]}` provides
bounded alternatives to typed clients. JSON groups cannot nest. A literal pipe in a
shorthand operand is ambiguous and requires JSON. The existing eight-group, 16-KiB,
string and in-array bounds remain; saved and request filters share the group/byte budget
for each selected population. All terms are validated and all operands bound natively.
Only an OR group whose every term positively selects event names establishes a finite
scope for property validation. A mixed event-name/other-dimension group cannot narrow it.

Custom metrics contain definitions, never SQL. They share account predicates, canonical
event deduplication, identity resolution, property checks, complete-result bounds and
query resource budgets with builtins. Count/sum/average/percentile use canonical raw events unless
traits/cohorts require the resolved source; unique counts and ratios use resolved events.
Saved state does not snapshot data, identities, traits or cohort membership.

## Alternatives considered

Stored SQL would bypass property governance and account isolation. Nested Boolean trees
would expand the public grammar and validation cost beyond the required AND-of-ORs.
Replacing the established JSON grammar would break typed producers and arbitrary text
values. Separate metric execution and resource pagination implementations would duplicate
existing safety and cursor contracts. These alternatives were rejected.

## Consequences

Applications can reuse named definitions while retaining complete-or-error query behavior.
JSON filters retain backward compatibility. Historical results can change with current
identity, trait, cohort or definition updates. Builtin filters use the same string-list
shape. Public native roundtrips exercise all aggregations, replay, saved overrides, both
cursor directions, cohorts/traits and account isolation; deterministic compiler checks
cover OR scope safety, invalid definitions and native parameterization.

## Whole-range temporal grouping

Explicit `timeGrain=none` is distinct from omission/null and is persisted as the string none. Request grain overrides saved grain in either direction. Simple custom aggregates, calendar users, acquisition, events, page views and sessions support a constant null bucket per populated group. Exact identities are aggregated over the whole selected population; per-group counts can overlap. Custom ratios still reject explicit grain. Existing sparse results, population rules and complete-result bounds apply; sessions alone retain ungrouped zero-fill.

## Exact percentile aggregation

Simple definitions support percentile with a declared numeric aggregationProperty and
required finite quantile strictly between zero and one. The optional JSON field is
omitted when absent, preserving legacy payloads. Ad-hoc URL quantile uses the same
validation; saved execution cannot override it. Ratio components reject percentile and
other aggregations reject quantile. Writes, loaded definitions and the compiler validate
before executing native queries.

ClickHouse quantileExactInclusive performs exact inclusive (R-7) interpolation at
zero-based position (n-1)q on finite Float64 samples; a singleton returns itself. Each
bucket/group uses its full underlying population, never aggregated partial percentiles.
The normal numeric extraction excludes missing, null, incompatible and non-finite values.
Canonical events deduplicate replay; traits/cohorts select the existing resolved source.
Empty populations emit no points. Exact sample retention remains subject to existing
memory/execution limits and complete-or-error behavior, with no approximation fallback.

Sample-count pairing uses separate existing count requests and identical explicit numeric
property set filters on both requests, plus matching events, dates, grouping, grain and
other filters. No new count field or atomic snapshot is introduced; writes or changes to
current identity/trait/cohort state between requests can change either population.

## Session-scoped custom populations

Ad-hoc and saved definitions accept the closed intrinsic session namespace from
[ADR-13](0013-whole-retained-replay-safe-web-sessions.md). Simple saved filters/default groups,
request overrides/common filters and both ratio component predicates participate in session
attachment discovery. One finalized left join supplies deduplicated requested attributes per
event relation, including for percentile samples. A component-only predicate triggers attachment
without a common session filter or group; side predicates stay inside their own aggregates.
Common filters still select both sides. Missing-session guards apply per Boolean term, preserving
mixed event/session OR alternatives and existing bound operands, types and query/result limits.
Nested session properties/traits/cohorts remain excluded; definitions retain their wire shape.
