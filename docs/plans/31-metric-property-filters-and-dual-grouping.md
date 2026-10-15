---
id: 31
slug: metric-property-filters-and-dual-grouping
title: "Metric property filters and dual grouping"
kind: exec-plan
created_at: 2026-10-15T13:44:34Z
intention: "intention_01m4zwwdrjesytazp5tb39fe3n"
master_plan: "docs/masterplans/5-act-on-rev-1-close-silent-loss-paths-add-metric-filters-and-enrich-web-analytics.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-15T13:44:34Z
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-15T14:55:47Z
      mode: "update"
      note: "Add source_service and host built-in dimensions and the one-account-several-properties guidance."
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-15T15:43:15Z
      mode: "update"
      note: "Reconcile first-release APIs, domain semantics, dependencies and acceptance with the source-validated MP-5 review."
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-15T15:43:15Z
      verdict: "changes-requested"
      note: "Original draft review found correctness gaps; findings corrected by the accompanying update, with native acceptance still required."
---

# Metric property filters and dual grouping


## Purpose / Big Picture


Provide one documented, typed filter and grouping contract across metrics. Results must keep
the same population and identity semantics when a filter forces a different query path.
This is the initial deployment: fix ambiguous encodings now rather than support temporary aliases.

## Progress


- [ ] M1: Typed bounded filters work on standard metrics with explicit missing/type semantics.
- [ ] M2: Dual grouping preserves arbitrary values and namespaced dimension keys.
- [ ] M3: Route support, exactness and generated clients match native fixtures and OpenAPI.

## Surprises & Discoveries


`events_resolved` has only seven columns: it lacks source, source_service, session and device
fields. The existing property helper is `Metrics/Query/Property.hs`, not `Query/Validate.hs`.
Its numeric cast accepts PTAny and can fail on historical mixed data. Delimiter splitting is
unsafe for arbitrary property values, and raw-rollup user counts disagree with resolved counts.

## Decision Log


On 2026-10-15 use repeatable JSON filter objects and JSON-encoded group projections. Require
exact identity-resolved HTTP user counts for both filtered and unfiltered paths; approximate raw
sketches remain explicitly named internal/SQL options, not a silent route optimization.

## Outcomes & Retrospective


Planning reviewed; contract generation and runtime checks remain outstanding.

## Context and Orientation


`kansoku-api/src/Kansoku/Metrics/Api.hs` defines `MetricPoint`, whose current group values are
Text. `kansoku-core/src/Kansoku/Metrics/Handler.hs` dispatches to `Query.hs`; `Query/Property.hs`
validates registry properties. `boundedSQL` limits final rows and supports typed hidden ordering.
Read [ADR-3](../adr/0003-api-key-authentication-and-account-scoped-analytics.md),
[ADR-4](../adr/0004-queryable-event-properties-and-identity-resolved-projection.md) and
[ADR-9](../adr/0009-bounded-complete-aggregate-responses.md), now Accepted. EP-26 is Complete.

## Plan of Work


### M1: Typed filter contract


Define `MetricFilter` and parsing in `kansoku-api/src/Kansoku/Metrics/Filter.hs`; compile only
validated expressions in core. `filter` is repeatable, AND-combined, at most eight objects,
with URL-decoded JSON such as `{"dimension":"prop:plan","op":"in","value":["pro","enterprise"]}`.
Dimensions initially are event_name, source, source_service, host, route and prop:<name>;
EP-33 adds enrichment and EP-40 user traits. Operators: eq, neq, in, contains, gt, lt, set, unset.
Require exactly dimension/op and, except set/unset, value. Reject unknown keys, null operands,
empty or mixed-type in arrays, more than 100 in values, any string above 1024 UTF-8 bytes,
and combined decoded filters above 16 KiB with 400 invalid_filter. Scalars are string, finite
number or Boolean; gt/lt require numeric declarations, contains requires string. Bind every
value as a native parameter. Never concatenate caller input into SQL.

A missing or JSON-null property is unset; every comparison including neq returns false for
unset. Empty string is a present property value. Built-in absent strings normalize to missing.
Require compatible declared scalar types across queried event schemas; PTAny is not numeric.
Historical incompatible values become missing with guarded conversion, never server errors.
For `/metrics/events`, a positive event_name eq/in filter establishes the finite event scope
for prop validation; reject property filters if event scope remains unbounded. Every ratio
builder applies population filters consistently to numerator and denominator; retain the
explicit rejection of unsupported event-property ratio dimensions. Test this route matrix.

EP-32 owns the internal rich resolved relation: extend it with canonical raw fields and join
by account/event ID without altering the public seven-column view. EP-30 supplies canonical
rows. No builder may select nonexistent source columns from the public view or fan out joins.

### M2: Lossless grouping


`groupBy` accepts one or two distinct comma-separated dimension names. Return full names as
keys (`prop:plan`, `user:plan`, `source`) and change `MetricPoint.group` to
`Map Text (Maybe Text)` so missing is JSON null, distinct from empty string or literal "other".
Values use documented scalar text rendering. Carry group values through native `group_key`
as a JSON array of nullable strings and decode structurally; no pipe/comma splitting.
Keep typed bucket/dimension sorting separate from serialized JSON and retain the 10000-point
complete-or-error cap. Upgrade all existing funnel/experiment group encodings as needed so
new dimensions and values cannot collide with metadata keys such as step/measure/variant.

### M3: Stable metric populations


Define active-user activity as events other than identify, identify_once, alias and group;
backend profile synchronization alone must not create active users. Apply that same base population
to rolling users, retention and lifecycle in EP-35, before optional filters.
Use exact canonical resolved identities for `/metrics/users` even without filters, bypassing
the approximate raw-identity DAU/WAU sketches. Page-view rollups may be used only when they
preserve deduplication, every requested filter/dimension and the bot policy. Unsupported
parameters return explicit 400 rather than being ignored; add an explicit route-parameter
validation boundary because Servant normally ignores unknown query parameters.
Own shared query work limits in Config.hs/Query.hs: KANSOKU_METRICS_MAX_EXECUTION_SEC=30
and KANSOKU_METRICS_MAX_MEMORY_BYTES=536870912, positive integers, applied on each query
including all subqueries. Map native timeout/memory-limit errors to non-retryable 400
query_resource_limit, preserving asynchronous cancellation and disposing failed handles.
Other storage failures remain retryable 503; never enable partial/break overflow modes. Publish a route-by-parameter matrix
in `docs/guides/query-metrics.md`, including event filters versus session/cohort filters as
later children define. Explain that sourceService/host separates properties inside one account,
but cross-origin identity still requires SDK cookie/handoff integration.
Regenerate OpenAPI and the Haskell client, and update ADR-4 and ADR-6 during implementation.

## Validation and Acceptance


Test every operator with missing, null, empty, Unicode, colon, comma, pipe, quote and backslash;
roundtrip full group keys, including built-in `source` alongside `prop:source`. Revenue filters
preserve totals; unfiltered users equal a filter that includes all rows, including stitched
anonymous traffic. Guard numeric extraction across schema versions and unknown events.
Assert account predicates on every subquery/join, no fanout, deterministic ordering across
multiple native blocks, and 10000/10001 results. Examples use `curl --data-urlencode` with a
JSON filter, never the superseded colon grammar.

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


No data migration here. This pre-deployment change intentionally updates the initial group contract; regenerate all consumers in the same implementation change. Invalid filters are errors; clients must never silently retry an unfiltered query.

## Interfaces and Dependencies


Required complete child artifacts: `docs/plans/26-bound-analytics-query-inputs-and-result-cardinality.md`, `docs/plans/30-pipeline-backpressure-and-storage-outage-resilience.md`, `docs/plans/32-time-aware-identity-bindings-and-bounded-resolution-cost.md`.

Hard dependencies: EP-26, EP-30 and EP-32 Complete, at `docs/plans/26-bound-analytics-query-inputs-and-result-cardinality.md`, `docs/plans/30-pipeline-backpressure-and-storage-outage-resilience.md`, and `docs/plans/32-time-aware-identity-bindings-and-bounded-resolution-cost.md`. Owns wire grammar and group shape; every later metric child consumes these unchanged.

Revision note (2026-10-15): reviewed against the current source and revised for first deployment.
[ADR-11](../adr/0011-initial-release-analytics-contracts.md) records the proposed cross-plan
contracts; implementation must supply the acceptance evidence before those contracts become
accepted runtime guarantees.
