---
id: 44
slug: custom-metric-definitions-and-or-filter-groups
title: "Custom metric definitions and OR filter groups"
kind: exec-plan
created_at: 2026-10-15T15:14:00Z
intention: "intention_01m4zwwdrjesytazp5tb39fe3n"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-15T15:14:00Z
---

# Custom metric definitions and OR filter groups

This ExecPlan is a living document. Update its living sections and durable ADRs as work
proceeds. It is a standalone plan, independent of
`docs/masterplans/5-act-on-rev-1-close-silent-loss-paths-add-metric-filters-and-enrich-web-analytics.md`,
that implements the `/metrics/custom` stub and the boolean filter gap named in
`docs/reviews/2026-10-15-architecture-and-feature-set-against-comparable-products.md`
(finding E6) and the 2026-10-15 assessment.


## Purpose / Big Picture

An application will be able to define a metric without a Kansoku release: "unique users
who did `document_shared` or `document_exported`, grouped by plan", either ad hoc in one
request or saved under a name and reused by dashboards and the product UI. Filters will
accept alternatives within one condition ("plan is pro or enterprise", "source is web or
app") so the common "either of these" question no longer needs two calls and a merge.


## Progress

- [ ] M1: `|` inside one `filter` parameter expresses alternatives, giving AND-of-ORs with the existing repeat semantics, proven on fixtures.
- [ ] M2: `GET /metrics/custom` computes an ad-hoc definition from query parameters with every aggregation the builtin registry supports, including ratios.
- [ ] M3: Saved definitions can be managed at `/metric-definitions` with cursor pagination and run by name through `/metrics/custom?metric=`.
- [ ] M4: OpenAPI, the client, the query guide and an ADR describe the definition shape and its limits.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: OR is expressed inside a single `filter` parameter by `|` between full
  `dimension:op:value` terms; separate `filter` parameters stay conjoined. Values may not
  contain `|`; a term containing it is rejected with `invalid_filter`.
  Rationale: AND-of-ORs covers the questions product tools expose without a nested grammar,
  and the generated clients need no new type.
  Date: 2026-10-15
- Decision: Saved definitions are stored in PostgreSQL as the existing `MetricDefinition` and
  `RatioMetric` JSON, with `filters` changed from a map to a list of grammar strings; builtin
  definitions migrate to the same shape.
  Rationale: `Kansoku.Metrics.Definition` already has JSON instances and the builders already
  run from these records, so saved metrics reuse the compile path and the ADR 4 safety rules
  wholesale.
  Date: 2026-10-15


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

`kansoku-core/src/Kansoku/Metrics/Definition.hs` defines `MetricDefinition` (`name`,
`description`, `eventNames`, `aggregation` of `Count | UniqueCount | Sum | Average | Ratio`,
`aggregationProperty`, `filters :: Map Text Value`, `groupBy`, `timeGrain`) and `RatioMetric`
(numerator and denominator definitions), both with JSON instances;
`kansoku-core/src/Kansoku/Metrics/Registry.hs` holds the builtin map (`events`, `page_views`,
`sessions`, `active_users`, `new_users`, `returning_users`, `feature_adoption`, `revenue`,
and the ratios `conversion_rate`, `activation_rate`, `retention`). The handler in
`kansoku-core/src/Kansoku/Metrics/Handler.hs` resolves a route to a builtin and runs the
matching builder in `kansoku-core/src/Kansoku/Metrics/Query.hs`; the `custom` route in
`kansoku-api/src/Kansoku/Metrics/Api.hs` carries the standard `MetricQuery` parameters and
today returns 404 `not_implemented` (Handler around line 185). Filters and their
`filter_<n>_value` native parameters come from
`docs/plans/31-metric-property-filters-and-dual-grouping.md`; declared-property rules from
[ADR 4](../adr/0004-queryable-event-properties-and-identity-resolved-projection.md); bounds from
[ADR 9](../adr/0009-bounded-complete-aggregate-responses.md). PostgreSQL migrations are steps in
`kansoku-core/src/Kansoku/Migrations.hs`; resource lists follow
`mori://shinzui/haskell-jitsurei/docs/api-relay-pagination`.


## Plan of Work

### M1: OR groups

Extend the filter parser: split a parameter on `|` into terms, each parsed as today; compile
a group to `(term1 OR term2 …)` and conjoin groups. Keep the eight-parameter limit and add a
limit of eight terms per group. Reject a value containing `|`.

### M2: Ad-hoc custom metrics

Implement `/metrics/custom` with parameters `events` (comma list), `aggregation`, `property`
(for `sum` and `average`), optional `denominatorEvents` and `denominatorAggregation` for a
ratio, plus the standard `from`, `to`, `timeGrain`, `groupBy` and `filter`. Build a
`MetricDefinition` (or `RatioMetric`) in the handler, validate it under the same rules as the
builtins (declared property for `property` and for `prop:` dimensions across all listed
events), and dispatch to the existing builders; `unique_count` reads the resolved view, the
others the raw table. Return 400 `invalid_metric` for an unsupported combination.

### M3: Saved definitions

Change `filters` to `[Text]` in `MetricDefinition`, migrate the builtins, and add a PostgreSQL
table `kansoku.metric_definitions` (`id`, `account_id`, `name` unique per account,
`definition jsonb`, timestamps). Add `/metric-definitions` CRUD under `MetricsAuth` with
Relay cursor pagination for the list, validating on write exactly as M2 does. Run a saved
metric with `GET /metrics/custom?metric=<name>&from&to[&groupBy&filter]`, where request
filters are conjoined with the saved ones and a request `groupBy` overrides the saved one.
Cohort references inside saved filters are allowed once
`docs/plans/41-behavioural-and-saved-cohorts.md` lands.

### M4: Contract, docs and ADR

Regenerate OpenAPI and the client; document "Custom metrics" and "OR filters" in the query
guide; add an ADR recording that saved metrics are definitions compiled under the builtin
rules, not stored SQL, and that the vision's `MetricDefinition` shape is now the wire shape.


## Concrete Steps

```bash
cabal run kansoku-migrate -- up
cabal test kansoku-core --test-options='--match "Custom"'
cabal test kansoku-core --test-options='--match "Filter"'
just openapi && just openapi-check
```

Example:

```bash
curl -s --get http://localhost:8080/metrics/custom -H "Authorization: Bearer $TOKEN" \
  --data-urlencode from=2026-07-01 --data-urlencode to=2026-08-01 \
  --data-urlencode events=document_shared,document_exported --data-urlencode aggregation=unique_count \
  --data-urlencode 'filter=prop:plan:eq:pro|prop:plan:eq:enterprise' --data-urlencode groupBy=prop:plan
```


## Validation and Acceptance

1. M1: `filter=prop:plan:eq:pro|prop:plan:eq:enterprise` equals the sum of the two single
   filters on a fixture with disjoint plans; a ninth term or a value with `|` returns 400.
2. M2: the ad-hoc unique count over two events equals a hand-written query; `sum` of a
   string property returns `invalid_metric`; a ratio returns a single unbucketed point.
3. M3: a saved definition runs by name and equals the ad-hoc call with the same parameters;
   a name of another account returns 404; builtin behaviour is unchanged after the `filters`
   migration (existing metric tests pass).
4. Bounds, codes and the account predicate test hold for the new builders.


## Idempotence and Recovery

The PostgreSQL migration is additive. Changing the builtin `filters` type is a source-level
change with no stored data. Ad-hoc metrics have no state.


## Interfaces and Dependencies

Hard dependencies: `docs/plans/26-bound-analytics-query-inputs-and-result-cardinality.md`
and `docs/plans/31-metric-property-filters-and-dual-grouping.md` Complete. Soft:
`docs/plans/41-behavioural-and-saved-cohorts.md`. Claims `/metric-definitions`, the
`invalid_metric` code, the `|` separator and the `MetricDefinition` wire shape.
