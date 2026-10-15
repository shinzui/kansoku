---
id: 41
slug: behavioural-and-saved-cohorts
title: "Behavioural and saved cohorts"
kind: exec-plan
created_at: 2026-10-15T15:14:00Z
intention: "intention_01m4zwwdrjesytazp5tb39fe3n"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-15T15:14:00Z
---

# Behavioural and saved cohorts

This ExecPlan is a living document. Update its living sections and durable ADRs as work
proceeds. It is a standalone plan, independent of
`docs/masterplans/5-act-on-rev-1-close-silent-loss-paths-add-metric-filters-and-enrich-web-analytics.md`,
that closes the cohort gap named in
`docs/reviews/2026-10-15-architecture-and-feature-set-against-comparable-products.md`
(finding E6) and in the follow-up assessment of 2026-10-15.


## Purpose / Big Picture

An operator or application will be able to name a set of users by what they did, such as
"used the export feature at least three times in the last thirty days and has not cancelled
in ninety", or by an uploaded list of user ids, save it under a name, and then use it in any
metric: "retention of power users", "revenue from the Q3 beta list", "page views by whether
the visitor is in the churn-risk cohort". Membership of a behavioural cohort is computed at
query time from the identity-resolved events, so it is always current and never needs a
refresh job; static cohorts live in ClickHouse next to the events they filter.


## Progress

- [ ] M1: Cohort definitions can be created, read, listed with cursor pagination, updated and deleted at `/cohorts` with a service token, stored in PostgreSQL per account.
- [ ] M2: `filter=cohort:eq:<id>` and `filter=cohort:neq:<id>` work on every filterable metric route for behavioural cohorts, and `groupBy=cohort:<id>` splits a series into `in` and `out`.
- [ ] M3: Static cohorts accept member uploads, and `GET /cohorts/{id}/members` lists current members of either kind with cursor pagination and a size endpoint.
- [ ] M4: OpenAPI, the Haskell client, the query guide and a new ADR describe the cohort model.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Definitions live in PostgreSQL (`kansoku.cohorts`), behavioural membership is
  computed at query time in ClickHouse, and static members live in ClickHouse
  (`analytics.cohort_members`).
  Rationale: Definitions are small, consistent records with CRUD semantics, which is what
  `kansoku.api_keys` already models in PostgreSQL; membership is analytics data that must join
  events cheaply. Mixpanel recomputes cohorts at query time; PostHog recomputes daily. Query
  time avoids a refresh job and staleness in a single-tenant deployment whose cost is bounded
  by the account's history.
  Date: 2026-10-15
- Decision: A behavioural definition is up to four conditions conjoined with AND, each
  `did` or `didNot` an event with `atLeast`/`atMost` distinct occurrences within
  `withinDays` before the query's `to` bound, optionally narrowed by event-property filters in
  the EP-31 grammar, plus optional trait conditions in the EP-40 `user:` grammar.
  Rationale: Covers the did, did-not, frequency and recency criteria PostHog, Mixpanel and
  Amplitude all expose; sequences, "first time" and "stopped doing" are deferred. Anchoring on
  `to` makes a query reproducible.
  Date: 2026-10-15
- Decision: Cohort references use the existing filter grammar with `eq` and `neq`, and
  cohort grouping yields exactly two groups.
  Rationale: No new parameter shape; generated clients and the point cap are unaffected.
  Date: 2026-10-15


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Metric routes are Servant NamedRoutes in `kansoku-api/src/Kansoku/Metrics/Api.hs`, compiled
to SQL in `kansoku-core/src/Kansoku/Metrics/Query.hs` with inputs validated in
`kansoku-core/src/Kansoku/Metrics/Query/Validate.hs` and bound as native ClickHouse
parameters ([ADR 3](../adr/0003-api-key-authentication-and-account-scoped-analytics.md)).
Exact user metrics read `analytics.events_resolved`, whose `canonical_user` is the resolved
identity ([ADR 4](../adr/0004-queryable-event-properties-and-identity-resolved-projection.md),
[ADR 5](../adr/0005-evidence-based-multi-signal-identity-resolution.md)). The `filter`
grammar `filter=<dimension>:<op>:<value>` and the dimension prefixes (`prop:`, and `user:`
for traits) are defined by `docs/plans/31-metric-property-filters-and-dual-grouping.md` and
`docs/plans/40-person-properties-set-and-set-once-user-traits.md`; this plan adds the
`cohort:` dimension. Bounded complete-or-error answers are
[ADR 9](../adr/0009-bounded-complete-aggregate-responses.md). PostgreSQL schema is an explicit
plan in `kansoku-core/src/Kansoku/Migrations.hs` built from `sqlMigration` steps; credentials
in `kansoku.api_keys` are the model for an account-scoped record. Service tokens
(`MetricsAuth`) are the credential for management routes. Resource-list endpoints in this
portfolio follow `mori://shinzui/haskell-jitsurei/docs/api-relay-pagination` (cursor pages);
MasterPlan 4 recorded that metric aggregates are the only exception, so `/cohorts` and
`/cohorts/{id}/members` paginate.

A "cohort" is a named set of users. "Behavioural" means defined by events; "static" means an
explicit list. No cross-repository ADR applies beyond the pagination guide.


## Plan of Work

### M1: Definitions and management routes

Add a PostgreSQL migration creating `kansoku.cohorts` (`id uuid`, `account_id text`,
`name text`, `kind text` in `behavioural|static`, `definition jsonb`, `created_at`,
`updated_at`, unique on `(account_id, name)`). Define `CohortDefinition` in
`kansoku-api/src/Kansoku/Cohort/Types.hs` with JSON instances matching the Decision Log
shape, validated on write: known event names are not required (undeclared events are
queryable), but property filters inside conditions must compile under EP-31's declared rule
and `withinDays` is 1 to 365. Add a `Cohorts` NamedRoutes record under `MetricsAuth`:
`POST /cohorts`, `GET /cohorts/{id}`, `GET /cohorts` with Relay cursor parameters,
`PUT /cohorts/{id}`, `DELETE /cohorts/{id}`, all account-scoped by the token's principal, with
problem codes `cohort_not_found` (404) and `invalid_cohort` (400).

### M2: Behavioural membership in metrics

Extend the filter and group-by compilers with the `cohort:` dimension. For `eq` and `neq`,
load the definition by id and account, verify it belongs to the caller, and compile a
membership subquery over `analytics.events_resolved` bounded by the account and by
`[to - withinDays, to)` per condition: `canonical_user IN (SELECT canonical_user … GROUP BY
canonical_user HAVING uniqExact(event_id) >= {n})`, `NOT IN` for `didNot`, intersected across
conditions, with trait conditions joined through EP-40's `user_traits`. Bind every literal as a
native parameter. `groupBy=cohort:<id>` emits `multiIf(member, 'in', 'out')` as the group key.
A cohort reference on a rollup fast path forces the resolved path, like other filters.

### M3: Static cohorts and member listing

Add a ClickHouse migration creating `analytics.cohort_members`
(`account_id, cohort_id, user_id, version DateTime64(3,'UTC'), present UInt8`) as
`ReplacingMergeTree(version)` ordered by `(account_id, cohort_id, user_id)`, and
`PUT /cohorts/{id}/members` accepting up to 50,000 user ids that replaces the list (absent
ids are written with `present = 0`). Static membership compiles to
`canonical_user IN (SELECT user_id … WHERE present = 1)` using `argMax(present, version)`.
Add `GET /cohorts/{id}/members?from&to` returning current members (behavioural computed for
the window, static read) with Relay cursor pagination ordered by user id, and
`GET /cohorts/{id}/size`.

### M4: Contract, docs and ADR

Regenerate OpenAPI and the client, document cohorts in `docs/guides/query-metrics.md`
("Cohorts") with the JSON shape and three examples, and add an ADR recording the storage
split, the query-time semantics anchored on `to`, and the deferred criteria.


## Concrete Steps

```bash
cabal run kansoku-migrate -- up
just ch-migrate
cabal test kansoku-core --test-options='--match "Cohort"'
just openapi && just openapi-check
```

Example:

```bash
curl -s -X POST http://localhost:8080/cohorts -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"power_users","kind":"behavioural","conditions":[{"did":"feature_used","atLeast":3,"withinDays":30,"filters":["prop:feature:eq:export"]},{"didNot":"subscription_cancelled","withinDays":90}]}'
curl -s --get http://localhost:8080/metrics/retention -H "Authorization: Bearer $TOKEN" \
  --data-urlencode from=2026-07-01 --data-urlencode to=2026-08-01 --data-urlencode "filter=cohort:eq:$COHORT_ID"
```


## Validation and Acceptance

1. M1: CRUD round trip; a definition with a fifth condition or `withinDays=400` returns 400
   `invalid_cohort`; a cohort of another account returns 404.
2. M2: over fixtures where user A exported three times and user B once, `filter=cohort:eq:`
   on `/metrics/users` counts A only; `neq` counts B; adding the `didNot` condition removes a
   user who cancelled; `groupBy=cohort:` returns `in` and `out` whose sum equals the unfiltered
   count; a cohort id from another account returns 404.
3. M3: uploading two ids then one id leaves one present member; the member list paginates
   with a cursor and the size endpoint agrees.
4. The account-predicate completeness test covers the membership subqueries; the point cap
   and EP-26 codes still apply.


## Idempotence and Recovery

Migrations are additive. Member uploads are full replacements and safe to repeat. Deleting a
cohort referenced by a saved metric definition (see
`docs/plans/44-custom-metric-definitions-and-or-filter-groups.md`) makes that metric return
`cohort_not_found`; document it.


## Interfaces and Dependencies

Hard dependencies: `docs/plans/26-bound-analytics-query-inputs-and-result-cardinality.md`
and `docs/plans/31-metric-property-filters-and-dual-grouping.md` Complete. Soft:
`docs/plans/40-person-properties-set-and-set-once-user-traits.md` (trait conditions) and
`docs/plans/32-time-aware-identity-bindings-and-bounded-resolution-cost.md` (resolution cost
of membership subqueries). Claims the `/cohorts` routes, the `cohort:` dimension, the
`kansoku.cohorts` and `analytics.cohort_members` objects, and the `cohort_not_found` and
`invalid_cohort` codes.
