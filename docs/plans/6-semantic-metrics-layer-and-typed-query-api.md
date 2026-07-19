---
id: 6
slug: semantic-metrics-layer-and-typed-query-api
title: "Semantic metrics layer and typed query API"
kind: exec-plan
created_at: 2026-07-01T16:04:44Z
intention: "intention_01kwf425fxenc904ear54cr2n7"
master_plan: "docs/masterplans/1-kansoku-analytics-service-mvp.md"
---

# Semantic metrics layer and typed query API

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Kansoku (観測, "observation") is a first-party analytics service. By the time you start this
plan, events already flow into a ClickHouse table named `analytics.events_raw`, and a set of
pre-aggregated helper tables ("rollup views": `analytics.dau`, `analytics.wau`,
`analytics.page_views_by_route`, `analytics.daily_event_counts`) plus an identity lookup table
(`analytics.identity_map`, which is *not* a rollup — it maps observed user ids to canonical
ones) already exist. The rollups are `AggregatingMergeTree` tables: their `users`/`views`/
`events` columns hold *partial aggregation states* (ClickHouse type
`AggregateFunction(uniqExact, String)`), not finished numbers, so every read of them must
finish the aggregation with `uniqExactMerge(...)` under a `GROUP BY` (explained fully in
Context and Orientation). What is still missing is a way for other applications — dashboards,
product UI widgets, reports, automated summaries — to ask for a metric like "how many active
users did we have per day last week" without writing raw SQL against ClickHouse and without
each dashboard inventing its own slightly-different definition of "active user".

After this change, a person running the Kansoku server can make plain HTTP requests like:

```bash
curl -s 'http://localhost:8080/metrics/events?from=2026-06-01&to=2026-06-08&timeGrain=day'
```

and receive a typed JSON document with one number per day, computed by a single, shared
definition of the metric. The same definition of "active users" is reused by every endpoint,
so two dashboards can never disagree about what the number means. This is the "semantic
metrics layer": a metric is defined **once**, in Haskell, as data, and then compiled to a
ClickHouse query and served over HTTP.

Concretely, this plan delivers two things a novice can see working:

1. A library of metric definitions (`Kansoku.Metrics.*`) and a query compiler
   (`Kansoku.Metrics.Query`) that turns a metric definition plus a time range into a ClickHouse
   query and runs it, returning typed rows.
2. A set of HTTP endpoints under `GET /metrics/*` (added to the existing servant web server)
   that expose those metrics. Seven endpoints are **fully implemented** and return correct
   aggregates you can verify by hand (`/metrics/events`, `/metrics/page-views`,
   `/metrics/sessions`, `/metrics/users`, `/metrics/funnel`, `/metrics/retention`,
   `/metrics/conversion`); four more are present but return a typed HTTP 404
   `not_implemented` envelope (`/metrics/acquisition`, `/metrics/feature-adoption`,
   `/metrics/organizations`, `/metrics/custom`). The stub endpoints exist so that clients and
   the OpenAPI surface are stable from day one, and so a later plan only has to fill in the
   handler body, not add routing.

The observable proof of success: insert a small, known set of fixture events, build the
rollups, `curl` each of the seven implemented endpoints, and see JSON whose numbers match
values you computed by hand from the fixtures.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Read the prerequisite context: confirm `analytics.events_raw`, the `EventRow` type, and
  the rollup views exist (Milestone 0).
- [x] Create `Kansoku.Api.Metrics` in the shared `kansoku:kansoku-api` sub-library with the
  `TimeGrain` sum type (JSON + `FromHttpApiData` instances) and the `MetricPoint`/`MetricResult`
  response DTOs (Milestone 1).
- [x] Add `Kansoku.Metrics.Definition` (main library) with the `Aggregation` sum type and the
  `MetricDefinition` record — importing `TimeGrain` from `Kansoku.Api.Metrics` — plus their JSON
  instances (Milestone 1).
- [x] Add `Kansoku.Metrics.Registry` with the twelve built-in metrics (Events, Page Views,
  Active Users, New Users, Returning Users, Conversion Rate, Activation Rate, Retention,
  Feature Adoption, Revenue, Search Success Rate, Funnel Completion Rate) (Milestone 1).
- [x] Add `Kansoku.Query` with `QueryRequest`, the pure SQL builder `buildSQL`, and the executor
  `run` taking EP-3's `Connection` (Milestone 1).
- [x] Write unit tests over `buildSQL` that assert exact generated SQL for representative
  metrics/requests — including the `uniqExactMerge`-based rollup reads; make them green
  (Milestone 1).
- [x] Extend `Kansoku.Config` and the effectful runtime so the metrics handlers have read
  access to ClickHouse, following EP-1's config pattern (Milestone 2).
- [x] Declare the servant `MetricsAPI` type in `Kansoku.Api.Metrics`, then add
  `Kansoku.Metrics.Handler` with `metricsServer`, hoisted from `Eff` into servant's `Handler`,
  and mount it in the existing web application (Milestone 2).
- [x] Fully implement `/metrics/events`, `/metrics/page-views`, `/metrics/users` and verify
  each against fixtures with `curl` (Milestone 2).
- [x] Fully implement `/metrics/funnel` and `/metrics/conversion` and verify against fixtures
  (Milestone 3).
- [x] Fully implement `/metrics/sessions` (unique `session_id` counts over `events_raw`) and
  `/metrics/retention` (query-time cohort computation over `events_resolved`), extend the
  QuerySpec tests, and verify both against fixtures with `curl` (Milestone 4).
- [x] Return HTTP 501 with a documented JSON body for `/metrics/acquisition`,
  `/metrics/feature-adoption`, `/metrics/organizations`, `/metrics/custom` (Milestone 4).
- [x] Update the MasterPlan Progress rows for EP-6 and write the Outcomes & Retrospective entry.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- ClickHaskell's dynamic result decoding mis-associated multi-column aggregate rows in live
  validation: buckets and values from the same ClickHouse row did not stay paired. The executor
  now wraps generated metric SQL in a one-column `line` select, decodes that single
  tab-delimited `String`, and sorts the parsed rows in Haskell.
- The local ClickHouse server raised `std::bad_alloc` in LLVM/JIT paths while serving the small
  funnel and retention API queries. Appending
  `SETTINGS compile_expressions = 0, compile_sort_description = 0` to the read wrapper avoids
  those compilation paths and made the live validation stable.
- The EP-6 fixture SQL is now checked in as `db/clickhouse/fixtures/ep6_fixtures.sql` with a
  `just ch-fixtures-ep6` recipe. Before this, the plan embedded the fixture inline, which made
  repeatable HTTP validation too easy to drift.


## Decision Log

Record every decision made while working on the plan.

- Decision (SUPERSEDED 2026-07-01 for `/metrics/retention` and `/metrics/sessions` — see the
  two user scope decisions later in this log): The MVP fully implements exactly five endpoints —
  `/metrics/events`, `/metrics/page-views`, `/metrics/users`, `/metrics/funnel`,
  `/metrics/conversion` — and stubs the remaining six (`/metrics/sessions`, `/metrics/retention`,
  `/metrics/acquisition`, `/metrics/feature-adoption`, `/metrics/organizations`,
  `/metrics/custom`) with HTTP 501.
  Rationale: These five exercise every distinct machinery path the query compiler needs —
  a plain `count` over `events_raw` (events), a read of a pre-aggregated rollup view
  (page-views), an identity-resolved `unique_count` (users / DAU-WAU), a multi-step sequence
  (funnel), and a `ratio` of two event sets (conversion). Proving all five proves the compiler
  end-to-end. The six stubbed endpoints are either variations that reuse the exact same
  machinery once more rollups exist (acquisition = events grouped by UTM; feature-adoption =
  identity-resolved unique_count filtered to a feature; organizations = users grouped by
  organization) or need aggregate infrastructure not built in this phase (session duration,
  retention cohorts, arbitrary user-supplied metric bodies in `custom`). Stubbing keeps the
  MVP tight while freezing the HTTP surface so later work is additive.
  Date: 2026-07-01

- Decision: Keep the `MetricDefinition` record faithful to the TypeScript shape in
  `docs/initial-spec.md` (name, description, eventNames, aggregation, filters, groupBy,
  timeGrain), and represent "ratio" metrics that need two distinct event sets (e.g. Conversion
  Rate = completed / started) with a separate `RatioMetric` wrapper in the registry rather than
  by adding numerator/denominator fields to `MetricDefinition`.
  Rationale: The spec's `MetricDefinition` has a single `eventNames` list and a single
  `aggregation`, so a two-population ratio does not fit it without distorting the contract.
  A thin wrapper keeps `MetricDefinition` a faithful mirror of the spec (important because
  EP-2's event JSON and this metric JSON are both normative contracts) while still expressing
  ratios cleanly.
  Date: 2026-07-01

- Decision: Compile every metric to SQL through ClickHaskell's `unsafeMkSelect` returning a
  single fixed result-row shape (`bucket`, `group_key`, `value`), rather than trying to derive
  a distinct type-level column list per metric.
  Rationale: ClickHaskell's type-safe `fromTable`/`fromView` selects a statically-known column
  list, but our aggregate queries have computed columns (`toStartOfHour(...)`, `count()`,
  `uniqExact(...)`) whose names/shape vary with the request (time grain, group-by). Collapsing
  every metric to a uniform three-column result (a time bucket, an optional group key, a
  numeric value) lets one Haskell row type (`AggRow`) decode every metric, and makes the SQL
  builder a plain, unit-testable `MetricDefinition -> QueryRequest -> Text` function. The SQL
  text is what we assert in tests, so correctness is visible without a database.
  Date: 2026-07-01

- Decision: For unique-user counts, resolve identity by reading EP-5's
  `analytics.events_resolved` view (which resolves each event to a `canonical_user` via the
  `analytics.identity_map` join over `events_raw FINAL`) rather than re-implementing the join
  here; for other dedup-sensitive counts that read `events_raw` directly, dedup on
  `event_id` (either `count(DISTINCT event_id)` or `... FINAL`, matching EP-5's documented
  approach) rather than assuming rows are unique.
  Rationale: The ingestion boundary is at-least-once (a replayed batch re-inserts rows with the
  same `event_id`), so naive `count()` over-counts. EP-3 stores events in a `ReplacingMergeTree`
  keyed on `event_id`; EP-5 documents resolving duplicates with `FINAL`/dedup aggregation. This
  plan follows that so metric numbers are correct even after a replay.
  Date: 2026-07-01

- Decision: Prefer reading EP-5's rollup views (`analytics.dau`, `analytics.wau`,
  `analytics.page_views_by_route`, `analytics.daily_event_counts`) for the metrics they cover,
  and fall back to `events_raw` for ad-hoc shapes.
  Rationale: The rollups are pre-aggregated and small, so serving DAU/WAU and page-views from
  them is far cheaper than scanning `events_raw`, and it reuses EP-5's already-correct
  identity-resolved definitions. `events_raw` is used only where no matching rollup exists
  (the events count endpoint with arbitrary time grain, funnels, conversion).
  Date: 2026-07-01

- Decision: Every rollup read finishes the aggregation with `uniqExactMerge(...)` under a
  `GROUP BY` on the rollup's key columns (`day` for `analytics.dau`; `week` for `analytics.wau`;
  `day, route` — or just `day` when not grouping by route — for
  `analytics.page_views_by_route`), never a bare `SELECT toFloat64(users) ...`.
  Rationale: EP-5's rollups are `AggregatingMergeTree` tables whose `users`/`views` columns have
  ClickHouse type `AggregateFunction(uniqExact, String)` — a partial aggregation *state* (an
  opaque serialized set), not a number — and the table's data parts are not guaranteed to be
  merged, so one key can appear in several parts at read time. Reading the column without a
  `-Merge` combinator is a type error, and skipping the `GROUP BY` would return one partial row
  per unmerged part. This fixed a validation blocker: the earlier draft read
  `toFloat64(users)` with no `GROUP BY`, which cannot compile in ClickHouse.
  Date: 2026-07-01

- Decision: `TimeGrain` (with its `FromHttpApiData` and JSON instances) is defined in
  `Kansoku.Api.Metrics` inside the `kansoku:kansoku-api` sub-library, and
  `Kansoku.Metrics.Definition` in the main library imports it from there.
  Rationale: Architecture review found the earlier draft defined `TimeGrain` in
  `Kansoku.Metrics.Definition` (main library) while `Kansoku.Api.Metrics` (sub-library)
  imported it — an impossible dependency direction, since the main library depends on the
  sub-library and Cabal forbids the reverse. The MasterPlan's integration point already places
  `TimeGrain` (together with `MetricPoint`/`MetricResult`) in `Kansoku.Api.Metrics` so the
  servant API type stays free of ClickHaskell; this plan now follows it consistently.
  Date: 2026-07-01

- Decision (USER SCOPE DECISION, superseding the earlier 501-stub decision for this endpoint):
  Implement `/metrics/retention` in the MVP as a query-time cohort computation over
  `analytics.events_resolved`, with no supporting rollup. Cohort day = each user's first-seen
  day (minimum event day within the `[from, to)` window); for each cohort day and each
  day-offset `k`, the value is the count of that cohort's users who were also active on
  cohort day + `k`. The offsets default to 1, 7, 14, and 30 days and can be overridden with an
  optional comma-separated `days` query parameter; offset 0 (the cohort's own size) is always
  included so a client can compute retention *rates* as `value(k) / value(0)`.
  Rationale: Chosen by the user on 2026-07-01. It is deliberately query-time and unoptimized —
  it scans `events_resolved` twice — which is acceptable for MVP data volumes; a retention
  rollup is future work. Note the "first-seen day" is relative to the request window, not
  all-time: a user active before `from` still gets a cohort day inside the window. This is the
  standard windowed-cohort simplification and is documented at the endpoint.
  Date: 2026-07-01

- Decision (USER SCOPE DECISION, superseding the earlier 501-stub decision for this endpoint):
  Implement `/metrics/sessions` in the MVP as `uniqExact(session_id)` over
  `analytics.events_raw`, bucketed by the requested `timeGrain` — a count of distinct
  client-supplied session ids, nothing more. No session durations, boundaries, or
  timeout-based sessionization; that remains deferred.
  Rationale: Chosen by the user on 2026-07-01. `session_id` is `Nullable(String)` in
  `events_raw` (EP-3 schema); ClickHouse aggregate functions skip NULL inputs, and we also
  filter `session_id != ''` defensively so empty-string ids never count as a session.
  `uniqExact` over `session_id` is duplicate-tolerant (a replayed event row adds no new
  distinct id), so the query needs no `FINAL`. Counting distinct ids exercises no new
  machinery and gives dashboards a useful number now.
  Date: 2026-07-01

- Decision: Decode query results through a single ClickHouse `String` column named `line`,
  then parse it into `bucket`, `group_key`, and `value` in Haskell.
  Rationale: Live validation showed ClickHaskell's dynamic multi-column `unsafeMkSelect` path
  returning aggregate rows with values attached to the wrong buckets. A single-column wrapper
  keeps ClickHaskell's decode shape static while preserving the pure SQL builders and typed API
  response. The parsed rows are sorted in Haskell, so the wrapper does not rely on ClickHouse
  sort compilation for response determinism.
  Date: 2026-07-02

- Decision: Add ClickHouse read settings `compile_expressions = 0` and
  `compile_sort_description = 0` to the metric query wrapper.
  Rationale: The local ClickHouse server failed with `std::bad_alloc` inside LLVM/JIT
  expression and sort compilation for the MVP-size retention/funnel queries. These API reads are
  small semantic queries over bounded time windows, and disabling query compilation made the
  acceptance checks pass without changing metric semantics.
  Date: 2026-07-02

- Decision: Implement `/metrics/funnel` as a deterministic per-step unique-user fallback rather
  than relying on ClickHouse `windowFunnel` for the MVP.
  Rationale: The endpoint needs stable step counts for the typed API contract; the fallback
  counts users at each requested step who have also performed all prior requested steps in the
  same time window. It returns the documented fixture values and can be replaced by a stricter
  ordered-window implementation later without changing the response DTO.
  Date: 2026-07-02


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

EP-6 is complete. The shared API library now exposes `Kansoku.Metrics.Api.MetricsRoutes` and
the combined `Kansoku.Api.KansokuAPI`; the core library defines the semantic metric data model,
built-in registry, query compiler/executor, and servant handlers. The existing server serves
the NamedRoutes umbrella once, with operational routes handled by its WAI wrapper.

Fixture validation covered the seven implemented endpoints: events returned day counts
`5,3,1`; page views grouped by route returned `/home 2`, `/pricing 1`, `/home 1`; users and
sessions returned day counts `2,2,1`; conversion returned `0.5`; funnel returned
`signup_started 2` and `signup_completed 1`; retention returned cohort/offset values
`2026-06-01/0=2`, `2026-06-01/1=1`, `2026-06-02/0=1`, `2026-06-02/1=1`. The missing funnel
`steps` request returned HTTP 400, and acquisition, feature-adoption, organizations, and custom
returned HTTP 404 with the shared typed `not_implemented` envelope.


## Context and Orientation

This section assumes you know nothing about this repository. Read it fully before editing.

Kansoku is a Haskell project built with GHC 9.12.4 through a Nix flake. Application code is
written using **effectful**, an effect system where functions run in a type `Eff es` and
declare the capabilities they need as constraints in `es` (for example `IOE :> es` for
arbitrary IO). You do not need to master effectful to follow this plan; wherever a specific
effect is needed, this plan names it and shows the shape.

The pieces this plan builds on already exist in the working tree when you start, because this
plan (EP-6) hard-depends on two earlier plans and soft-depends on a third:

- **EP-3 (ClickHouse storage), hard dependency.** It created the module `Kansoku.ClickHouse`
  which exposes: a `Connection` handle to ClickHouse (the columnar analytics database, running
  in the dev environment on TCP port 9000 / HTTP port 8123); a helper to open that connection
  from configuration; the `EventRow` record that mirrors one analytics event as stored; and the
  raw-events table `analytics.events_raw`. That table is created with
  `ENGINE = ReplacingMergeTree(received_at)`, `ORDER BY (account_id, user_id,
  event_name, occurred_at, event_id)`, and `PARTITION BY toYYYYMM(occurred_at)`. "ReplacingMergeTree keyed
  on `event_id`" means: if the same `event_id` is inserted twice (which happens because
  ingestion is at-least-once), ClickHouse eventually keeps only one copy when it merges parts —
  but until a merge runs, both copies are visible, so read queries that must not double-count
  either use the `FINAL` keyword or count distinct `event_id`. EP-3 also exposes
  `insertEvents` for writing rows, which this plan uses only to load test fixtures.
  The ClickHouse client library is **ClickHaskell** (`KovalevDima/ClickHaskell`); its `select`
  function runs a read query (details in Interfaces and Dependencies).

- **EP-5 (identity + rollups), hard dependency.** It added identity events and a set of
  ClickHouse materialized views feeding "rollup views" — `AggregatingMergeTree` target tables
  that ClickHouse keeps up to date as new rows arrive. Understand what an
  `AggregatingMergeTree` rollup actually stores, because it dictates how every read in this
  plan is written: a column like `users AggregateFunction(uniqExact, String)` holds a *partial
  aggregation state* (an opaque serialized set of the distinct values seen so far in that data
  part), and the same key (say, the same `day`) can exist in several unmerged parts at once.
  To read a finished number you apply the matching `-Merge` combinator under a `GROUP BY` —
  `uniqExactMerge(users)` combines all partial states for a group and returns the final
  distinct count. A bare `SELECT users` (or `toFloat64(users)`) is a ClickHouse type error, and
  a merge-less read can return several fragment rows per day. The rollups this plan reads are:
  `analytics.daily_event_counts` (key `(day, event_name)`; `events
  AggregateFunction(uniqExact, String)` over event ids), `analytics.dau` (daily active users;
  key `day`, `users` state over identity-resolved user ids), `analytics.wau` (weekly active
  users; key `week`, the Monday of the week — note: *not* `day`), and
  `analytics.page_views_by_route` (key `(day, route)`; `views` state over page-view event ids).
  EP-5 also created two things that are **not** rollups: `analytics.identity_map`, a plain
  `ReplacingMergeTree` lookup table mapping any observed user identifier (anonymous id or user
  id) to a single canonical user id, so events a person generated before and after logging in
  count as one person; and `analytics.events_resolved`, a query-time view exposing each event
  with its resolved `canonical_user`, which this plan reads for exact, late-identify-correct
  unique-user counts and for the retention cohort computation. EP-5 documents the exact columns
  and recommended SELECT patterns; Milestone 0 tells you how to confirm the real columns before
  coding.

- **EP-4 (ingestion API), soft dependency.** It introduced the HTTP server: a **servant**
  application served by **warp** (servant is a Haskell library where you describe a web API as a
  *type* and get a type-checked server; warp is the underlying HTTP server that runs it). EP-4's
  server currently serves the ingestion endpoints `POST /v1/events` and `POST /v1/batch` and a
  health endpoint. This plan **extends that same servant application** with the `GET /metrics/*`
  endpoints; it does not start a second server. The soft dependency is only about *data*: with
  EP-4 running you can post real events, but this plan is fully verifiable by inserting fixture
  rows directly with EP-3's `insertEvents`, so you do not need EP-4 to be finished.

- **EP-1 (runtime), transitively required.** It created the buildable package `kansoku`
  (the file `kansoku.cabal` and the `Kansoku.*` module namespace), the effectful runtime, and
  `Kansoku.Config`, a record parsed from environment variables (`PG_CONNECTION_STRING`,
  `CLICKHOUSE_TCP_PORT`, `CLICKHOUSE_HTTP_PORT`, and — added by EP-3 — the ClickHouse host/port
  used to open a connection). New effects and configuration fields are added by extending these,
  following EP-1's documented pattern, not by inventing a parallel runtime.

All Haskell in this plan follows the shared Kansoku standards in
`/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/core/` — `standards.md`, `custom-prelude.md`,
`record-patterns.md`, and `multiline-strings.md`. Concretely: every package uses the `GHC2024`
language edition and the shared `common` cabal stanza (every stanza declares `import: common`)
enabling `DeriveAnyClass`, `DuplicateRecordFields`, `OverloadedLabels`, `OverloadedStrings`, and
`MultilineStrings`; every module imports `Kansoku.Prelude` (EP-1's custom prelude, exported from
the `kansoku:kansoku-api` sub-library, which re-exports `Text`, `Generic`, aeson's
`FromJSON`/`ToJSON`, `Data.Time`, `NonEmpty`, and the `lens` operators); qualified imports use
the postpositive form (`import Data.Text qualified as Text`); records use strict `!` fields with
explicit `deriving stock`/`deriving anyclass`/`deriving newtype` clauses; records are read and
updated through generic-lens `#label` syntax (each such module adds
`import Data.Generics.Labels ()`); and embedded ClickHouse SQL is written as `"""..."""`
MultilineStrings — which is exactly how `buildSQL` emits its query text in Milestone 1. The code
sketches below follow these rules.

Terms of art used in this plan, defined in plain language:

- **Semantic metric**: a named, reusable definition of a number (e.g. "Active Users"),
  expressed as data, that can be compiled to a query. "Semantic" here just means the meaning
  lives in one place instead of being re-derived in each dashboard's SQL.
- **Aggregation**: how raw event rows are collapsed into one number — counting rows, counting
  distinct users, summing a numeric property, averaging it, or dividing one count by another
  (a ratio).
- **Time grain**: the size of each time bucket a metric is broken into — hour, day, week, or
  month. "DAU" (daily active users) is the active-users metric at a day grain; "WAU" is the
  same at a week grain.
- **Rollup view**: see EP-5 above — an `AggregatingMergeTree` table kept current automatically,
  used so a query reads a few small rows instead of scanning all raw events. Its aggregate
  columns hold `AggregateFunction(...)` partial states, so reads always use a `-Merge`
  combinator (`uniqExactMerge`) under a `GROUP BY` on the rollup's key columns.
- **Session**: a client-supplied grouping id (`session_id`, a `Nullable(String)` column on
  `analytics.events_raw`) that the SDK attaches to events emitted during one visit. The MVP
  sessions metric only counts distinct `session_id` values per time bucket; it does not derive
  durations or boundaries.
- **Retention cohort**: the set of users whose first-seen day (their earliest event day within
  the requested window) is the same day. Day-`k` retention for a cohort is how many of those
  users were also active exactly `k` days later.
- **Funnel**: an ordered list of steps (event names) a user is expected to pass through, e.g.
  "landing page viewed" → "signup started" → "signup completed". The funnel metric reports how
  many distinct users reached each step, so you can see where people drop off.

The files this plan creates or edits, all under the repository root
`/Users/shinzui/Keikaku/bokuno/kansoku-project/kansoku`:

- `kansoku-api/src/Kansoku/Metrics/Api.hs` — the shared `TimeGrain` query-param enum, JSON
  response types (`MetricResult`, `MetricPoint`), and `MetricsRoutes` NamedRoutes record; no
  handlers and no `servant-server`.
- `kansoku-core/src/Kansoku/Metrics/Definition.hs` — the metric data types
  (`Aggregation`, `MetricDefinition`, `RatioMetric`); imports `TimeGrain` from
  `Kansoku.Metrics.Api`.
- `kansoku-core/src/Kansoku/Metrics/Registry.hs` — the built-in metrics.
- `kansoku-core/src/Kansoku/Metrics/Query.hs` — the SQL builder and bounded-pool executor.
- `kansoku-core/src/Kansoku/Metrics/Handler.hs` — the `MetricsRoutes (AsServerT Handler)` server.
- `kansoku-core/src/Kansoku/Server.hs` — constructs the umbrella `KansokuAPI` server record and
  delegates it to the single Servant application.
- `kansoku-api/kansoku-api.cabal` and `kansoku-core/kansoku-core.cabal` — expose the API and core
  modules with their one-way dependency (`kansoku-core` depends on `kansoku-api`).
- `kansoku-core/test/Kansoku/QuerySpec.hs` — exact SQL tests for the compiler.


## Plan of Work

The work is four milestones. Milestone 1 builds the metric library and query compiler with no
web server involved, verified purely by unit tests over generated SQL — this de-risks the
hardest part (getting the SQL right) before any HTTP is in play. Milestone 2 wires three
read-only endpoints into the existing servant app and verifies them against known fixtures.
Milestone 3 adds the funnel and conversion endpoints. Milestone 4 adds the sessions and
retention endpoints (implemented per the two user scope decisions in the Decision Log) and
freezes the four remaining stubbed endpoints as typed HTTP 404 `not_implemented` results.

There is a Milestone 0 up front: a read-only confirmation step. It exists because this plan
makes claims about tables and modules created by earlier plans; before writing code you confirm
those claims against the actual tree, and if a name differs you adapt (and record the
difference in the Decision Log). Milestone 0 changes nothing.


### Milestone 0 — Confirm the ground truth (no code changes)

Scope: verify the prerequisite artifacts exist and learn their exact names. At the end you will
know the real module path of the servant application, the real columns of the rollup views, and
that ClickHouse is reachable. Nothing is edited.

Run, from the repository root, a search for the servant application wiring and the ClickHouse
module surface (the exact commands are in Concrete Steps). Read `src/Kansoku/ClickHouse.hs` (or
whatever EP-3 named it) to learn the real type of the connection handle, the name of the
function that opens a connection from `Kansoku.Config`, and the signature of `insertEvents`
(used only for fixtures). Read the EP-5 plan file
`docs/plans/5-identity-stitching-and-materialized-view-rollups.md` and, if the views already
exist, confirm the live column names with `clickhouse-client` (`DESCRIBE TABLE analytics.dau`
etc.). Acceptance: you can state, in one sentence each, the module that builds the servant
`Application`, the function that yields a ClickHouse `Connection`, and the column list of
`analytics.dau`, `analytics.page_views_by_route`, and `analytics.identity_map`. If any name
differs from what this plan assumes, note it in the Decision Log and use the real name
throughout.


### Milestone 1 — Metric definitions, registry, and the SQL compiler

Scope: create the pure core. At the end there will be a `MetricDefinition` type mirroring the
spec, an `Aggregation` and a `TimeGrain` sum type, a registry of the twelve built-in metrics,
and a function that compiles any metric plus a time-range request into ClickHouse SQL text —
all unit-tested by asserting the exact SQL produced. No database and no HTTP are needed to run
these tests, so this milestone is fully verifiable in isolation.

Start with the shared API library, because the core library imports from it and never the
other way around. Create `kansoku-api/src/Kansoku/Metrics/Api.hs`
(add it to that stanza's `exposed-modules` now). In it define
`data TimeGrain = Hour | Day | Week | Month` with `deriving stock (Generic, Eq, Ord, Show)`,
a hand-written `aeson` `ToJSON`/`FromJSON` instance whose wire form matches the spec strings
exactly (`"hour"`, `"day"`, `"week"`, `"month"`), and a `FromHttpApiData` instance (from the
`http-api-data` package that servant re-exports) parsing the same strings, so `TimeGrain` can
be a query parameter. Also define here the response DTOs `MetricPoint` and `MetricResult`
(shapes below, under `Kansoku.Metrics.Query`, and in Interfaces and Dependencies) — they live
in the API library so the route record added in Milestone 2 stays free of the ClickHaskell
dependency. `TimeGrain` lives here, not in `Kansoku.Metrics.Definition`, because the servant
route record references it and the API library cannot import from the core library (see the
Decision Log).

Then create `kansoku-core/src/Kansoku/Metrics/Definition.hs` in the core library. Define
`data Aggregation = Count | UniqueCount | Sum | Average | Ratio` with an explicit
`deriving stock (Generic, Eq, Ord, Show)` and a hand-written `ToJSON`/`FromJSON` instance
matching the spec strings exactly (`"count"`, `"unique_count"`, `"sum"`, `"average"`,
`"ratio"`) — hand-written rather than generically derived so the JSON is guaranteed to match
the spec. Import `TimeGrain` from `Kansoku.Metrics.Api`. Define the record faithfully to the
spec's TypeScript shape:

```haskell
data MetricDefinition = MetricDefinition
  { name        :: !Text
  , description :: !(Maybe Text)
  , eventNames  :: ![Text]
  , aggregation :: !Aggregation
  , filters     :: !(Map Text Value)   -- Value is Data.Aeson.Value
  , groupBy     :: ![Text]
  , timeGrain   :: !(Maybe TimeGrain)
  }
  deriving stock (Generic, Eq, Show)
  -- ToJSON/FromJSON are hand-written (see above) to pin the wire form to the spec strings.
  -- No field prefixes (per the record-patterns "No Field Prefixes" rule); the shared field
  -- names (name/description/groupBy/timeGrain) are legal across records via
  -- DuplicateRecordFields, and match the spec's TypeScript field names exactly.
```

Also define, in the same module, the ratio wrapper used by the registry for two-population
ratios:

```haskell
data RatioMetric = RatioMetric
  { name        :: !Text
  , description :: !(Maybe Text)
  , numerator   :: !MetricDefinition   -- e.g. "signup completed" unique users
  , denominator :: !MetricDefinition   -- e.g. "signup started" unique users
  }
  deriving stock (Generic, Eq, Show)
```

Create `kansoku-core/src/Kansoku/Metrics/Registry.hs`. Export the twelve built-in metrics — the ten named
in the spec plus two endpoint-backing entries (`events` and `page_views`) so that every
implemented endpoint has a registry entry to look up — as top-level values, and a lookup map.
Represent each as either a `MetricDefinition` or a `RatioMetric`, wrapped in a sum so the
registry is a single list:

```haskell
data BuiltinMetric = Simple !MetricDefinition | Ratioed !RatioMetric
  deriving stock (Generic, Eq, Show)

builtinMetrics :: Map Text BuiltinMetric
```

Define each metric per the spec ("Semantic Metrics Layer" and "Initial Product Metrics"),
plus the two endpoint-backing entries:
- **Events** (key `events`) — `Count` over all events: an empty `eventNames` list, which the
  SQL builder treats as "no `event_name` filter". This backs `/metrics/events`.
- **Page Views** (key `page_views`) — `Count` filtered to `eventNames = ["page_view"]`. This
  backs `/metrics/page-views` (and is served from the `page_views_by_route` rollup at day
  grain via the rollup shortcut below).
- **Active Users** — `UniqueCount` of any event by resolved user (the events the DAU/WAU
  rollups already aggregate).
- **New Users** — `UniqueCount` of the `user registered` / account-created event.
- **Returning Users** — `UniqueCount` of active users excluding those whose first-seen day is
  in-range (documented as computed against the identity map; for MVP registry this is a
  definition value, not a served endpoint).
- **Conversion Rate** — `Ratioed` (numerator = unique users with `signup completed`,
  denominator = unique users with `signup started`).
- **Activation Rate** — `Ratioed` (numerator = unique users with `onboarding completed`,
  denominator = unique users with `account created`).
- **Retention** — `Ratioed` (definition value for MVP).
- **Feature Adoption** — `UniqueCount` filtered to a feature event.
- **Revenue** — `Sum` of a numeric property (e.g. `properties.amount`) over payment events.
- **Search Success Rate** — `Ratioed` (numerator = `search performed` with a results-found
  filter, denominator = all `search performed`).
- **Funnel Completion Rate** — `Ratioed` (numerator = unique users reaching the final funnel
  step, denominator = unique users reaching the first step).

Every metric must carry a non-empty `description`, because the value of the semantic
layer is that the definition documents itself.

Create `kansoku-core/src/Kansoku/Metrics/Query.hs` in the core library. Define the request type
and compiler there; the two result DTOs below are already defined in `Kansoku.Metrics.Api`,
shown here because `Kansoku.Metrics.Query` imports and
produces them:

```haskell
-- In Kansoku.Metrics.Query (core library):
data QueryRequest = QueryRequest
  { from      :: !Day               -- inclusive, from Data.Time
  , to        :: !Day               -- exclusive upper bound (see below)
  , groupBy   :: !(Maybe [Text])    -- overrides the metric's own groupBy when present
  , timeGrain :: !(Maybe TimeGrain) -- overrides the metric's own timeGrain when present
  }
  deriving stock (Generic, Eq, Show)

-- In Kansoku.Metrics.Api (API library), imported by Kansoku.Metrics.Query:
data MetricPoint = MetricPoint
  { bucket :: !(Maybe Text)      -- e.g. "2026-06-01"; Nothing for a single scalar
  , group  :: !(Map Text Text)   -- group-by dimension values; empty when no grouping
  , value  :: !Double
  }
  deriving stock (Generic, Eq, Show)

data MetricResult = MetricResult
  { metric :: !Text
  , points :: ![MetricPoint]
  }
  deriving stock (Generic, Eq, Show)
```

No field prefixes are used (per the record-patterns "No Field Prefixes" rule); shared field
names such as `from`/`to`/`groupBy`/`timeGrain`/`value`/`points` are legal across these and the
metric records via `DuplicateRecordFields`, and generic-lens `#label` access resolves them
unchanged. Because these DTOs' generic wire form keys off the field names, the de-prefixed names
also make the JSON response keys clean (`bucket`/`group`/`value`, `metric`/`points`).

Give `MetricPoint` and `MetricResult` `ToJSON` instances (this is the HTTP response contract;
its exact JSON is in Interfaces and Dependencies). They live in `Kansoku.Metrics.Api` because
the `MetricsRoutes` record (added in Milestone 2) references them and the API library must
stay free of the ClickHaskell dependency.

Define the **pure** SQL builder — this is the heart of the milestone and what the unit tests
pin down:

```haskell
buildSQL :: BuiltinMetric -> QueryRequest -> Text
```

Rules the builder follows, stated so a novice can reproduce the exact output:
- The time window is half-open: `occurred_at >= '<from> 00:00:00' AND occurred_at < '<to>
  00:00:00'`. `to` is the day *after* the last day you want included, which is why the
  fixtures below use `to=2026-06-08` to cover through June 7. Render dates as
  `YYYY-MM-DD HH:MM:SS` string literals.
- The time bucket column is chosen from the effective time grain:
  `toString(toStartOfHour(occurred_at))` (hour), `toString(toDate(occurred_at))` (day),
  `toString(toMonday(occurred_at))` (week), or `toString(toStartOfMonth(occurred_at))`
  (month), aliased `AS bucket`. The day/week/month expressions all return ClickHouse `Date`
  values, so their string form is a plain `2026-06-01` — deliberately identical to what the
  rollup reads produce with `toString(day)`, so bucket strings look the same no matter which
  table served the query. (Do not use `toStartOfDay`, which returns a `DateTime` and would
  render as `2026-06-01 00:00:00`.) Hour is the only grain with a time component. When there
  is no time grain (a scalar metric like conversion), select `'' AS bucket`.
- The group column: when grouping by a single dimension `d`, select `toString(d) AS group_key`;
  with no grouping select `'' AS group_key`.
- The value column depends on the aggregation:
  - `Count` → `toFloat64(count(DISTINCT event_id)) AS value` (dedup-safe per the Decision Log).
  - `UniqueCount` → count distinct canonical (identity-resolved) users by reading EP-5's
    `analytics.events_resolved` view, which already resolves each event to its `canonical_user`
    (the `analytics.identity_map` join over `events_raw FINAL`):
    `toFloat64(uniqExact(canonical_user)) AS value` with a `canonical_user != ''` guard. This is
    the exact, late-identify-correct path EP-5 documents; do not re-implement the `identity_map`
    join here. (The fast day/week grains use the `analytics.dau`/`analytics.wau` rollups via the
    rollup shortcut below.)
  - `Sum` → `toFloat64(sum(<numeric property extraction>)) AS value`.
  - `Average` → `toFloat64(avg(<numeric property extraction>)) AS value`.
  - `Ratio` → build the numerator and denominator sub-metrics each as a scalar `UniqueCount`
    over its own event set, then emit `numerator / denominator AS value` (with a
    `denominator = 0` guard producing `0`).
- `eventNames` becomes `event_name IN ('a','b',...)`; an **empty** `eventNames` list means "no
  `event_name` predicate at all" (the `events` registry entry relies on this to count every
  event). `filters` becomes additional `AND` clauses (for MVP, support equality filters on
  top-level columns and on `properties`/`context` string keys via ClickHouse's
  `JSONExtractString`).
- The rollup shortcut: when the metric is Active Users and the effective grain is Day, read
  `analytics.dau`; when the grain is Week, read `analytics.wau` (whose key column is `week`,
  the Monday of the week — not `day`); when the metric is Page Views at day grain, read
  `analytics.page_views_by_route`. These rollups are `AggregatingMergeTree` tables whose
  `users`/`views` columns hold `AggregateFunction(uniqExact, String)` partial states, and the
  same key can appear in several unmerged data parts, so every rollup read **must** finish the
  aggregation with `uniqExactMerge` under a `GROUP BY` on the rollup's key columns:

  ```sql
  -- Active Users at day grain:
  SELECT toString(day) AS bucket, '' AS group_key,
         toFloat64(uniqExactMerge(users)) AS value
  FROM analytics.dau
  WHERE day >= '{{from}}' AND day < '{{to}}'
  GROUP BY day
  ORDER BY day

  -- Active Users at week grain (key column is week):
  SELECT toString(week) AS bucket, '' AS group_key,
         toFloat64(uniqExactMerge(users)) AS value
  FROM analytics.wau
  WHERE week >= '{{from}}' AND week < '{{to}}'
  GROUP BY week
  ORDER BY week

  -- Page views per day, one series per route (groupBy=route):
  SELECT toString(day) AS bucket, route AS group_key,
         toFloat64(uniqExactMerge(views)) AS value
  FROM analytics.page_views_by_route
  WHERE day >= '{{from}}' AND day < '{{to}}'
  GROUP BY day, route
  ORDER BY day, route

  -- Page views per day, all routes combined (no groupBy): merging the per-route states
  -- yields the distinct page-view event_ids per day, i.e. the daily total.
  SELECT toString(day) AS bucket, '' AS group_key,
         toFloat64(uniqExactMerge(views)) AS value
  FROM analytics.page_views_by_route
  WHERE day >= '{{from}}' AND day < '{{to}}'
  GROUP BY day
  ORDER BY day
  ```

  A bare `toFloat64(users)` with no `GROUP BY` is a ClickHouse type error (you cannot cast an
  aggregation state to a number) — see the Decision Log. The rollup key columns are `Date`s,
  so the window predicates compare against plain `'YYYY-MM-DD'` literals, not
  `'YYYY-MM-DD 00:00:00'`. Use the real column names from Milestone 0.
- Always end with `GROUP BY bucket, group_key ORDER BY bucket, group_key` for aggregate forms
  over `events_raw`/`events_resolved`; the rollup reads above instead `GROUP BY` their key
  columns (`day`, `week`, or `day, route`), which is what makes `uniqExactMerge` produce one
  finished value per bucket.

A compliant sketch of `buildSQL` follows. Note how the fixed-shape query fragments are written
as `"""..."""` MultilineStrings (per the multiline-strings standard), and the per-request
literals (window bounds, the time-bucket expression, event lists) are spliced into `{{...}}`
placeholders with `Data.Text.replace` — MultilineStrings do not interpolate, so a small
template-substitution keeps the SQL readable while staying pure and unit-testable:

```haskell
module Kansoku.Metrics.Query where

import Kansoku.Prelude
import Data.Generics.Labels ()             -- enables #label reads below
import Data.Text qualified as Text
import Kansoku.Metrics.Definition (MetricDefinition)
import Kansoku.Metrics.Registry (BuiltinMetric (..))

-- | Compile a metric plus a time-range request into ClickHouse SQL text.
--   Pure and unit-tested: the returned 'Text' is exactly what QuerySpec asserts.
--   'bucketExpr', 'effectiveGrain', 'activeUsersDaily', 'eventList', and 'renderDay' are the
--   small helpers that implement the rules stated above.
buildSQL :: BuiltinMetric -> QueryRequest -> Text
buildSQL metric req = case metric of
    Simple def | activeUsersDaily def req -> fill baseBindings dauTemplate
    Simple _                              -> fill baseBindings eventsCountTemplate
    Ratioed r                             -> fill (ratioBindings r) ratioTemplate
  where
    fromLit = renderDay (req ^. #from)
    toLit   = renderDay (req ^. #to)

    baseBindings =
      [ ("{{from}}",   fromLit)
      , ("{{to}}",     toLit)
      , ("{{bucket}}", bucketExpr (effectiveGrain metric req))
      ]
    ratioBindings r = baseBindings
      <> [ ("{{numEvents}}", eventList (r ^. #numerator   . #eventNames))
         , ("{{denEvents}}", eventList (r ^. #denominator . #eventNames))
         ]

    -- Replace every "{{key}}" placeholder in the template with its bound value.
    fill bindings tpl = foldr (\(needle, value) -> Text.replace needle value) tpl bindings

    -- Rollup shortcut: Active Users at Day grain reads the AggregatingMergeTree rollup.
    -- `users` is an AggregateFunction(uniqExact, String) partial state, so the read must
    -- finish the aggregation: uniqExactMerge under GROUP BY day (see the rules above).
    dauTemplate =
      """
      SELECT toString(day) AS bucket, '' AS group_key,
             toFloat64(uniqExactMerge(users)) AS value
      FROM analytics.dau
      WHERE day >= '{{from}}' AND day < '{{to}}'
      GROUP BY day
      ORDER BY day
      """
    -- Dedup-safe plain events count over events_raw, bucketed by the effective time grain.
    eventsCountTemplate =
      """
      SELECT {{bucket}} AS bucket, '' AS group_key,
             toFloat64(count(DISTINCT event_id)) AS value
      FROM analytics.events_raw
      WHERE occurred_at >= '{{from}} 00:00:00' AND occurred_at < '{{to}} 00:00:00'
      GROUP BY bucket, group_key
      ORDER BY bucket, group_key
      """
    -- Two-population ratio: identity-resolved unique users, numerator / denominator,
    -- with a denominator = 0 guard producing 0.
    ratioTemplate =
      """
      SELECT '' AS bucket, '' AS group_key,
             if(denominator = 0, 0, numerator / denominator) AS value
      FROM
        ( SELECT
            ( SELECT toFloat64(uniqExact(canonical_user))
              FROM analytics.events_resolved
              WHERE canonical_user != ''
                AND event_name IN ({{numEvents}})
                AND occurred_at >= '{{from}} 00:00:00' AND occurred_at < '{{to}} 00:00:00'
            ) AS numerator,
            ( SELECT toFloat64(uniqExact(canonical_user))
              FROM analytics.events_resolved
              WHERE canonical_user != ''
                AND event_name IN ({{denEvents}})
                AND occurred_at >= '{{from}} 00:00:00' AND occurred_at < '{{to}} 00:00:00'
            ) AS denominator
        )
      """
```

Define the executor that runs the SQL and decodes rows:

```haskell
run :: (IOE :> es) => QueryPool -> BuiltinMetric -> QueryRequest -> Eff es MetricResult
```

`QueryPool` is EP-11's bounded read pool. It is passed as an ordinary first argument; the
server assembly opens it once at startup and hands it to `metricsServer`, which closes over it
in each handler. `run` calls `buildSQL`, wraps the text in ClickHaskell's
`unsafeMkSelect` targeting a fixed three-column result row `AggRow { bucket :: ChString,
group_key :: ChString, value :: Float64 }` (deriving `Generic` and `ClickHaskell '[Column
"bucket" ChString, Column "group_key" ChString, Column "value" Float64]`), executes it with
`withQueryConnection` and ClickHaskell's `select`, and maps each `AggRow` to a `MetricPoint`
(empty `bucket`/`group_key` strings become `Nothing`/empty map). See Interfaces and
Dependencies for the exact ClickHaskell signatures.

Write `test/Kansoku/QuerySpec.hs`. Assert `buildSQL` output for at least: (a) Active Users at
day grain returns the `analytics.dau` read in its merged form — `uniqExactMerge(users)` with
`GROUP BY day` (the exact `Text` of the `dauTemplate` above with the window bounds spliced
in); (b) a plain events count at day grain returns the dedup-safe `count(DISTINCT event_id)`
form with the correct half-open window; (c) a conversion `Ratioed` metric returns
`numerator / denominator`. Compare against exact expected `Text`. These tests need no
database. (Milestone 4 extends this spec with the sessions and retention SQL.)

Acceptance for Milestone 1: `cabal build` succeeds and `cabal test` runs the QuerySpec green.
Commands and expected transcript are in Concrete Steps.


### Milestone 2 — Wire read endpoints into the servant app (events, page-views, users)

Scope: expose three metrics over HTTP by extending the existing servant application, and verify
each against fixture events. At the end, `curl` against a running `kansoku-server` returns
correct JSON for `/metrics/events`, `/metrics/page-views`, and `/metrics/users`.

First ensure the metrics handlers can reach ClickHouse. EP-11 added `QueryPool` and its size to
`Kansoku.Config`; confirm that in Milestone 0. The server creates this bounded pool once and
shares it with all metrics handlers. Do not create a parallel config or connection mechanism.

Declare the servant route record in `src/Kansoku/Metrics/Api.hs` — the module you already created
in Milestone 1, which compiles into the shared `kansoku:kansoku-api` sub-library and therefore
depends on API-side Servant libraries only (no `servant-server`, no warp, no ClickHaskell). Milestone 1 put the
`TimeGrain` enum and the response DTOs (`MetricResult`, `MetricPoint`) there; this milestone
adds the `MetricsRoutes` record and `MetricQuery` alias that reference them (full type in
Interfaces and Dependencies). The shared query-parameter block is:

```haskell
type MetricQuery =
       QueryParam' '[Required] "from" Day
    :> QueryParam' '[Required] "to"   Day
    :> QueryParam  "groupBy"   Text
    :> QueryParam  "timeGrain" TimeGrain
    :> MultiVerb 'GET '[JSON]
         (OkResponses "Metric result" MetricResult)
         (KansokuResult MetricResult)
```

`from` and `to` are required ISO dates (`Day` from `Data.Time` has a `FromHttpApiData` instance
parsing `YYYY-MM-DD`); `groupBy` and `timeGrain` are optional. The same sub-library declares
`KansokuAPI mode`, whose `ingest` and `metrics` fields contain nested NamedRoutes records, plus
`kansokuAPI :: Proxy (NamedRoutes KansokuAPI)`. EP-8 feeds this exact proxy to
`servant-openapi-hs`.

Then create `src/Kansoku/Metrics/Handler.hs` in the main `kansoku` library. Define
`metricsServer` as a function `QueryPool -> MetricsRoutes (AsServerT Handler)` — it takes EP-11's
bounded ClickHouse query pool (opened once at startup by the server assembly) and its implemented
handlers build a `QueryRequest` from
the params, look up the right `BuiltinMetric` from the registry by key, and call
`Kansoku.Metrics.Query.run pool metric request`. Each handler returns a `KansokuResult` value:
success is `200`, malformed input is `400`, an absent/stubbed metric is `404`, and query failure
is `503`. `Kansoku.Server.kansokuServer` constructs the umbrella record, and one
`serveWithContext kansokuAPI` call serves both slices.

Implement three handlers fully:
- `/metrics/events` → looks up the `events` registry entry (a `Count` with an empty
  `eventNames` list, meaning every event) and runs it over `events_raw`, honoring `timeGrain`
  and an optional `groupBy` on `event_name` or `source`.
- `/metrics/page-views` → looks up the `page_views` registry entry (a `Count` filtered to
  `event_name = 'page_view'`); at day grain the rollup shortcut serves it from
  `analytics.page_views_by_route` with `uniqExactMerge(views)`, and `groupBy=route` returns one
  series per route.
- `/metrics/users` → looks up the `active_users` registry entry; `timeGrain=day` serves DAU
  from `analytics.dau`, `timeGrain=week` serves WAU from `analytics.wau` (both read with
  `uniqExactMerge(users)` under `GROUP BY`), using identity-resolved counts.

A word on precision, because two storage paths answer these endpoints and they can
legitimately disagree. The rollups (`dau`, `wau`, `page_views_by_route`) resolve identity **at
insert time**: the canonical user recorded for an event is frozen at the moment the row was
ingested, so an `identify` event that arrives *later* does not retroactively merge that
event's user into the rollup numbers. `analytics.events_resolved` resolves identity **at query
time** against the latest `identity_map`, so late identify events are always reflected.
Concretely: `/metrics/users` (day/week grain) serves rollup precision — fast,
insert-time-frozen; `/metrics/conversion`, `/metrics/funnel`, and `/metrics/retention`
(Milestone 4) serve `events_resolved` precision — exact under late identifies;
`/metrics/events`, `/metrics/page-views`, and `/metrics/sessions` count events or session ids,
not people, so identity resolution does not affect them at all. A small discrepancy between
`/metrics/users` and a user count derived from `events_resolved` after a late identify is
therefore expected behavior, not a bug — EP-5 documents the same trade-off.

Related rule for when to use ClickHouse's `FINAL` keyword (which forces `ReplacingMergeTree`
duplicate collapse at read time, at a real performance cost): none of this plan's aggregate
queries need it. `count(DISTINCT event_id)`, `uniqExact(canonical_user)`, and
`uniqExact(session_id)` are all duplicate-tolerant — a replayed row contributes an id already
in the distinct set — so adding `FINAL` would only slow them down. `FINAL` is only required
where **row multiplicity** matters, i.e. where a duplicate row would change the answer: for
example a future `Sum`/`Average` over a numeric property (Revenue), or row-level reads like
the one inside EP-5's `events_resolved` view (which already applies `FINAL` internally for
exactly this reason).

Leave the other endpoints returning typed `KansokuNotFound` values for now (Milestones 3 and 4
finalize them, but their routes and response schemas are already present).

Acceptance: with fixtures loaded and the server running, the three `curl` commands in Validation
return JSON whose numbers equal the hand-computed values.


### Milestone 3 — Funnel and conversion endpoints

Scope: implement the two metrics that exercise sequence and ratio machinery. At the end,
`/metrics/funnel` and `/metrics/conversion` compute correct numbers against the fixtures.

Implement `/metrics/funnel`: accept the funnel steps as a single **required** query parameter
`steps` containing the ordered event names, comma-separated (for example
`steps=signup_started,signup_completed`), plus `from`/`to`. It is one comma-separated
parameter — not a repeated parameter — because servant's `QueryParam` combinator binds a
query-string key at most once; the handler splits the value on commas
(`Text.splitOn ","`) and preserves the order as the step order. Declare it
`QueryParam' '[Required] "steps" Text` in the `funnel` field of `MetricsRoutes` (a funnel without steps is meaningless,
so requests missing `steps` should fail with 400 at the servant layer rather than reach the
handler). Compile to a ClickHouse `windowFunnel`-based query that, for each distinct resolved
user, finds the furthest step reached within the window, then reports the number of distinct
users reaching each step. Return one `MetricPoint` per step with `group` carrying the step
name and index and `value` the user count. (If Milestone 0 shows the ClickHouse build lacks
`windowFunnel`, fall back to a per-step `uniqExact` of users who have all events up to that
step; note the choice in Surprises & Discoveries.)

Implement `/metrics/conversion`: serve the Conversion Rate `Ratioed` metric — unique users with
`signup completed` divided by unique users with `signup started` in the window — returning a
single scalar `MetricPoint` (`bucket = Nothing`) with the ratio as a fraction between 0 and 1.

Acceptance: the funnel and conversion `curl` commands in Validation match the hand-computed
values, and a funnel request without `steps` returns HTTP 400.


### Milestone 4 — Sessions and retention endpoints; freeze the four stubs

Scope: implement the two endpoints the user pulled into the MVP scope on 2026-07-01 (see the
Decision Log), and make the four remaining unimplemented endpoints return the shared typed
HTTP 404 envelope. At
the end all eleven spec endpoints are routable; seven compute correct numbers (`events`,
`page-views`, `sessions`, `users`, `funnel`, `retention`, `conversion`); four return a
documented `not_implemented` result (`acquisition`, `feature-adoption`, `organizations`, `custom`).

Implement `/metrics/sessions`: a count of distinct client-supplied session ids per time
bucket, over `analytics.events_raw`. The `session_id` column is `Nullable(String)` (EP-3's
schema); ClickHouse aggregate functions skip NULL inputs, so `uniqExact(session_id)` never
counts a NULL, and we additionally filter `session_id != ''` defensively so empty-string ids
never count as a session either. `uniqExact` over `session_id` is duplicate-tolerant (the
replayed fixture row adds no new distinct id), so no `FINAL` is needed. This is counts only —
no session durations, boundaries, or timeout-based sessionization; that remains deferred
beyond the MVP. Add the template to `buildSQL` (or a sibling builder in `Kansoku.Metrics.Query`),
honoring the requested `timeGrain` through the same `{{bucket}}` expression as the events
count:

```sql
SELECT {{bucket}} AS bucket, '' AS group_key,
       toFloat64(uniqExact(session_id)) AS value
FROM analytics.events_raw
WHERE occurred_at >= '{{from}} 00:00:00' AND occurred_at < '{{to}} 00:00:00'
  AND isNotNull(session_id) AND session_id != ''
GROUP BY bucket, group_key
ORDER BY bucket, group_key
```

Implement `/metrics/retention`: a query-time cohort computation over
`analytics.events_resolved` — deliberately unoptimized for the MVP (it scans the resolved
events twice; a retention rollup is future work, and using `events_resolved` gives it
query-time identity precision, so late identify events are handled correctly). The semantics:
a user's **cohort day** is their first-seen day — the minimum `toDate(occurred_at)` over their
`events_resolved` rows within `[from, to)`. For each cohort day and each **day-offset** `k`,
the value is how many of that cohort's users were also active (had any event) on cohort day +
`k`. The offsets come from an optional query parameter `days`, a comma-separated list of
positive integers defaulting to `1,7,14,30`; offset `0` is always prepended by the handler
regardless of `days`, because at offset 0 every cohort user is active by definition, so the
offset-0 value is the cohort's size and lets a client compute the retention **rate** as
`value(k) / value(0)`. Declare the route with `QueryParam "days" Text` instead of the shared
`MetricQuery` block (retention ignores `groupBy`/`timeGrain`). The SQL is a two-level
aggregation — a first-seen CTE joined back to a distinct-activity CTE ("CTE" = common table
expression, ClickHouse's `WITH name AS (subquery)` form):

```sql
WITH
  first_seen AS
  (
    SELECT canonical_user, min(toDate(occurred_at)) AS cohort_day
    FROM analytics.events_resolved
    WHERE canonical_user != ''
      AND occurred_at >= '{{from}} 00:00:00' AND occurred_at < '{{to}} 00:00:00'
    GROUP BY canonical_user
  ),
  activity AS
  (
    SELECT DISTINCT canonical_user, toDate(occurred_at) AS active_day
    FROM analytics.events_resolved
    WHERE canonical_user != ''
      AND occurred_at >= '{{from}} 00:00:00' AND occurred_at < '{{to}} 00:00:00'
  )
SELECT
    toString(f.cohort_day)                            AS bucket,
    toString(dateDiff('day', f.cohort_day, a.active_day)) AS group_key,
    toFloat64(uniqExact(f.canonical_user))            AS value
FROM first_seen AS f
INNER JOIN activity AS a ON a.canonical_user = f.canonical_user
WHERE dateDiff('day', f.cohort_day, a.active_day) IN ({{offsets}})
GROUP BY f.cohort_day, dateDiff('day', f.cohort_day, a.active_day)
ORDER BY f.cohort_day, dateDiff('day', f.cohort_day, a.active_day)
```

`{{offsets}}` is the comma-joined offset list including the prepended 0 (default
`0,1,7,14,30`). The query reuses the three-column `AggRow` decode: the handler re-maps each
row into a `MetricPoint` with `bucket = Nothing` and `group = {"cohort": <row bucket>,
"offset": <row group_key>}`, because a cohort day labels a cohort rather than a time-series
bucket. Cohort/offset combinations with zero returning users produce **no** point (the join is
sparse); clients treat a missing point as 0. Two caveats to document in the handler's Haddock:
"first seen" is relative to the request window (a user active before `from` still cohorts
inside the window — the standard windowed-cohort simplification), and offsets whose target day
falls at or beyond `to` cannot appear since activity is only scanned inside the window.

Extend `test/Kansoku/QuerySpec.hs` with two more exact-SQL assertions: (d) the sessions query
at day grain, and (e) the retention query with default offsets. Five assertions total after
this milestone.

Finalize the four stubs (`/metrics/acquisition`, `/metrics/feature-adoption`,
`/metrics/organizations`, `/metrics/custom`). Each handler returns the shared typed `404`
envelope so it stays inside every endpoint's MultiVerb response list:

```haskell
notImplemented :: Text -> Day -> Day -> Maybe Text -> Maybe TimeGrain
               -> Handler (KansokuResult MetricResult)
notImplemented name _ _ _ _ =
  pure
    ( KansokuNotFound
        (notFound "not_implemented" ("metric endpoint is stubbed in the MVP: " <> name))
    )
```

`/metrics/custom` additionally documents (in a Haddock comment and the 404 message) that it will
accept a full `MetricDefinition` JSON body and compile it with the same `buildSQL`, so the path
is reserved.

Acceptance: `curl` of each of the seven implemented endpoints matches hand-computed values;
`curl` of each of the four stubs returns HTTP 404 with `ErrorEnvelopeWire`; `cabal test` runs
all five QuerySpec assertions green. Commands and expected output are in Validation.


## Concrete Steps

All commands are run from the repository root
`/Users/shinzui/Keikaku/bokuno/kansoku-project/kansoku` unless stated otherwise. Enter the dev
environment first (this exports `CLICKHOUSE_TCP_PORT`, `CLICKHOUSE_HTTP_PORT`, and starts the
ClickHouse dev server):

```bash
nix develop
```

Milestone 0 — locate the servant app and confirm the ClickHouse surface:

```bash
# Find where the servant Application is assembled and where warp is run.
grep -rn "serve\|hoistServer\|Application\|run \|Warp" src/

# Learn the ClickHouse module surface (connection handle, opener, insertEvents).
grep -rn "openConnection\|Connection\|insertEvents\|EventRow" src/Kansoku/ClickHouse.hs

# Confirm the rollup views and their columns against the live database.
clickhouse-client --port "$CLICKHOUSE_TCP_PORT" --query "SHOW TABLES FROM analytics"
clickhouse-client --port "$CLICKHOUSE_TCP_PORT" --query "DESCRIBE TABLE analytics.dau"
clickhouse-client --port "$CLICKHOUSE_TCP_PORT" --query "DESCRIBE TABLE analytics.page_views_by_route"
clickhouse-client --port "$CLICKHOUSE_TCP_PORT" --query "DESCRIBE TABLE analytics.identity_map"
```

Expected: `SHOW TABLES FROM analytics` lists `events_raw`, `daily_event_counts`, `dau`, `wau`,
`page_views_by_route`, `identity_map` (names may vary slightly — use the real ones). The `grep`
prints the module that calls `serve`/`hoistServer` (this is EP-4's server-assembly module you
will edit).

Milestone 1 — after creating the four modules and the test, build and test the pure core:

```bash
cabal build
cabal test
```

Expected transcript (abbreviated):

```text
Building library for kansoku-0.1.0.0..
Running 1 test suites...
Kansoku.Query
  buildSQL
    Active Users at day grain reads analytics.dau [OK]
    events count at day grain is dedup-safe        [OK]
    conversion ratio divides numerator/denominator [OK]
All 3 tests passed.
```

Load fixtures for the HTTP milestones. The fixtures are a small, known set of events across
three days so every expected number is hand-computable. Every row carries a `session_id`
(needed by `/metrics/sessions`): u1's June 1 visit is one session `s1` covering e1/e3/e4/e5,
u2's single event is session `s2`, u3's June 2 visit is `s3`, and the two return-visit events
e8/e9 (which exist so retention has day-1 returns to count: u1 returns on June 2, u3 returns
on June 3) are their own sessions `s4` and `s5`. Insert them either through EP-3's
`insertEvents` (preferred; write a tiny throwaway `cabal run` script) or directly with
`clickhouse-client`. Direct insertion (adjust column names to the real `events_raw` schema from
Milestone 0):

```bash
clickhouse-client --port "$CLICKHOUSE_TCP_PORT" --query "
INSERT INTO analytics.events_raw
  (event_id, event_name, source, occurred_at, received_at, user_id, url, session_id)
VALUES
  ('e1','page_view','web','2026-06-01 09:00:00','2026-06-01 09:00:00','u1','/home','s1'),
  ('e2','page_view','web','2026-06-01 10:00:00','2026-06-01 10:00:00','u2','/home','s2'),
  ('e3','page_view','web','2026-06-01 11:00:00','2026-06-01 11:00:00','u1','/pricing','s1'),
  ('e4','signup_started','web','2026-06-01 11:05:00','2026-06-01 11:05:00','u1','/signup','s1'),
  ('e5','signup_completed','web','2026-06-01 11:10:00','2026-06-01 11:10:00','u1','/welcome','s1'),
  ('e6','signup_started','web','2026-06-02 09:00:00','2026-06-02 09:00:00','u3','/signup','s3'),
  ('e7','page_view','web','2026-06-02 09:30:00','2026-06-02 09:30:00','u3','/home','s3'),
  ('e8','feature_used','web','2026-06-02 10:00:00','2026-06-02 10:00:00','u1','/app','s4'),
  ('e9','feature_used','web','2026-06-03 10:00:00','2026-06-03 10:00:00','u3','/app','s5'),
  ('e2','page_view','web','2026-06-01 10:00:00','2026-06-01 10:00:00','u2','/home','s2')
"
```

Note the deliberate duplicate `e2` (last row) — a replayed event — which the dedup-safe queries
must ignore (it also adds no new `session_id`, so the sessions count is unaffected). After inserting, force a merge so `FINAL`/dedup behave predictably, or rely on
`count(DISTINCT event_id)`:

```bash
clickhouse-client --port "$CLICKHOUSE_TCP_PORT" --query "OPTIMIZE TABLE analytics.events_raw FINAL"
```

If the rollup views are populated by materialized views on insert, they update automatically; if
EP-5 provides a manual refresh command, run it now (it will be named in the EP-5 plan).

Start the server (executable created by EP-1/EP-4):

```bash
cabal run kansoku-server
```

Expected: a log line indicating warp is listening on port 8080 (or the configured port).


## Validation and Acceptance

Hand-computed expectations from the fixtures above (window `from=2026-06-01`, `to=2026-06-08`,
which includes June 1 through June 7; the duplicate `e2` counts once):

- Events count per day: June 1 has 5 distinct events (e1..e5), June 2 has 3 (e6, e7, e8),
  June 3 has 1 (e9).
- Page views per day: June 1 has 3 page_view events (e1, e2, e3), June 2 has 1 (e7); e8 and e9
  are `feature_used`, not page views.
- Active users (distinct users) per day: June 1 = {u1, u2} = 2, June 2 = {u3, u1} = 2,
  June 3 = {u3} = 1.
- Sessions per day: June 1 = {s1, s2} = 2, June 2 = {s3, s4} = 2, June 3 = {s5} = 1 (the
  duplicate `e2` repeats `s2`, adding nothing).
- Conversion rate in-window: signup_completed distinct users = {u1} = 1; signup_started distinct
  users = {u1, u3} = 2; ratio = 0.5.
- Retention: first-seen days give cohort 2026-06-01 = {u1, u2} and cohort 2026-06-02 = {u3}.
  Cohort 2026-06-01: offset 0 = 2 (cohort size), offset 1 = 1 (only u1 is active on June 2; u2
  never returns). Cohort 2026-06-02: offset 0 = 1, offset 1 = 1 (u3 is active on June 3).
  Offsets 7/14/30 land on days with no activity inside the window, so they produce no points.

Bucket strings are plain `YYYY-MM-DD` dates at day grain everywhere — both the rollup reads
(`toString(day)` over a `Date` column) and the `events_raw` reads
(`toString(toDate(occurred_at))`) render dates without a time component; only the hour grain
carries a time.

Endpoint checks (server running from the previous section):

```bash
curl -s 'http://localhost:8080/metrics/events?from=2026-06-01&to=2026-06-08&timeGrain=day'
```

Expected JSON (order of points by bucket):

```json
{
  "metric": "events",
  "points": [
    { "bucket": "2026-06-01", "group": {}, "value": 5.0 },
    { "bucket": "2026-06-02", "group": {}, "value": 3.0 },
    { "bucket": "2026-06-03", "group": {}, "value": 1.0 }
  ]
}
```

```bash
curl -s 'http://localhost:8080/metrics/page-views?from=2026-06-01&to=2026-06-08&timeGrain=day'
```

```json
{
  "metric": "page_views",
  "points": [
    { "bucket": "2026-06-01", "group": {}, "value": 3.0 },
    { "bucket": "2026-06-02", "group": {}, "value": 1.0 }
  ]
}
```

```bash
curl -s 'http://localhost:8080/metrics/users?from=2026-06-01&to=2026-06-08&timeGrain=day'
```

```json
{
  "metric": "active_users",
  "points": [
    { "bucket": "2026-06-01", "group": {}, "value": 2.0 },
    { "bucket": "2026-06-02", "group": {}, "value": 2.0 },
    { "bucket": "2026-06-03", "group": {}, "value": 1.0 }
  ]
}
```

```bash
curl -s 'http://localhost:8080/metrics/sessions?from=2026-06-01&to=2026-06-08&timeGrain=day'
```

```json
{
  "metric": "sessions",
  "points": [
    { "bucket": "2026-06-01", "group": {}, "value": 2.0 },
    { "bucket": "2026-06-02", "group": {}, "value": 2.0 },
    { "bucket": "2026-06-03", "group": {}, "value": 1.0 }
  ]
}
```

```bash
curl -s 'http://localhost:8080/metrics/retention?from=2026-06-01&to=2026-06-08'
```

Default offsets are `1,7,14,30` plus the always-included `0` (cohort size); only offsets with
returning users appear:

```json
{
  "metric": "retention",
  "points": [
    { "bucket": null, "group": {"cohort": "2026-06-01", "offset": "0"}, "value": 2.0 },
    { "bucket": null, "group": {"cohort": "2026-06-01", "offset": "1"}, "value": 1.0 },
    { "bucket": null, "group": {"cohort": "2026-06-02", "offset": "0"}, "value": 1.0 },
    { "bucket": null, "group": {"cohort": "2026-06-02", "offset": "1"}, "value": 1.0 }
  ]
}
```

The day-1 retention *rate* for the 2026-06-01 cohort is `value(1) / value(0)` = 1/2 = 0.5,
computed client-side.

```bash
curl -s 'http://localhost:8080/metrics/conversion?from=2026-06-01&to=2026-06-08'
```

```json
{
  "metric": "conversion_rate",
  "points": [
    { "bucket": null, "group": {}, "value": 0.5 }
  ]
}
```

```bash
curl -s 'http://localhost:8080/metrics/funnel?from=2026-06-01&to=2026-06-08&steps=signup_started,signup_completed'
```

Expected: two points, step `signup_started` reached by 2 users (u1, u3) and
`signup_completed` reached by 1 user (u1):

```json
{
  "metric": "funnel",
  "points": [
    { "bucket": null, "group": {"step": "signup_started",   "index": "1"}, "value": 2.0 },
    { "bucket": null, "group": {"step": "signup_completed", "index": "2"}, "value": 1.0 }
  ]
}
```

Stub check (repeat for each of the four stubbed paths — `acquisition`, `feature-adoption`,
`organizations`, `custom`):

```bash
curl -s -o /dev/null -w '%{http_code}\n' 'http://localhost:8080/metrics/acquisition?from=2026-06-01&to=2026-06-08'
```

Expected: `404`. And the body:

```bash
curl -s 'http://localhost:8080/metrics/acquisition?from=2026-06-01&to=2026-06-08'
```

```json
{ "code": "not_implemented", "message": "metric endpoint is stubbed in the MVP: acquisition", "retryable": false }
```

Unit-test check (no database): `cabal test` runs `Kansoku.QuerySpec` green (three
assertions after Milestone 1, five after Milestone 4 adds the sessions and retention SQL). To
make the value of the change visible beyond compilation, break one expected-SQL string in the
test and observe the test fail with a diff, then restore it — this proves the SQL builder is
actually exercised.

The plan is accepted when: `cabal build` and `cabal test` pass; each of the seven implemented
`curl` commands returns the JSON above (numbers matching the hand-computed values); and each of
the four stub paths returns HTTP 404 with the documented shared error envelope.


## Idempotence and Recovery

Creating the five new modules and editing `kansoku.cabal`, `Kansoku.Config`, and the
server-assembly module are additive; re-running `cabal build` is safe and repeatable. If a build
fails midway, fix the reported module and rebuild — no state is left behind.

Loading fixtures is repeatable but appends rows. Because every count query is dedup-safe on
`event_id` (via `count(DISTINCT event_id)`, `FINAL`, or `uniqExact` on resolved users),
re-running the fixture INSERT does not change the expected numbers. If you want a clean slate,
`clickhouse-client --port "$CLICKHOUSE_TCP_PORT" --query "TRUNCATE TABLE analytics.events_raw"`
and re-insert; then refresh rollups per EP-5. Rollup views repopulate from the raw table.

Starting the server twice on the same port fails with an address-in-use error; stop the earlier
instance (Ctrl-C) and restart. No data is affected — the metrics endpoints are read-only.

If a rollup view is missing or empty (EP-5 not fully applied), the `/metrics/users` and
`/metrics/page-views` endpoints will return empty `points`; re-run EP-5's view creation/refresh,
confirmed via the `DESCRIBE TABLE`/`SELECT count()` checks in Milestone 0.


## Interfaces and Dependencies

Libraries used and why:
- **ClickHaskell** (`KovalevDima/ClickHaskell`) — the ClickHouse client. Chosen by the MasterPlan
  because it supports GHC 9.12.*. This plan uses its read path only. The relevant signatures
  (from the ClickHaskell `queries` reference):

  ```haskell
  -- Build a query from an explicit SQL builder (used because our aggregate SQL is dynamic):
  unsafeMkSelect :: ([(Builder, Builder)] -> Builder) -> Select columns output

  -- Execute a SELECT; the callback runs once per result block, results are concatenated:
  select :: ClickHaskell columns output
         => Select columns output -> Connection -> ([output] -> IO result) -> IO [result]
  ```

  Collect all rows with `concat <$> select sel conn pure`. The fixed result row type is:

  ```haskell
  data AggRow = AggRow
    { bucket    :: !ByteString
    , group_key :: !ByteString
    , value     :: !Double
    }
    deriving stock (Generic)
    deriving anyclass
      (ClickHaskell '[ Column "bucket" ChString, Column "group_key" ChString, Column "value" Float64 ])
  ```

  (`ChString` maps to `ByteString`; `Float64` maps to `Double`; `DateTime`/`Date` columns map to
  `UTCTime`/`Word16` — see the ClickHaskell `types` reference. We deliberately `toString(...)`
  time buckets in SQL so the Haskell side only ever decodes `ChString`.)

- **servant** / **servant-server** / **servant-multiverb** / **warp** — the HTTP layer, already
  introduced by EP-4 and normalized by EP-9. This plan uses `NamedRoutes`, `(:-)`,
  `QueryParam'`/`QueryParam`, `MultiVerb`, `AsServerT`, and `Handler`. `Day` and the metric enums
  get `FromHttpApiData` instances (from `http-api-data`) for query-param parsing.
- **aeson** (`ToJSON`/`FromJSON`), **text**, **time** (`Day`), **containers** (`Map`) — standard.

Module and signature contract that must exist at the end of each milestone (full module paths
under `src/`):

End of Milestone 1 — `Kansoku.Metrics.Definition`:

```haskell
module Kansoku.Metrics.Definition where

import Kansoku.Prelude
import Data.Aeson (Value)          -- not re-exported by the prelude
import Data.Map.Strict (Map)
import Kansoku.Metrics.Api (TimeGrain)   -- defined in the kansoku-api sub-library (see below)

data Aggregation = Count | UniqueCount | Sum | Average | Ratio
  deriving stock (Generic, Eq, Ord, Show)
data MetricDefinition = MetricDefinition
  { name :: !Text, description :: !(Maybe Text), eventNames :: ![Text]
  , aggregation :: !Aggregation, filters :: !(Map Text Value)
  , groupBy :: ![Text], timeGrain :: !(Maybe TimeGrain) }
  deriving stock (Generic, Eq, Show)
data RatioMetric = RatioMetric
  { name :: !Text, description :: !(Maybe Text)
  , numerator :: !MetricDefinition, denominator :: !MetricDefinition }
  deriving stock (Generic, Eq, Show)
-- ToJSON/FromJSON for Aggregation, MetricDefinition, RatioMetric matching spec strings.
-- TimeGrain (and its ToJSON/FromJSON/FromHttpApiData) lives in Kansoku.Metrics.Api, because
-- the servant API type needs it and the sub-library cannot depend on this main-library module.
```

`Kansoku.Metrics.Registry`:

```haskell
module Kansoku.Metrics.Registry where

import Kansoku.Prelude
import Data.Map.Strict (Map)
import Kansoku.Metrics.Definition (MetricDefinition, RatioMetric)

data BuiltinMetric = Simple !MetricDefinition | Ratioed !RatioMetric
  deriving stock (Generic, Eq, Show)
builtinMetrics :: Map Text BuiltinMetric   -- keys: "events","page_views","active_users",
  -- "new_users","returning_users","conversion_rate","activation_rate","retention",
  -- "feature_adoption","revenue","search_success_rate","funnel_completion_rate"
  -- ("events" and "page_views" back /metrics/events and /metrics/page-views)
```

`Kansoku.Metrics.Query`:

```haskell
module Kansoku.Metrics.Query where

import Kansoku.Prelude
import Data.Generics.Labels ()               -- enables #label reads in buildSQL/run
import Data.Time (Day)
import Effectful (Eff, IOE, (:>))
import Kansoku.ClickHouse (QueryPool)
import Kansoku.Metrics.Registry (BuiltinMetric)
import Kansoku.Metrics.Api (MetricPoint (..), MetricResult (..), TimeGrain)

data QueryRequest = QueryRequest
  { from :: !Day, to :: !Day, groupBy :: !(Maybe [Text]), timeGrain :: !(Maybe TimeGrain) }
  deriving stock (Generic, Eq, Show)
-- TimeGrain, MetricPoint, and MetricResult are declared in Kansoku.Metrics.Api (the kansoku-api
-- sub-library, so the servant API type stays ClickHaskell-free) and imported here:
--   data MetricPoint  = MetricPoint { bucket :: !(Maybe Text), group :: !(Map Text Text), value :: !Double }
--   data MetricResult = MetricResult { metric :: !Text, points :: ![MetricPoint] }
buildSQL :: BuiltinMetric -> QueryRequest -> Text                       -- pure, unit-tested
-- The bounded QueryPool is created once at startup and passed explicitly:
run      :: (IOE :> es) => QueryPool -> BuiltinMetric -> QueryRequest -> Eff es MetricResult
```

The `MetricResult` JSON contract (field names are `metric` and `points`; each point has
`bucket`, `group`, `value`):

```json
{ "metric": "<name>", "points": [ { "bucket": "<string|null>", "group": { "<dim>": "<val>" }, "value": 0.0 } ] }
```

End of Milestones 2–4 — the route record `Kansoku.Metrics.Api` (in the `kansoku:kansoku-api`
sub-library; its `TimeGrain` and DTOs exist from Milestone 1, the record from Milestone 2)
and the handler `Kansoku.Metrics.Handler` (main library):

```haskell
-- In the kansoku:kansoku-api sub-library (no servant-server):
module Kansoku.Metrics.Api where

import Kansoku.Prelude
import Data.Time (Day)
import Data.Map.Strict (Map)
import Kansoku.Api.Response (KansokuResult, OkResponses)
import Servant.API
import Servant.API.Generic ((:-))
import Servant.API.MultiVerb (MultiVerb)
import Servant.API.Verbs qualified as Servant

-- TimeGrain is DEFINED here (not in Kansoku.Metrics.Definition): the sub-library cannot import
-- from the main library, and this API type references TimeGrain as a query parameter. Its
-- hand-written ToJSON/FromJSON/FromHttpApiData instances parse "hour"/"day"/"week"/"month":
data TimeGrain = Hour | Day | Week | Month
  deriving stock (Generic, Eq, Ord, Show)

-- The response DTOs live here (not in Kansoku.Metrics.Query) so the route record stays free of the
-- ClickHaskell dependency. Both use strict fields + explicit deriving; their ToJSON is
-- hand-written to pin the wire field names ("metric"/"points"; "bucket"/"group"/"value"):
--   data MetricPoint  = MetricPoint { bucket :: !(Maybe Text), group :: !(Map Text Text), value :: !Double }
--     deriving stock (Generic, Eq, Show)
--   data MetricResult = MetricResult { metric :: !Text, points :: ![MetricPoint] }
--     deriving stock (Generic, Eq, Show)

type MetricQuery =
       QueryParam' '[Required] "from" Day :> QueryParam' '[Required] "to" Day
    :> QueryParam "groupBy" Text :> QueryParam "timeGrain" TimeGrain
    :> MultiVerb 'Servant.GET '[JSON]
         (OkResponses "Metric result" MetricResult)
         (KansokuResult MetricResult)

data MetricsRoutes mode = MetricsRoutes
  { events :: mode :- "metrics" :> "events" :> MetricQuery
  , pageViews :: mode :- "metrics" :> "page-views" :> MetricQuery
  , sessions :: mode :- "metrics" :> "sessions" :> MetricQuery
  , funnel :: mode :- "metrics" :> "funnel"
      :> QueryParam' '[Required] "from" Day
      :> QueryParam' '[Required] "to" Day
      :> QueryParam' '[Required] "steps" Text
      :> MultiVerb 'Servant.GET '[JSON]
           (OkResponses "Metric result" MetricResult)
           (KansokuResult MetricResult)
  , retention :: mode :- "metrics" :> "retention"
      :> QueryParam' '[Required] "from" Day
      :> QueryParam' '[Required] "to" Day
      :> QueryParam "days" Text
      :> MultiVerb 'Servant.GET '[JSON]
           (OkResponses "Metric result" MetricResult)
           (KansokuResult MetricResult)
  , acquisition :: mode :- "metrics" :> "acquisition" :> MetricQuery
  , featureAdoption :: mode :- "metrics" :> "feature-adoption" :> MetricQuery
  , conversion :: mode :- "metrics" :> "conversion" :> MetricQuery
  , users :: mode :- "metrics" :> "users" :> MetricQuery
  , organizations :: mode :- "metrics" :> "organizations" :> MetricQuery
  , custom :: mode :- "metrics" :> "custom" :> MetricQuery
  }
  deriving stock (Generic)
```

```haskell
module Kansoku.Api where

import Kansoku.Ingest.Api (IngestRoutes)
import Kansoku.Metrics.Api (MetricsRoutes)
import Kansoku.Prelude
import Servant.API (NamedRoutes)
import Servant.API.Generic ((:-))

data KansokuAPI mode = KansokuAPI
  { ingest :: mode :- NamedRoutes IngestRoutes
  , metrics :: mode :- NamedRoutes MetricsRoutes
  }
  deriving stock (Generic)

kansokuAPI :: Proxy (NamedRoutes KansokuAPI)
kansokuAPI = Proxy
```

```haskell
-- In the main kansoku library:
module Kansoku.Metrics.Handler where

import Kansoku.Prelude
import Kansoku.Api.Response (KansokuResult)
import Kansoku.ClickHouse (QueryPool)
import Kansoku.Metrics.Api (MetricResult, MetricsRoutes (..))
import Servant (Handler)
import Servant.Server.Generic (AsServerT)

metricsServer :: QueryPool -> MetricsRoutes (AsServerT Handler)
metricsServer pool =
  MetricsRoutes
    { events = metricHandler "events"
    , pageViews = metricHandler "page_views"
    , sessions = sessionsHandler
    , funnel = funnelHandler
    , retention = retentionHandler
    , acquisition = notImplemented "acquisition"
    , featureAdoption = notImplemented "feature_adoption"
    , conversion = metricHandler "conversion_rate"
    , users = metricHandler "active_users"
    , organizations = notImplemented "organizations"
    , custom = notImplemented "custom"
    }
```

`Kansoku.Server.kansokuServer` returns `KansokuAPI (AsServerT Handler)` with `ingestServer` and
`metricsServer` in their named fields. `serveWithContext kansokuAPI` consumes that record once;
there is no separate metrics application or positional handler assembly.

MasterPlan integration points honored by this plan: it reads the `analytics.events_raw` schema
and `EventRow` shape from EP-3; it reads the rollup view names and identity map from EP-5; it
extends `Kansoku.Config` and the effectful runtime per EP-1's pattern; and it adds its endpoints
to the single servant application EP-4 introduced. When committing, use Conventional Commits and
these trailers:

```text
feat(metrics): add semantic metrics layer and typed /metrics query API

MasterPlan: docs/masterplans/1-kansoku-analytics-service-mvp.md
ExecPlan: docs/plans/6-semantic-metrics-layer-and-typed-query-api.md
Intention: intention_01kwf425fxenc904ear54cr2n7
```


## Revision Notes

- 2026-07-02 — **EP-6 implementation completed.** Added `Kansoku.Api.Metrics`,
  `Kansoku.Api`, `Kansoku.Metrics.Definition`, `Kansoku.Metrics.Registry`, `Kansoku.Query`, and
  `Kansoku.Metrics.Handler`; wired the combined API into `kansoku-server`; added QuerySpec
  coverage and a repeatable `db/clickhouse/fixtures/ep6_fixtures.sql` fixture with
  `just ch-fixtures-ep6`. Live validation against ClickHouse confirmed events `5,3,1`;
  page-views-by-route `/home 2`, `/pricing 1`, `/home 1`; users and sessions `2,2,1`;
  conversion `0.5`; funnel `signup_started 2` and `signup_completed 1`; retention
  `2026-06-01/0=2`, `2026-06-01/1=1`, `2026-06-02/0=1`, `2026-06-02/1=1`; missing funnel
  `steps` returns 400; and the four deferred endpoints return documented 501 JSON. The
  implementation also records two ClickHouse/ClickHaskell discoveries: single-column result
  decoding avoids row association errors, and disabling ClickHouse expression/sort compilation
  avoids local LLVM `std::bad_alloc` failures for these bounded API reads.

- 2026-07-01 — **adopted the shared haskell-jitsurei/core coding standards in every Haskell code
  sketch.** The plan's design is unchanged — the same five implemented / six stubbed endpoint
  set, the same `MetricDefinition`/`RatioMetric`/`BuiltinMetric` shapes, the same uniform
  three-column `AggRow` decode, the same ClickHouse dedup strategy (`count(DISTINCT event_id)` /
  `FINAL` / identity-resolved `uniqExact`) — only the Haskell style was brought into compliance
  with `/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/core/` (`standards.md`,
  `custom-prelude.md`, `record-patterns.md`, `multiline-strings.md`). What changed and why:
  - Added a "Coding standards" paragraph to Context and Orientation pointing at the core docs and
    at EP-1's `Kansoku.Prelude` + the shared `common` cabal stanza, so a novice knows the house
    rules before reading any sketch.
  - Every module sketch now imports `Kansoku.Prelude` and uses postpositive `qualified` imports
    (e.g. `import Data.Text qualified as Text`).
  - The data records — `MetricDefinition`, `RatioMetric`, `BuiltinMetric`, `QueryRequest`,
    `MetricPoint`, `MetricResult`, `AggRow`, and the `Aggregation`/`TimeGrain` sum types — now use
    strict `!` fields and explicit `deriving stock (...)` (plus `deriving anyclass (ClickHaskell
    …)` for `AggRow`), replacing the lazy fields and bare `deriving (Eq, Show, Generic)`. Their
    hand-written `ToJSON`/`FromJSON`/`FromHttpApiData` instances (which pin the JSON to the spec
    strings) are unchanged.
  - `buildSQL` now ships a concrete sketch that emits its ClickHouse SQL as `"""..."""`
    MultilineStrings (the `analytics.dau` rollup read, the dedup-safe events count, and the
    numerator/denominator ratio), with per-request literals spliced into `{{...}}` placeholders
    via `Data.Text.replace` and window bounds read through generic-lens `#label`
    (`req ^. #from` / `#to`); this makes the multiline-strings and `#label` standards concrete
    at the plan's most important function. Each module that reads/updates records via `#label`
    adds `import Data.Generics.Labels ()`.
  Explicitly unchanged: the endpoint set (5 implemented / 6 stubbed at HTTP 501), the
  `kansoku:kansoku-api` sub-library structure, the ClickHouse dedup strategy, all
  Decision-Log-reconciled content, the fixtures and hand-computed acceptance numbers, and the
  commit-trailer example above.

- 2026-07-01 — **removed record field-name prefixes for standards compliance.** Per the
  "No Field Prefixes" rule in `/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/core/record-patterns.md`,
  every record field was de-prefixed, relying on `DuplicateRecordFields` (already enabled by the
  shared `common` cabal stanza) to allow the now-shared names across records: `MetricDefinition`
  (`metricName`→`name`, `metricDescription`→`description`, `metricEventNames`→`eventNames`,
  `metricAggregation`→`aggregation`, `metricFilters`→`filters`, `metricGroupBy`→`groupBy`,
  `metricTimeGrain`→`timeGrain`), `RatioMetric` (`ratioName`→`name`, `ratioDescription`→`description`,
  `ratioNumerator`→`numerator`, `ratioDenominator`→`denominator`), `QueryRequest`
  (`qFrom`→`from`, `qTo`→`to`, `qGroupBy`→`groupBy`, `qTimeGrain`→`timeGrain`), `MetricPoint`
  (`mpBucket`→`bucket`, `mpGroup`→`group`, `mpValue`→`value`), and `MetricResult`
  (`mrMetric`→`metric`, `mrPoints`→`points`). The `#label` reads in `buildSQL` were updated to
  match (`req ^. #from`/`#to`, `r ^. #numerator . #eventNames`). This also makes `MetricDefinition`
  mirror the spec's TypeScript field names exactly, and — because the generic wire form keys off
  the field names — makes the JSON response keys clean (`metric`/`points`, `bucket`/`group`/`value`)
  for both the API responses and EP-8's OpenAPI schema. The design is otherwise unchanged: the
  5-implemented / 6-stubbed endpoint set, the ClickHouse dedup strategy, the rollup view names, the
  `buildSQL` MultilineString SQL text, the `kansoku:kansoku-api` sub-library structure, and the
  servant types' shape are all untouched.

- 2026-07-01 — **validation blockers fixed, architecture review applied, and two user scope
  decisions incorporated (retention and sessions are now implemented, not stubbed).** The
  changes, and why each was made:
  - **BLOCKER — rollup reads rewritten as merge + GROUP BY.** EP-5's `analytics.dau`,
    `analytics.wau`, and `analytics.page_views_by_route` are `AggregatingMergeTree` tables whose
    `users`/`views` columns hold `AggregateFunction(uniqExact, String)` partial states, and
    parts are not pre-merged — so the earlier draft's `toFloat64(users)` with no `GROUP BY` was
    a ClickHouse type error. Every rollup read now uses `uniqExactMerge(...)` under `GROUP BY`
    on the rollup's key columns (`day`; `week` for `wau` — the draft also wrongly keyed WAU on
    `day`; `(day, route)` for page views). Cascaded to: the `dauTemplate` sketch, the rollup
    rules (four exact SQL examples added), the QuerySpec expectations, the Decision Log (new
    entry), and the Context prose, which no longer describes the rollups as plain
    pre-aggregated counts and no longer calls `analytics.identity_map` a "rollup view" (it is a
    `ReplacingMergeTree` lookup table). While fixing bucket rendering, the day-grain bucket
    expression changed from `toStartOfDay` (a `DateTime`, rendering `2026-06-01 00:00:00`) to
    `toDate` (a `Date`, rendering `2026-06-01`), so `events_raw`-served and rollup-served
    buckets now render identically; all acceptance transcripts use plain dates.
  - **BLOCKER — `TimeGrain` module home corrected.** The draft defined `TimeGrain` in
    `Kansoku.Metrics.Definition` (main library) while `Kansoku.Api.Metrics` (sub-library)
    imported it — an impossible dependency direction. Per the MasterPlan's integration point,
    `TimeGrain` (with its `FromHttpApiData`/JSON instances) now lives in `Kansoku.Api.Metrics`,
    which Milestone 1 creates first; `Kansoku.Metrics.Definition` imports it. All four sketches,
    the cabal-edit instructions, the files list, and the Interfaces contract were updated, and a
    Decision Log entry records it.
  - **Registry gained `events` and `page_views` entries** (a `Count` over all events — empty
    `eventNames` now explicitly means "no event_name filter" — and a `Count` filtered to
    `page_view`), because `/metrics/events` and `/metrics/page-views` had no registry key to
    look up. Twelve built-ins total; handler descriptions now name the keys they look up.
  - **Funnel `steps` is `QueryParam' '[Required] "steps" Text`** — a single comma-separated
    ordered list, since servant's `QueryParam` cannot repeat; the Milestone 3 "repeated/
    comma-separated" wording was fixed and a missing `steps` now 400s at the servant layer.
  - **`run`'s signature pinned** to `run :: (IOE :> es) => Connection -> BuiltinMetric ->
    QueryRequest -> Eff es MetricResult`: EP-3 exposes a plain ClickHaskell `Connection`, no
    bespoke effect, and the connection is threaded from the server wiring per EP-1's
    Reader-`Config` pattern (`metricsServer` likewise takes the `Connection`). The "whatever
    ClickHouse effect EP-3 exposes" hedge was removed.
  - **USER SCOPE DECISION (2026-07-01, superseding the 501-stub decision): `/metrics/retention`
    implemented** as a query-time cohort computation over `analytics.events_resolved` (no
    rollup; deliberately unoptimized for MVP): cohort day = first-seen day within the window;
    offsets from an optional comma-separated `days` param defaulting to `1,7,14,30`, with
    offset 0 (cohort size) always included so clients can compute rates as
    `value(k)/value(0)`. New Milestone 4 carries the SQL sketch (first-seen CTE joined to a
    distinct-activity CTE), fixtures, transcript, and QuerySpec assertion.
  - **USER SCOPE DECISION (2026-07-01, superseding the 501-stub decision): `/metrics/sessions`
    implemented** as `uniqExact(session_id)` over `analytics.events_raw` bucketed by
    `timeGrain` — counts only, no durations/boundaries (sessionization proper stays deferred).
    `session_id` is `Nullable(String)`; ClickHouse aggregates skip NULLs and the query filters
    `session_id != ''` defensively. SQL sketch, fixtures (every row now carries a
    `session_id`), transcript, and QuerySpec assertion added.
  - **Implemented/stubbed enumeration updated everywhere** (Purpose, Progress, Decision Log,
    milestones, Validation): seven implemented — `events`, `page-views`, `sessions`, `funnel`,
    `retention`, `conversion`, `users`; four stubbed at 501 — `acquisition`,
    `feature-adoption`, `organizations`, `custom`. The stub-check example moved from
    `/metrics/retention` (now implemented) to `/metrics/acquisition`. Milestones renumbered:
    the stub freeze moved from Milestone 3 into the new Milestone 4. Fixtures gained e8/e9
    (return visits on June 2/3) so retention has day-1 returns; the events/users hand-computed
    numbers and transcripts were recomputed accordingly.
  - **Precision paragraph and FINAL-avoidance rule added** (Milestone 2): rollup-served numbers
    resolve identity at insert time (frozen at ingestion) while `events_resolved`-served
    numbers resolve at query time, so they can legitimately disagree after late identify
    events — `/metrics/users` serves rollup precision; `/metrics/conversion`, `/metrics/funnel`,
    `/metrics/retention` serve query-time precision; the event/session counters are unaffected
    by identity. And because `uniqExact` over `event_id`/`canonical_user`/`session_id` is
    duplicate-tolerant, none of this plan's queries add `FINAL`; `FINAL` is reserved for reads
    where row multiplicity matters (e.g. a future `Sum`-based Revenue).

- 2026-07-18 — **Plan 9 alignment.** Updated the live metrics contract to
  `Kansoku.Metrics.Api.MetricsRoutes`, the `KansokuAPI` umbrella record, MultiVerb's shared
  error tail, and `QueryPool -> MetricsRoutes (AsServerT Handler)` server assembly. Historical
  Progress entries remain unchanged.
