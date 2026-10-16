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
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-16T12:20:29Z
      mode: "implement"
      note: "Implement OR filter groups and ad-hoc and saved custom metrics"
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

- [x] (2026-10-16) M1: Bounded shorthand and JSON OR groups preserve repeated AND semantics. Native fixtures prove disjoint-plan equivalence, conjoined conditions and binding safety; malformed/ninth terms return invalid_filter. Four native examples passed, plus deterministic scope/grammar checks.
- [x] (2026-10-16) M2: Ad-hoc custom metrics execute count, unique_count, sum, average and ratios. Owned public fixtures prove multi-event resolved uniques, replay-safe aggregates, unbucketed ratios, numeric validation, date limits and account isolation; native fixtures match multi-event uniques against independent SQL and prove mixed ratio aggregations and query resource behavior.
- [x] (2026-10-16) M3: Account-scoped definition CRUD, bidirectional cursor walks and named execution pass owned public roundtrips, including defaults/overrides, per-component ratio filters, cohorts/traits, duplicate names, deletion and foreign-account 404s. The deterministic suite passes 378 core examples, 20 client examples and four probes.
- [x] (2026-10-16) M4: Shared wire types, generated-client roundtrips, regenerated OpenAPI and the query guide describe definitions and limits. OpenAPI freshness/lint, event-contract freshness, formatting, telemetry lifecycle checks and strict ADR validation (20 concepts) pass; ADR-20 records durable execution and OR semantics.


## Surprises & Discoveries

The baseline implements bounded JSON filters, not the colon grammar assumed by the
original plan. JSON accepts literal pipes and existing tests depend on that behavior.
The implementation preserves it and adds shorthand OR groups plus a non-nested JSON
`or` group for typed clients. Only shorthand rejects an ambiguous literal pipe.

The old ratio builder always counted unique subjects, even for components declaring
Count. It now compiles each component's count, unique count, sum or average explicitly.
Saved component filters must participate in trait/cohort discovery before source selection;
otherwise count/sum queries can reference trait columns absent from their raw source.

Plan 41 has landed: saved cohort references are supported immediately. The first owned
public roundtrip caught a missing custom entry in request validation: Servant's fallback
returned malformed_request for malformed filters instead of invalid_filter. The corrected
entry and regression checks preserve the stable filter error boundary.


## Decision Log

- Decision: OR is expressed inside a single `filter` parameter by `|` between full
  `dimension:op:value` terms; separate `filter` parameters stay conjoined. Values may not
  contain an ambiguous literal `|`; use the existing JSON form for that value (clarified
  2026-10-16). Malformed shorthand returns `invalid_filter`.
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
- Decision: Preserve the existing JSON filter syntax and arbitrary JSON string values;
  accept `|` shorthand and JSON `{"or":[term,...]}` with no nested groups. Canonical
  groupBy values in definitions are full dimension names, including `prop:`.
  Rationale: Existing clients retain their scalar encoding while typed clients can express
  the same bounded alternatives. Builtin feature grouping migrates to `prop:feature`.
  Date: 2026-10-16
- Decision: `aggregation=ratio` defaults its numerator to unique_count; another aggregation
  with denominatorEvents selects that numerator aggregation. denominatorAggregation defaults
  to unique_count. Numeric components share the ad-hoc property parameter. Saved ratios
  express each component independently; ratios reject timeGrain and property grouping.
  Rationale: The original ad-hoc parameters need an explicit way to select all supported
  component aggregations. Definitions reuse the same numeric validation and native compiler.
  Date: 2026-10-16
- Decision: Move definition wire types to kansoku-api and re-export them from kansoku-core.
  Store definitions as an untagged simple/ratio JSON union; normalize custom dispatch names
  internally and preserve the user's name only in storage and responses.
  Rationale: Generated clients share the served body shape and user labels cannot invoke
  special builtin sessions or ordered-conversion code paths.
  Date: 2026-10-16


## Outcomes & Retrospective

All four milestones are implemented. Applications can compute ad-hoc metrics, save and
manage account-scoped definitions, run them by name with overrides, and express bounded
alternatives without merging results client-side. The additive PostgreSQL migration and
shared wire types are exercised by the owned public acceptance runner. Generated-client
and existing builtin tests pass after the filter-list migration. Final evidence: 378 core
and 20 client examples with zero failures, four production probes, four required native
filter examples with zero failures/pending, and the full owned custom-metric HTTP
roundtrip. OpenAPI/event-contract freshness, OpenAPI lint (no errors), formatting,
telemetry lifecycle checks and strict ADR validation (20 concepts) pass. The same public
roundtrip is wired into the existing packaged acceptance runner; that full packaged
runner was not rerun for this plan.

The key compatibility lesson is to inspect the existing wire grammar and aggregate semantics
before reusing internal records: preserving JSON avoids breaking arbitrary string values,
and explicit component aggregation prevents ratios from silently ignoring definitions.
Saved filters must enter identity, trait and cohort discovery before compilation. These
constraints are distilled into ADR-20. No feature milestone remains outstanding.


## Context and Orientation

`kansoku-api/src/Kansoku/Metrics/Definition.hs` defines `MetricDefinition` (`name`,
`description`, `eventNames`, `aggregation` of `Count | UniqueCount | Sum | Average | Ratio`,
`aggregationProperty`, `filters :: [Text]`, `groupBy`, `timeGrain`) and `RatioMetric`
(numerator and denominator definitions), both with JSON instances;
`kansoku-core/src/Kansoku/Metrics/Registry.hs` holds the builtin map (`events`, `page_views`,
`sessions`, `active_users`, `new_users`, `returning_users`, `feature_adoption`, `revenue`,
and the ratios `conversion_rate`, `activation_rate`, `retention`). The handler in
`kansoku-core/src/Kansoku/Metrics/Handler.hs` resolves a route to a builtin and runs the
matching builder in `kansoku-core/src/Kansoku/Metrics/Query.hs`; the `custom` route in
`kansoku-api/src/Kansoku/Metrics/Api.hs` carries the standard metric parameters plus
custom-definition arguments. `kansoku-core/src/Kansoku/Metrics/Custom.hs` validates them
before the shared builders execute them. Filters and their native bound parameters
come from
`docs/plans/31-metric-property-filters-and-dual-grouping.md`; declared-property rules from
[ADR 4](../adr/0004-queryable-event-properties-and-identity-resolved-projection.md); bounds from
[ADR 9](../adr/0009-bounded-complete-aggregate-responses.md). PostgreSQL migrations are steps in
`kansoku-core/src/Kansoku/Migrations.hs` (0006 creates metric_definitions). Resource CRUD is in
`kansoku-core/src/Kansoku/Metrics/DefinitionHandler.hs` and
`kansoku-core/src/Kansoku/Metrics/DefinitionStore.hs`; routes
are in `kansoku-api/src/Kansoku/Metrics/DefinitionApi.hs`. [ADR-20](../adr/0020-custom-metric-definitions-and-bounded-or-filters.md)
records the wire shape and bounded OR behavior. Resource lists follow
`mori://shinzui/haskell-jitsurei/docs/api-relay-pagination`.


## Plan of Work

### M1: OR groups

Extend the filter parser: split a parameter on `|` into terms, each parsed as today; compile
a group to `(term1 OR term2 …)` and conjoin groups. Keep the eight-parameter limit and add a
limit of eight terms per group. Preserve JSON terms and accept non-nested JSON OR groups;
reject ambiguous shorthand pipe values with invalid_filter.

### M2: Ad-hoc custom metrics

Implement `/metrics/custom` with parameters `events` (comma list), `aggregation`, `property`
(for `sum` and `average`), optional `denominatorEvents` and `denominatorAggregation` for a
ratio, plus the standard `from`, `to`, `timeGrain`, `groupBy` and `filter`. Build a
`MetricDefinition` (or `RatioMetric`) in the handler, validate it under the same rules as the
builtins (declared property for `property` and for `prop:` dimensions across all listed
events), and dispatch to the existing builders. Unique counts and ratios use resolved
events; other aggregations use canonical raw events unless trait/cohort selection requires
the resolved source. Ratios are unbucketed, with independently aggregated components. Return 400 `invalid_metric` for an unsupported combination.

### M3: Saved definitions

Use `filters :: [Text]` in `MetricDefinition`, migrate the builtins, and add a PostgreSQL
table `kansoku.metric_definitions` (`id`, `account_id`, `name` unique per account,
`definition jsonb`, timestamps). Add `/metric-definitions` CRUD under `MetricsAuth` with
Relay cursor pagination for the list, validating on write exactly as M2 does. Run a saved
metric with `GET /metrics/custom?metric=<name>&from&to[&groupBy&filter]`, where request
filters are conjoined with the saved ones and a request `groupBy` overrides the saved one.
Cohort references inside saved filters use the completed
`docs/plans/41-behavioural-and-saved-cohorts.md` implementation.

### M4: Contract, docs and ADR

Regenerate OpenAPI and the client; document "Custom metrics" and "OR filters" in the query
guide; add an ADR recording that saved metrics are definitions compiled under the builtin
rules, not stored SQL, and that the vision's `MetricDefinition` shape is now the wire shape.


## Concrete Steps

```bash
nix develop -c cabal build all --enable-tests
nix develop -c just deterministic-test
nix develop -c just custom-metrics-acceptance
nix develop -c just openapi
nix develop -c just openapi-check
nix develop -c just openapi-lint
nix develop -c okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
```

Example:

```bash
curl -s --get http://localhost:8080/metrics/custom -H "Authorization: Bearer $TOKEN" \
  --data-urlencode from=2026-07-01 --data-urlencode to=2026-08-01 \
  --data-urlencode events=payment_completed --data-urlencode aggregation=unique_count \
  --data-urlencode 'filter=prop:plan:eq:pro|prop:plan:eq:enterprise' --data-urlencode groupBy=prop:plan
```


## Validation and Acceptance

Run these commands from the repository root. `custom-metrics-acceptance` owns disposable
PostgreSQL and ClickHouse instances, applies migrations, runs the native filter fixtures
and public custom-definition roundtrips, and fails zero/pending native evidence. It must
report zero failures and the custom-metric success message. No ambient database is used.

1. M1: `filter=prop:plan:eq:pro|prop:plan:eq:enterprise` equals the sum of the two single
   filters on a fixture with disjoint plans; a ninth term or an ambiguous shorthand value with `|` returns 400 invalid_filter; JSON preserves literal pipes.
2. M2: the ad-hoc unique count over two events equals a hand-written query; `sum` of a
   string property returns `invalid_metric`; a ratio returns a single unbucketed point.
3. M3: a saved definition runs by name and equals the ad-hoc call with the same parameters;
   a name of another account returns 404; builtin behaviour is unchanged after the `filters`
   migration (existing metric tests pass).
4. Bounds, codes and the account predicate test hold for the new builders.


## Idempotence and Recovery

The PostgreSQL migration is additive. Changing the builtin `filters` type is a source-level
change with no pre-existing stored definition data. The core module is re-exported for
existing imports. The owned acceptance runner proves first application; migration tests
verify strict checking and no-work reapplication. Ad-hoc metrics have no state.


## Interfaces and Dependencies

Hard dependencies: `docs/plans/26-bound-analytics-query-inputs-and-result-cardinality.md`
and `docs/plans/31-metric-property-filters-and-dual-grouping.md` Complete. Soft:
`docs/plans/41-behavioural-and-saved-cohorts.md`. Claims `/metric-definitions`, the
`invalid_metric` code, the `|` separator and the `MetricDefinition` wire shape.

Revision note (2026-10-16): Preserve the established JSON grammar, specify the ad-hoc ratio
component defaults, publish shared definition wire types, and include already-landed cohorts.
The implementation and acceptance commands above reflect these compatibility findings.
