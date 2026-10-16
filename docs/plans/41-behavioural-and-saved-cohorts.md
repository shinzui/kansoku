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
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-16T10:36:12Z
      mode: "implement"
      note: "Implement cohort management, query-time membership and public contract"
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

- [x] M1 (2026-10-16): Account-scoped definition CRUD and bidirectional Relay pagination pass the public roundtrip, including invalid bounds, a fifth condition, and foreign-account 404s.
- [x] M2 (2026-10-16): Behavioural eq/neq selection and in/out grouping pass across every implemented metric family, including strict funnels and experiments; fixtures cover negative/trait criteria, identity-resolved pre-login activity, replay and exclusive lookback bounds. Account-scope compiler checks pass.
- [x] M3 (2026-10-16): Static replacements, member pages and size agree for two-to-one uploads and a 50,000-member upload/retry/clear. Fenced user erasure removes static facts. The Nix-packaged server, migrator and administrator pass the same owned-database proof.
- [x] M4 (2026-10-16): OpenAPI and typed client compile; generated-artifact, OpenAPI lint, formatting and strict ADR gates pass. Query guide and ADR-19 document the contract. Regression evidence is 369 core examples, 19 client examples and four production probe tests, all passing.


## Surprises & Discoveries

The shipped filter grammar is URL-decoded JSON, rather than the older colon syntax in
this plan. Cohorts use `{"dimension":"cohort","op":"eq","value":"<uuid>"}`; the
plan's cohort-only shorthand remains accepted. Condition property filters use JSON objects.

The public `analytics.events_resolved` view is a frozen seven-column reader contract.
Membership uses the existing bounded `events_resolved_http` path and extends the
connection-owned identity snapshot to include cohort lookbacks. Widened retention and
session scopes must not move the original cohort `to` anchor.
`mori://shinzui/relay-pagination` 0.1.1.2 was verified against Hackage and upstream tags before adding the published packages. The telemetry
route classifier needs a transparent RelayPage instance.

The Nix package set initially selected codecs incompatible with the existing Hasql 1.10
runtime. Released `mori://hasql/hasql/packages/hasql-dynamic-statements` 0.5.1.2 and
`mori://hasql/hasql/packages/hasql-implicits` 0.2.0.3 were verified against Hackage and
upstream tags and aligned in both build paths. Test-only upstream container dependencies
are omitted from the Nix codec derivation, whose checks are disabled.

The 50,000-member acceptance case needs set-based deduplication and grouped replacement
rows; repeated linear membership scans per uploaded ID would make replacement quadratic.
The final native proof passes upload, retry and clear at the advertised limit.


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
  cohort grouping uses the two labels `in` and `out`.
  Rationale: No new parameter shape; generated clients and the point cap are unaffected.
  Date: 2026-10-15

- Decision: Cohorts target identified users, and member endpoints return explicit user IDs.
  Behavioural membership uses resolved pre-login activity; anonymous-only subjects are out.
  Behavioural member lists use identified users observed in the requested from/to window;
  static lists contain every present uploaded ID independent of event history.
  Rationale: Keeps the member list/size and static-ID contract aligned, without confusing
  cookie text with a user ID. Definitions are anchored on the original to bound, including
  negative-only and zero-occurrence conditions.
  Date: 2026-10-16
- Decision: Serialize member replacements, definition updates and deletion with a PostgreSQL
  transaction advisory lock per account/cohort; write one ClickHouse insert with versions
  strictly greater than the prior cohort maximum. Keep kind immutable, and remove static
  member facts during fenced user erasure.
  Rationale: Full replacements must remain repeatable across server processes and cannot
  depend on merge timing or leave user identifiers outside the existing erasure protocol.
  Date: 2026-10-16


## Outcomes & Retrospective

All four milestones are complete. Cohorts are reusable across implemented metrics, with
current identity-aware behavioural membership and explicit static lists. The public
management/member contract, typed Haskell client, migrations, guide and durable decision
are delivered. No refresh worker is needed. Deferred sequence/first-ever/stopped-doing
criteria remain outside this plan.

Final validation ran `cabal build all --enable-tests`, the deterministic regression runner,
`just openapi-check`, `just openapi-lint`, the non-mutating formatter check, strict ADR
validation, and Nix builds of the server and client. `scripts/cohorts_acceptance.py` passed
against both Cabal binaries and Nix-packaged binaries in fresh owned stores, including
50,000-member replacement and user erasure. Packaged proof evidence is under
`.dev/acceptance/cohort-2afofp08`; these private runtime artifacts are not committed.

The durable lessons are recorded in
[ADR-19](../adr/0019-saved-query-time-cohorts-and-static-membership.md): anchor membership
before widening metric scopes, preserve whole-session attribution, namespace subjects,
serialize cross-store replacements, and include static identifiers in erasure. Current
traits, identity evidence and definition changes intentionally affect historical answers;
member pages are current reads without a cross-request snapshot.


## Context and Orientation

Metric routes are Servant NamedRoutes in `kansoku-api/src/Kansoku/Metrics/Api.hs`, compiled
to SQL in `kansoku-core/src/Kansoku/Metrics/Query.hs` with inputs validated in
`kansoku-core/src/Kansoku/Metrics/Query/Validate.hs` and bound as native ClickHouse
parameters ([ADR 3](../adr/0003-api-key-authentication-and-account-scoped-analytics.md)).
Exact HTTP metrics read the private bounded `analytics.events_resolved_http` source;
`canonical_user` is the resolved identity, while the public `analytics.events_resolved`
reader view retains its frozen projection ([ADR 4](../adr/0004-queryable-event-properties-and-identity-resolved-projection.md),
[ADR 5](../adr/0005-evidence-based-multi-signal-identity-resolution.md)). The `filter`
grammar is a URL-decoded JSON object with `dimension`, `op` and `value`; prefixes
`prop:` and `user:` select event properties and current traits. These dimensions are defined by `docs/plans/31-metric-property-filters-and-dual-grouping.md` and
`docs/plans/40-person-properties-set-and-set-once-user-traits.md`; this plan adds the
`cohort` filter dimension and `cohort:<uuid>` grouping. Bounded complete-or-error answers are
[ADR 9](../adr/0009-bounded-complete-aggregate-responses.md). PostgreSQL schema is an explicit
plan in `kansoku-core/src/Kansoku/Migrations.hs` built from `sqlMigration` steps; credentials
in `kansoku.api_keys` are the model for an account-scoped record. Service tokens
(`MetricsAuth`) are the credential for management routes. Resource-list endpoints in this
portfolio follow `mori://shinzui/haskell-jitsurei/docs/api-relay-pagination` (cursor pages);
MasterPlan 4 recorded that metric aggregates are the only exception, so `/cohorts` and
`/cohorts/{id}/members` paginate.

`kansoku-api/src/Kansoku/Cohort/Types.hs` owns the JSON payloads;
`kansoku-api/src/Kansoku/Cohort/Api.hs` declares routes. Definition persistence is in
`kansoku-core/src/Kansoku/Cohort/Store.hs`, membership compilation in
`kansoku-core/src/Kansoku/Cohort/Query.hs`, native member queries in
`kansoku-core/src/Kansoku/Cohort/Members.hs`, and management handlers in
`kansoku-core/src/Kansoku/Cohort/Handler.hs`. Metrics load definitions through
`withCohorts` in `kansoku-core/src/Kansoku/Metrics/Handler.hs` and carry compiled membership
on `QueryRequest` before any historical/session scope changes.

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

Extend the filter compiler with dimension `cohort`, UUID operand and eq/neq, and the
group-by compiler with the `cohort:<uuid>` dimension. For `eq` and `neq`,
load the definition by id and account, verify it belongs to the caller, and compile a
membership subquery over `analytics.events_resolved_http` bounded by the account and by
`[to - withinDays, to)` per condition: `canonical_user IN (SELECT canonical_user … GROUP BY
canonical_user HAVING uniqExact(event_id) >= {n})`, `NOT IN` for `didNot`, intersected across
conditions, with trait conditions joined through EP-40's `user_traits`. Bind every literal as a
native parameter. `groupBy=cohort:<id>` emits `if(member, 'in', 'out')` as the group key.
A cohort reference on a rollup fast path forces the resolved path, like other filters.

### M3: Static cohorts and member listing

Add a ClickHouse migration creating `analytics.cohort_members`
(`account_id, cohort_id, user_id, version DateTime64(3,'UTC'), present UInt8`) as
`ReplacingMergeTree(version)` ordered by `(account_id, cohort_id, user_id)`, and
`PUT /cohorts/{id}/members` accepting up to 50,000 user ids that replaces the list (absent
ids are written with `present = 0`). Static membership compares namespaced canonical users
against uploaded explicit IDs using
`argMax(present, version)`, without relying on background merges.
Add `GET /cohorts/{id}/members?from&to` returning current members (behavioural computed for
the window, static read) with Relay cursor pagination ordered by user id, and
`GET /cohorts/{id}/size`.

### M4: Contract, docs and ADR

Regenerate OpenAPI and the client, document cohorts in `docs/guides/query-metrics.md`
("Cohorts") with the JSON shape and three examples, and add an ADR recording the storage
split, the query-time semantics anchored on `to`, and the deferred criteria.


## Concrete Steps

Run from the repository root inside `nix develop`. `just cohorts-acceptance` builds the
components and runs the public proof in fresh owned databases. To repeat the packaged
proof, set `KANSOKU_COHORT_SERVER`, `KANSOKU_COHORT_MIGRATE` and
`KANSOKU_COHORT_ADMIN` to the corresponding executables from the output of
`nix build .#kansoku-server --no-link --json`, then run the same Python script. The migration
commands below apply to the configured development stores.

```bash
cabal run kansoku-migrate -- up
just ch-migrate
cabal test kansoku-core:kansoku-core-test --test-options='--match Cohort'
python3 scripts/cohorts_acceptance.py
just openapi && just openapi-check
```

Example:

```bash
curl -s -X POST http://localhost:8080/cohorts -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"power_users","kind":"behavioural","conditions":[{"did":"feature_used","atLeast":3,"withinDays":30,"filters":[{"dimension":"prop:feature","op":"eq","value":"export"}]},{"didNot":"subscription_cancelled","withinDays":90}]}'
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


Implementation revision (2026-10-16): reconciled the shipped JSON grammar, private resolved
source, identified-user member population and current-trait support; documented serialized
static replacement and erasure integration. Acceptance remains the four milestones above,
with native boundary, maximum-size and packaged-binary proofs added to verify the existing
contract.
