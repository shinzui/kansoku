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
---

# Metric property filters and dual grouping

This ExecPlan is a living document. Update its living sections and durable ADRs as work
proceeds. It is a child of
`docs/masterplans/5-act-on-rev-1-close-silent-loss-paths-add-metric-filters-and-enrich-web-analytics.md`
and acts on findings E6 and E7 of
`docs/reviews/2026-10-15-architecture-and-feature-set-against-comparable-products.md`.


## Purpose / Big Picture

An application embedding Kansoku metrics will be able to ask "revenue by plan for enterprise
customers in July" with one HTTP call: standard metric routes will accept repeatable `filter`
parameters over declared event properties and built-in dimensions, and up to two `groupBy`
dimensions, with the same complete-or-error bounds the routes already enforce. Every filter
compiles through the existing declared-property check and native-parameter binding, so the
safety argument of ADR 4 carries over unchanged.


## Progress

- [ ] M1: `filter=` on every standard metric route (events, page-views, sessions, feature-adoption, users, revenue) with the operator set below, rejected with `invalid_filter` when malformed or undeclared, proven by HTTP integration tests over fixtures.
- [ ] M2: Two `groupBy` dimensions produce `group` objects with both keys under the existing 10,000-point cap; rollup fast paths are bypassed when a filter or a second dimension is present.
- [ ] M3: OpenAPI, the Haskell client and `docs/guides/query-metrics.md` describe filters and dual grouping; the sessions guide states that a session spanning two buckets counts in each.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Filter grammar is `filter=<dimension>:<op>:<value>`, repeatable up to eight times,
  all conjoined with AND, where `<dimension>` is `event_name`, `source`, `source_service`,
  `host`, `route` or `prop:<name>`, and `<op>` is one of `eq`, `neq`, `in`, `contains`, `gt`,
  `lt`, `set`, `unset`.
  `in` takes a comma-separated list; `set` and `unset` take no value.
  Rationale: One parameter shape keeps generated clients simple; the operator set matches the
  intersection of PostHog's and Plausible's documented operators. OR and nesting are excluded
  from this plan.
  Date: 2026-10-15
- Decision: Add `source_service` and `host` as built-in dimensions for both `filter` and
  `groupBy`, where `host` is `domain(url)` computed at query time like `route` is `path(url)`.
  Rationale: A single account is meant to hold a marketing site and the product application
  together so identity stitching can link them, but `route` is the path alone, so `/pricing`
  on both properties merges, and `sourceService` is stored in `events_raw.source_service` yet
  is not queryable. Both dimensions are columns or cheap expressions and need no storage change.
  Date: 2026-10-15
- Decision: Property filters are allowed only when every event queried by the metric declares
  the property, the same rule as `groupBy=prop:`.
  Rationale: Reuses ADR 4's compile boundary and keeps undeclared JSON out of SQL.
  Date: 2026-10-15


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Metric routes are declared as Servant NamedRoutes records in
`kansoku-api/src/Kansoku/Metrics/Api.hs`; the standard routes take `from`, `to`, an optional
`groupBy` and `timeGrain`. `kansoku-core/src/Kansoku/Metrics/Handler.hs` parses parameters,
builds a `QueryRequest` carrying the service-token account, and dispatches to SQL builders in
`kansoku-core/src/Kansoku/Metrics/Query.hs`. Dimension and property names pass through
`kansoku-core/src/Kansoku/Metrics/Query/Validate.hs` (`mkSqlName` enforces a strict charset),
and property expressions use `toString(getSubcolumn(properties_json, '<name>'))` after the
registry check in `resolveNumericProperty` and its grouping counterpart. Account ids and event
names are bound as native ClickHouse parameters, never interpolated. Day-grain page views and
day and week active users read rollups; everything else reads `analytics.events_raw` or the
identity-resolved view `analytics.events_resolved`.

`docs/plans/26-bound-analytics-query-inputs-and-result-cardinality.md` (in progress at the
time of writing) adds fixed bounds and a bounded, complete-or-error execution path with stable
problem codes; this plan must be implemented after it is Complete because filters add
predicates inside that bounded projection and dual grouping multiplies result cardinality.

Relevant decisions: [ADR 4](../adr/0004-queryable-event-properties-and-identity-resolved-projection.md)
(property compile boundary, `prop:` prefix), [ADR 3](../adr/0003-api-key-authentication-and-account-scoped-analytics.md)
(native parameters, account predicate completeness test), and the proposed
[ADR 9](../adr/0009-bounded-complete-aggregate-responses.md) (bounds and ordering). No
cross-repository ADR applies.


## Plan of Work

### M1: Filters

Define `MetricFilter` in `kansoku-api/src/Kansoku/Metrics/Filter.hs` with a parser from the
wire text and a `ToJSON` instance for problem details. Add `QueryParams "filter" Text` to the
standard route record and regenerate the client. In the handler, parse each filter, reject more
than eight or any malformed entry with a new stable code `invalid_filter` (400, non-retryable)
added to the catalog in `kansoku-api/src/Kansoku/Api/Response.hs`, and resolve `prop:` names
against the registry exactly as grouping does. Compile to SQL predicates in `Query.hs`: string
operators compare the property expression (or the built-in column) with native parameters
named `filter_<n>_value`; `in` binds an array parameter; `gt` and `lt` cast the property with
`CAST(getSubcolumn(...), 'Float64')` and require a numeric declared type; `set` and `unset`
test `isNotNull`/`isNull` on the subcolumn (for built-in dimensions, non-empty string). The
built-in dimensions compile to `event_name`, `source`, `source_service`, `domain(url)` and
`path(url)` respectively; `host` and `route` are expressions, not columns, so grouping by them
on the day-grain page-view rollup is only possible for `route`, which the rollup already keys.
Apply filters on the raw-table and resolved-view paths alike; when a filter is present, route
day-grain page views and users to the raw or resolved path instead of the rollup, and say so in
the accuracy map comment.

### M2: Dual grouping

Allow `groupBy=a,b` with exactly one or two distinct dimensions drawn from the built-in set
(`event_name`, `source`, `source_service`, `host`, `route`) and `prop:<name>`. The `group`
object carries one key per dimension; the SQL `group_key` becomes a composite the handler splits, following the
pattern the funnel order already uses for its `index|step` composite. Keep bucket-then-group
ordering and the EP-26 point cap unchanged; a two-dimension query that overflows 10,000 points
receives the existing `metric_result_too_large` problem. Ratio metrics keep rejecting property
dimensions.

### M3: Contract and documentation

Regenerate `docs/api/openapi.json`, update the route description to state the grammar, operator
set, eight-filter limit and the two-dimension rule, extend `docs/guides/query-metrics.md` with a
"Filters" section and two examples, and add the E7 sentence about sessions spanning buckets.
Add a short "One account, several properties" paragraph to the same guide and to
`docs/guides/send-events.md`: set `sourceService` per property (for example `marketing-site`
and `app`), keep both in one account so identity stitching can link a marketing visit to a
later signup, and use `filter=source_service:eq:…` or `groupBy=host` to separate them in
queries.
Update ADR 4 with the filter contract.


## Concrete Steps

Inside `nix develop` with the stack up and fixtures loaded (`db/clickhouse/fixtures`):

```bash
cabal build all --enable-tests
cabal test kansoku-core --test-options='--match "Filter"'
cabal test kansoku-core --test-options='--match "QueryIntegration"'
just openapi && just openapi-check
```

Example after `just run` with a service token in `TOKEN`:

```bash
curl -s --get http://localhost:8080/metrics/revenue -H "Authorization: Bearer $TOKEN" \
  --data-urlencode from=2026-07-01 --data-urlencode to=2026-08-01 \
  --data-urlencode 'filter=prop:plan:in:pro,enterprise' --data-urlencode 'groupBy=prop:plan,source'
```

Expected: HTTP 200 with points whose `group` objects carry both `plan` and `source`.


## Validation and Acceptance

Required acceptance over the committed fixtures:

1. `filter=prop:plan:eq:pro` on revenue returns the sum of `amount` for `pro` rows only; the
   unfiltered call still equals the previous total.
2. `filter=source:neq:web` on events excludes web rows; `filter=route:contains:/pricing` on
   page-views returns only matching routes; with fixtures carrying two hosts and two
   `sourceService` values, `filter=source_service:eq:marketing-site` and `groupBy=host` separate
   them and `groupBy=host,route` distinguishes `/pricing` on each property.
3. `filter=prop:amount:gt:100` on revenue works; the same operator on a string property returns
   400 `invalid_filter` naming the type.
4. An undeclared property, a ninth filter, an unknown operator, and `filter=prop:plan:set:x`
   each return 400 `invalid_filter` with a detail naming the offending entry.
5. `groupBy=prop:plan,source` returns composite groups; `groupBy=a,b,c` and `groupBy=a,a`
   return 400; a conversion ratio with `groupBy=prop:plan` still returns 400.
6. With any filter, day-grain page views equal a raw-path recount, proving the rollup bypass.
7. The account-predicate completeness test still passes for every builder.


## Idempotence and Recovery

Purely additive API surface; absent `filter` and single `groupBy` behave exactly as before. No
schema change. If a compiled predicate proves wrong, the problem code lets clients fall back
to unfiltered calls while a fix ships.


## Interfaces and Dependencies

Hard dependency: `docs/plans/26-bound-analytics-query-inputs-and-result-cardinality.md`
Complete. `Kansoku.Metrics.Filter`, the `filter_<n>_value` parameter naming and the built-in
dimensions `source_service` and `host` are claimed here and consumed by `docs/plans/33-acquisition-and-device-enrichment-with-bot-flagging.md`
(new built-in dimensions), `docs/plans/35-rolling-active-users-retention-modes-and-lifetime-cohorts.md`
and `docs/plans/36-funnel-modes-and-experiment-exposure-diagnostics.md` (breakdowns). No new
libraries.
