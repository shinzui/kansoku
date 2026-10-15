---
id: 38
slug: single-tenant-consumption-guide-for-dashboards-and-experiments
title: "Single-tenant consumption guide for dashboards and experiments"
kind: exec-plan
created_at: 2026-10-15T13:44:34Z
intention: "intention_01m4zwwdrjesytazp5tb39fe3n"
master_plan: "docs/masterplans/5-act-on-rev-1-close-silent-loss-paths-add-metric-filters-and-enrich-web-analytics.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-15T13:44:34Z
---

# Single-tenant consumption guide for dashboards and experiments

This ExecPlan is a living document. Update its living sections and durable ADRs as work
proceeds. It is a child of
`docs/masterplans/5-act-on-rev-1-close-silent-loss-paths-add-metric-filters-and-enrich-web-analytics.md`
and acts on findings G1 and E5 (documentation half) and the documentation items in E1, E2,
E3 and E7 of
`docs/reviews/2026-10-15-architecture-and-feature-set-against-comparable-products.md`.


## Purpose / Big Picture

An owner-operator will be able to build dashboards in Grafana or Metabase and run experiment
statistics in GrowthBook without Kansoku shipping a UI or a statistics engine, by following a
guide that says which ClickHouse objects are stable, how to create a read-only role, and which
queries reproduce the HTTP endpoints' numbers. The query guide and OpenAPI descriptions will
state the semantics REV-1 found implicit: calendar weeks and months, "on day N" retention,
the range-length funnel window, sessions counted per bucket, and multi-variant users counted
in each variant.


## Progress

- [ ] M1: `docs/guides/consume-clickhouse.md` exists with the role recipe, the stable-object table, three worked queries that match the endpoints on the fixtures, and a Grafana datasource recipe.
- [ ] M2: The guide's GrowthBook section provides an assignment query and a fact-table query that GrowthBook accepts against the local stack.
- [ ] M3: `docs/guides/query-metrics.md` and the route descriptions in `kansoku-api/src/Kansoku/Metrics/Api.hs` state the five semantics; OpenAPI regenerates and the conformance tests pass.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: The stable read surface is `analytics.events_resolved` (seven columns, ADR 4),
  the rollups `dau`, `wau`, `page_views_by_route`, `daily_event_counts`,
  `experiment_exposures`, and the views `identity_bindings` and `identity_conflicts`.
  `events_raw` and `identity_signals` are documented as internal and may change shape.
  Rationale: The HTTP endpoints already treat these as contracts; naming them lets dashboards
  survive migrations.
  Date: 2026-10-15


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Kansoku ships no dashboard; the product vision lists one as later scope. The documentation
index is `docs/README.md`, adopter guides are under `docs/guides/`, and the generated
contracts are `docs/api/openapi.json` (regenerated with `just openapi`, checked with
`just openapi-check`) and `docs/contracts/events.json`. Route descriptions that feed OpenAPI
live in `kansoku-api/src/Kansoku/Metrics/Api.hs`. The semantics to document are implemented
in `kansoku-core/src/Kansoku/Metrics/Query.hs`: `toMonday` weeks and `toStartOfMonth`
months, retention offsets matched with `dateDiff(...) IN (...)`, the funnel window defaulting
to the range length capped at 90 days, sessions counted by event bucket, and experiment
conversion counting a multi-variant user in each variant
([ADR 6](../adr/0006-exposure-based-experiment-analytics.md)). ClickHouse objects are created
by `db/clickhouse/migrations/`; the seven-column view contract is in
[ADR 4](../adr/0004-queryable-event-properties-and-identity-resolved-projection.md). GrowthBook
reads a ClickHouse data source through an "experiment assignment query" returning an
identifier, a timestamp, an experiment id and a variation id, plus fact tables defined by SQL
with a timestamp and identifier column (GrowthBook documentation, retrieved 2026-10-14; verify
the current field names when implementing). Grafana's ClickHouse data source plugin and
Metabase's ClickHouse driver both connect with a ClickHouse user over the native or HTTP port.
No cross-repository ADR applies.


## Plan of Work

### M1: Consumption guide

Write `docs/guides/consume-clickhouse.md`. Sections: why direct access is the single-tenant
dashboard path; the role recipe (`CREATE USER kansoku_reader IDENTIFIED WITH sha256_password
BY '…'`, `GRANT SELECT ON analytics.events_resolved, analytics.dau, … TO kansoku_reader`, and
a `SETTINGS PROFILE` with `max_execution_time` and `max_memory_usage`); the stable-object
table with one line per object and its contract; three worked queries whose results must
equal the endpoints on the fixtures (daily active users from `dau`, a two-step
`windowFunnel` over `events_resolved` with the same account and window predicates, revenue by
`plan` via `getSubcolumn(properties_json, 'plan')`); a Grafana recipe (datasource, one panel
per query, the account literal as a dashboard variable); and a note that `account_id` must
appear in every query. Link it from `docs/README.md` and the query guide.

### M2: GrowthBook section

Add the assignment query over `events_raw` filtered to `experiment_viewed` returning
`canonical_user` (from `events_resolved`) as the identifier, `occurred_at`, the `experiment`
and `variant` subcolumns, and a fact table example for `payment_completed` with `amount`.
Explain the exact-versus-approximate identity note from ADR 6 and that GrowthBook's
multiple-exposure handling applies. Verify against a local GrowthBook container if
available; otherwise record the verification as pending in Progress rather than claiming it.

### M3: Semantics precision

In the query guide and the route descriptions, state the five semantics in one sentence
each, placed where the parameter is introduced. Regenerate OpenAPI and run the conformance
tests; the committed artifact changes only in description strings.


## Concrete Steps

```bash
just openapi && just openapi-check
cabal test kansoku-core --test-options='--match "OpenApi"'
```

With the stack running and fixtures loaded, run each worked query with `clickhouse-client
--port 9000 --query` and compare with the corresponding `curl` against `just run`.


## Validation and Acceptance

1. M1: each worked query's result equals the endpoint's `value` for the same range on the
   fixtures; the reader role can run them and cannot select from `kansoku`-internal objects
   not granted.
2. M2: the assignment query returns one row per exposure with the four columns GrowthBook
   expects.
3. M3: `just openapi-check` passes after regeneration, and a reader of the query guide can
   find each semantic sentence by searching for "calendar", "on day", "capped at 90",
   "spans", and "each variant".


## Idempotence and Recovery

Documentation and description strings only; re-running regeneration is idempotent.


## Interfaces and Dependencies

No hard dependencies; this plan can run first. Soft dependency on every metric-semantics
child (`docs/plans/35-…`, `docs/plans/36-…`, `docs/plans/34-…`) in that their landing
requires updating the sentences this plan writes; each of those plans owns its own
documentation update. The stable-object list should be recorded in ADR 4 as the read
contract.
