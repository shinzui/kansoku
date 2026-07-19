---
id: 17
slug: queryable-event-properties-typed-storage-and-property-based-grouping
title: "Queryable event properties: typed storage and property-based grouping"
kind: exec-plan
created_at: 2026-07-15T21:43:59Z
intention: intention_01kxxscv06exbvqdtefzqnf9h5
master_plan: "docs/masterplans/3-kansoku-analytics-extensions-queryable-properties-multi-signal-identity-and-experiment-analytics.md"
---

# Queryable event properties: typed storage and property-based grouping

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Kansoku events carry a free-form `properties` JSON object — a payment event carries
`{"amount": 49.0, "plan": "pro"}`, a feature event carries `{"feature": "search"}` — but
today those properties are capturable and not analyzable. They are stored in ClickHouse as a
raw JSON string, so every property-dependent question pays to string-parse the JSON of every
scanned row, and the query layer cannot even express the question: the group-by whitelist in
`kansoku-core/src/Kansoku/Metrics/Query.hs` admits only `event_name`, `source`, and `route`; the
`filters` field on `MetricDefinition` is completely ignored by the query compiler; and the
`Sum`/`Average` aggregations hardcode the property name `'amount'` into their SQL, so a
metric summing anything else is impossible to declare. The `feature_adoption` builtin metric
even declares `groupBy ["feature"]` — a property — and the compiler silently ignores it,
returning ungrouped numbers; the endpoint itself is stubbed at HTTP 501.

After this plan, declared event properties are first-class analytics dimensions. A developer
ingests `payment_completed` events with `{"amount": 49.0, "plan": "pro"}` via curl, asks
`GET /metrics/revenue?groupBy=prop:plan`, and gets per-plan revenue sums. `GET
/metrics/feature-adoption?groupBy=prop:feature` returns distinct users per feature (the
endpoint comes off its 501 stub). Asking to group by a property that no queried event
declares returns HTTP 400 naming the property. Under the hood, ClickHouse reads properties
through a typed storage representation chosen by a benchmark in Milestone 1 — never by
`JSONExtract*` string-parsing of the raw column — and `MetricDefinition` gains an explicit
`aggregationProperty` so `revenue` declares `amount` instead of the compiler assuming it.
This is the enabling layer for experiment analytics (EP-19,
`docs/plans/19-experiment-analytics-assignment-events-variant-rollups-and-per-variant-metrics.md`),
whose per-variant metrics are exactly "group by the `variant` property".


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-07-19 18:17Z) M0: reconciled this plan against the post-MasterPlan-2 tree (see
      "Reconcile at start" in Context and Orientation); recorded deltas in the Decision Log
- [x] (2026-07-19 18:24Z) M1: benchmark fixture table `analytics.prop_bench_raw` created
      and populated (10M rows)
- [x] (2026-07-19 18:24Z) M1: candidate expressions validated on the pinned server (exact working SQL for
      string group, float aggregate, equality filter per candidate recorded in Decision Log)
- [x] (2026-07-19 18:24Z) M1: benchmark protocol run; latency/read-bytes/storage numbers captured in
      Surprises & Discoveries
- [x] (2026-07-19 18:24Z) M1: storage representation decided; Decision Log entry written here AND MasterPlan 3
      Integration Points ("Properties storage representation") updated
- [x] (2026-07-19 18:29Z) M1: versioned migration for the chosen representation written,
      applied via `just ch-migrate`, ledger-recorded; bench table dropped
- [x] (2026-07-19 18:37Z) M2: `feature_used` and `payment_completed` schemas added to
      `defaultRegistry`
- [x] (2026-07-19 18:37Z) M2: `MetricDefinition.aggregationProperty` added; `revenue`
      declares `"amount"`; builtin-registry unit test asserts every Sum/Average declares a
      numeric property
- [ ] M2: Sum/Average compiler uses `aggregationProperty` instead of a hardcoded `amount`
- [ ] M2: property group-by (`prop:<name>`) parsing + registry validation + SQL rendering
- [ ] M2: `MetricDefinition.filters` wired into compiled WHERE clauses
- [ ] M2: `feature_adoption` definition groupBy honored as default grouping; endpoint
      un-stubbed
- [ ] M2: `QuerySpec` golden SQL tests for all new shapes; `cabal test` green
- [ ] M3: `groupBy` query-param documentation extended in the metrics route record;
      OpenAPI document regenerated and client compiles in the same commit
- [ ] M3: account scoping verified present in every new SQL shape
- [ ] M3: end-to-end transcripts captured (revenue by plan, feature adoption by feature,
      400 for undeclared property) and pasted into Validation and Acceptance
- [ ] Outcomes & Retrospective written


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

Pre-implementation research findings (2026-07-15, plan authoring):

- The dev shell pins ClickHouse 26.5 — far past the 24.8 release where the native `JSON`
  column type became production-ready. Verified live:

  ```text
  $ nix develop --command clickhouse-client --version
  ClickHouse client version 26.5.1.882.
  ```

- The ClickHaskell client library (pinned checkout at
  `/Users/shinzui/Keikaku/hub/haskell/clickhaskell-project/`; confirm with
  `mori registry show KovalevDima/ClickHaskell --full`) has NO wire support for the `JSON`
  or `Map(K,V)` column types. Its complete type inventory is the modules under
  `ClickHaskell/library/ClickHaskell/Primitive/`: Array, Bool, Date, DateTime, Decimal,
  Enum, Float, Int, LowCardinality, Nullable, String, UInt, UUID. Consequence: whatever
  representation Milestone 1 picks must never cross the client wire. Every candidate in
  this plan is therefore a `MATERIALIZED` column computed server-side from the existing
  `properties` String column — the writer's insert block (`EventRow`) is untouched, and
  reads only ever return plain strings/floats through the aggregate row shape.

- The `feature_adoption` builtin queries event `feature_used` and `revenue` queries
  `payment_completed`, but neither event is declared in `defaultRegistry`
  (`kansoku-api/src/Kansoku/Event/Registry.hs` declares only `page_view`, `session_start`,
  `identify`, `user_registered`, `subscription_started`). Since this plan makes the
  registry the gate for property grouping, both schemas must be added (Milestone 2) or the
  two flagship examples would 400 on their own properties.

Implementation findings (2026-07-19, Milestone 1):

- The local ClickHouse server does not create `system.query_log`, so the planned query-log
  read-byte capture was unavailable. ClickHouse's `FORMAT JSON` statistics reported the
  same `rows_read` and `bytes_read` fields without changing the four-row aggregate result;
  those values are captured below. This changes only the evidence source, not the queries.
- Repeated grouped aggregates with ClickHouse expression compilation enabled eventually
  failed with `std::bad_alloc` in the constrained local process. Kansoku's production
  `aggSelect` already sets `compile_expressions = 0`, `compile_aggregate_expressions = 0`,
  and `compile_sort_description = 0`; rerunning every candidate with those exact settings
  completed five times without error. The medians below therefore model the shipped query
  path and use the same settings for every candidate.
- Five-run median seconds, followed by one representative JSON-statistics read measurement:

  ```text
                         raw JSONExtract   native JSON   typed columns   Map(String,String)
  grouped sum(amount)          0.272          0.043          0.011            0.105
  filter plan = pro            0.046          0.011          0.003            0.015
  group/count by plan          0.148          0.024          0.011            0.037

  aggregate bytes read       350.3 MB       392.5 MB        90.0 MB          170.3 MB
  group-only bytes read      350.3 MB       222.5 MB        10.0 MB           82.5 MB

  compressed storage:
    properties raw String       4.38 MiB
    properties_json JSON        1.49 MiB (34% of raw)
    prop_plan + prop_amount     0.63 MiB (14% of raw)
    props_map Map               5.65 MiB (129% of raw)
  ```

  Native JSON and typed columns both pass the grouped-latency threshold (at most one third
  of 0.272 seconds) and storage threshold (at most 60% of 4.38 MiB). The map candidate
  fails both. Native JSON wins by the plan's declared preference order because it avoids a
  new migration whenever the registry gains a property.
- Migration `0009_typed_properties.sql` applied once and skipped on the second runner pass.
  A fresh `payment_completed` storage probe returned `plan = pro` and `amount = 49` through
  `toString(properties_json.plan)` and `CAST(properties_json.amount, 'Float64')`; the
  ledger contained exactly one row and `EXISTS TABLE analytics.prop_bench_raw` returned 0
  after cleanup.


## Decision Log

Record every decision made while working on the plan.

- Decision: Decide the storage representation by benchmark, not by fiat. Milestone 1 runs a
  fixed protocol (fixtures, timings, storage sizes, acceptance thresholds written below)
  over three candidates and adopts the first that passes, with a stated preference order.
  Rationale: the three candidates have genuinely different cost profiles (per-query parse
  cost vs. per-property DDL churn vs. type erasure) and the pinned server version's JSON
  maturity is exactly the kind of thing that must be measured, not remembered. The plan's
  job is the protocol; the recommendation (native JSON first, materialized per-property
  columns as fallback) is a prior, not a preordained answer.
  Date: 2026-07-15

- Decision: Property grouping and filtering accept ONLY properties declared in the event
  registry for the queried events — never arbitrary JSON paths from the request.
  Rationale: two independent safety arguments. Injection: a property name is spliced into
  SQL (as a subcolumn path, a materialized column name, or a map key); an arbitrary
  user-supplied path would reopen exactly the injection class MP-2 EP-13 closed. Cardinality:
  grouping is only meaningful (and only cheap) on dimensions someone declared as such;
  arbitrary paths invite accidental group-by over unbounded-cardinality values. The registry
  (`kansoku-api/src/Kansoku/Event/Registry.hs`) already exists as the declaration point.
  Date: 2026-07-15

- Decision: `MetricDefinition` gains `aggregationProperty :: Maybe Text`; the query
  compiler's Sum/Average path uses it; the hardcoded `JSONExtractFloat(properties,
  'amount')` is deleted. `revenue` declares `aggregationProperty = Just "amount"`.
  Rationale: the hardcoding means every Sum/Average metric silently aggregates `amount`
  whatever its intent — a correctness smell and a dead end for EP-19's metrics. An explicit
  field makes the definition self-describing and lets the compiler reject Sum/Average
  definitions that forgot to declare a property instead of guessing.
  Date: 2026-07-15

- Decision: Wire syntax for property grouping is an explicit prefix: `groupBy=prop:plan`.
  Bare names keep their existing meanings (`event_name`, `source`, `route`); bare names
  that are neither builtins nor `prop:`-prefixed are rejected with HTTP 400.
  Rationale: an explicit namespace can never collide with current or future builtin
  dimensions (EP-18/EP-19 will add more), makes requests self-documenting, and gives the
  parser an unambiguous grammar. Resolving bare names against the registry was considered
  and rejected: `groupBy=source` would then mean a builtin today and could shadow a declared
  property tomorrow. Definition-side `groupBy` entries (Haskell, in
  `Kansoku.Metrics.Registry`) remain bare property names — they are trusted code, not wire
  input — and are resolved against the registry at compile time (this is how
  `feature_adoption`'s `["feature"]` becomes meaningful).
  Date: 2026-07-15

- Decision: All candidates are implemented as `MATERIALIZED` columns derived from the
  existing `properties` String column; the ClickHaskell insert path is not modified.
  Rationale: ClickHaskell has no JSON/Map wire types (see Surprises & Discoveries).
  MATERIALIZED columns are computed by the server on insert, are not part of the insert
  block, and are excluded from `SELECT *`, so the client never needs to encode or decode
  them. This also means zero risk to the ingest hot path.
  Date: 2026-07-15

- Decision: Reconcile EP-17 to the landed vertical-slice names and migration ledger. The
  query compiler is `Kansoku.Metrics.Query` in
  `kansoku-core/src/Kansoku/Metrics/Query.hs`, its validation module is
  `Kansoku.Metrics.Query.Validate`, the served contract is
  `kansoku-api/src/Kansoku/Metrics/Api.hs`, and the property boundary will be
  `Kansoku.Metrics.Query.Property`. Migration `0008_account_scoped_metrics.sql` is already
  applied by EP-15, so the typed-properties migration takes `0009`. The landed compiler
  uses typed ClickHaskell result rows, native `{account_id:String}` parameters, and the
  frozen six-column `analytics.events_resolved` contract exactly as expected. The clean
  baseline is `cabal build all` plus `cabal test all`: 92 core examples with 0 failures
  and 12 ClickHouse-dependent pending examples; 10 client examples with 0 failures and
  1 live-server pending example.
  Rationale: M0 must make the ExecPlan's paths and migration claims match the actual
  post-MasterPlan-2 working tree before implementation begins.
  Date: 2026-07-19

- Decision: Choose candidate (a), one server-side native `JSON` materialized column:
  `properties_json JSON MATERIALIZED CAST(properties, 'JSON')`. The compiler emits
  `toString(properties_json.<name>)` for group keys and string equality,
  `CAST(properties_json.<name>, 'Float64')` for numeric aggregation, and compares the
  typed expression directly for numeric and boolean filters. On 10 million rows the
  five-run median grouped aggregate was 0.043 seconds versus 0.272 seconds for raw
  `JSONExtract*` (6.3 times faster), and the column added 1.49 MiB versus the raw
  `properties` column's 4.38 MiB (34%). Registry-driven typed columns were faster at
  0.011 seconds but would require property-by-property DDL; the native JSON candidate also
  passes every criterion and therefore wins the plan's declared preference order.
  Rationale: native JSON gives declared properties typed, subcolumn-readable storage while
  allowing EP-20 to add declarations without ClickHouse schema churn. The materialized
  column remains server-side and never crosses ClickHaskell's wire.
  Date: 2026-07-19


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

Kansoku is a first-party analytics service written in Haskell (GHC 9.12.4, nix flake). Four
cabal packages: `kansoku-api` (servant route types and DTOs — the wire contract, shared by
everything), `kansoku-core` (server logic: ingest, ClickHouse writer, query compiler,
handlers), `kansoku-server` (the executable), `kansoku-client` (the Haskell SDK, derived
from the same servant types). Build with `just build` (`cabal build all`), test with `just
test` (`cabal test`), run local services (Postgres with pgmq, ClickHouse) with
`process-compose up` inside `nix develop`. `clickhouse-client` is on PATH inside the dev
shell; the local server listens on `$CLICKHOUSE_TCP_PORT` (9000).

The data path: HTTP ingest validates an `AnalyticsEvent`
(`kansoku-api/src/Kansoku/Event/Types.hs`; its `properties :: Object` field is an aeson
`KeyMap Value`, i.e. an arbitrary JSON object) and enqueues it on a durable Postgres pgmq
queue; a batched writer converts each event to an `EventRow`
(`kansoku-core/src/Kansoku/ClickHouse/EventRow.hs`) and inserts batches into
`analytics.events_raw`. `EventRow.properties` is a `ByteString` produced by
`objectBytes = LBS.toStrict . Aeson.encode . Aeson.Object` — the properties object
serialized to a JSON string — and lands in a plain `String` column (see
`db/clickhouse/migrations/0001_events_raw.sql`, superseded by the v2 table below). Because
`properties` always comes from a successfully parsed aeson `Object`, the stored string is
always valid JSON — a fact the materialization expressions below rely on.

The event registry (`kansoku-api/src/Kansoku/Event/Registry.hs`) is an in-code map from
`EventName` to `EventSchema`. An `EventSchema` holds `schemaProperties :: [PropertySpec]`
where `PropertySpec { propName :: Text, propType :: PropertyType, propRequired :: Bool }`
and `PropertyType = PTString | PTNumber | PTBool | PTObject | PTArray | PTAny`.
`defaultRegistry` currently declares five events. This registry is the source of truth for
"which properties are declared" throughout this plan. (EP-20,
`docs/plans/20-event-schema-governance-versioned-registry-and-portfolio-event-contracts.md`,
will later version and externalize the registry; this plan must work against the in-code
registry and does.)

The metrics layer: `kansoku-core/src/Kansoku/Metrics/Definition.hs` defines
`MetricDefinition { name, description, eventNames, aggregation, filters :: Map Text Value,
groupBy :: [Text], timeGrain }` and `Aggregation = Count | UniqueCount | Sum | Average |
Ratio`. `kansoku-core/src/Kansoku/Metrics/Registry.hs` declares the builtin metrics —
notably `revenue` (Sum over `payment_completed`, today with no way to say which property to
sum) and `featureAdoption` (UniqueCount over `feature_used` with `groupBy ["feature"]`,
which the compiler ignores — the latent bug this plan fixes). The query compiler
(`kansoku-core/src/Kansoku/Metrics/Query.hs`) builds SQL text per metric; its `groupExpr` maps only
`event_name`/`source`/`route` to fixed expressions and everything else to `''`; its
`propertyAggregateSQL` hardcodes `JSONExtractFloat(properties, 'amount')`; nothing reads
`filters`. Handlers live in `kansoku-core/src/Kansoku/Metrics/Handler.hs` (the
`feature-adoption`, `acquisition`, `organizations`, and `custom` endpoints are HTTP 501
stubs; this plan un-stubs `feature-adoption` only). The route types are in
`kansoku-api/src/Kansoku/Metrics/Api.hs`. Golden SQL tests are in
`kansoku-core/test/Kansoku/QuerySpec.hs`.

Terms used below. A "materialized column" is a ClickHouse column whose value is computed by
the server from an expression over other columns at insert time (and backfilled for existing
rows by `ALTER TABLE … MATERIALIZE COLUMN`); it is not sent by inserting clients and is not
returned by `SELECT *`. The "native JSON type" is ClickHouse's `JSON` column type
(production-ready since 24.8): it shreds JSON documents into typed subcolumns at insert
time, so reading one path (`properties_json.plan`) reads only that subcolumn's data, not the
whole document. A "subcolumn read" is that path access; on the pinned server a subcolumn of
`JSON` has type `Dynamic` and is converted with `toString(…)` / `CAST(…, 'Float64')` (exact
forms are pinned by the Milestone 1 prototype). The "migration ledger" is the
`analytics.schema_migrations` table introduced by MP-2 EP-12 (below).

### What MasterPlan 2 will have changed (reconcile at start)

This plan runs strictly AFTER MasterPlan 2
(`docs/masterplans/2-kansoku-production-hardening-review-fixes-and-portfolio-service-readiness.md`)
and describes the repository as it will exist then. Before writing any code, verify each of
the following against the actual tree; where reality differs, adapt and record the delta in
this plan's Decision Log. The contracts, with the plan files that establish them:

- Versioned ClickHouse migrations — `docs/plans/12-clickhouse-schema-v2-sort-key-final-free-resolution-join-free-rollups.md`.
  `db/clickhouse/migrate.sh` applies only unapplied files from `db/clickhouse/migrations/`
  in filename order, recording each in `analytics.schema_migrations` (MergeTree, `ORDER BY
  filename`); `just ch-migrate` invokes it; applied files are immutable — new DDL means a
  new numbered file. EP-12 plans files 0004–0007, so this plan's migrations are expected to
  start at `0009` (check `ls db/clickhouse/migrations/` and take the next unused number).
  EP-12's v2 `analytics.events_raw` keeps `properties String` and has sort key
  `ORDER BY (account_id, event_name, occurred_at, event_id)`.
- Rewritten validated query builders — `docs/plans/13-safe-and-correct-metric-sql-validated-inputs-ordered-funnels-honest-failures.md`.
  Module `Kansoku.Metrics.Query.Validate` exists with an opaque `SqlName` smart constructor
  (`mkSqlName :: Text -> Either Text SqlName`, charset `^[a-z0-9_.:-]{1,128}$`); user
  inputs that reach SQL are validated or parameterized, and invalid input yields HTTP 400
  with a JSON body naming the offending value. This plan extends that discipline to
  property names (with a slightly different charset, justified below), never bypasses it.
- Typed row decoding — `docs/plans/11-split-clickhouse-connections-and-adopt-typed-row-decoding.md`.
  The `concat(…, '\t', …)`/`splitOn` line-decoding hack and `AggLine` are gone; query
  results decode via typed columns and decode failures are loud. New SQL shapes added here
  must keep the `bucket`/`group_key`/`value` output shape the decoder expects (whatever its
  post-EP-11 form is) and must not reintroduce string splitting.
- Account-scoped authenticated queries — `docs/plans/15-api-keys-service-auth-and-account-scoped-queries.md`
  (still a skeleton at authoring time; its contract is stated in MasterPlan 2's Integration
  Points). `QueryRequest` carries an account predicate threaded through every SQL builder.
  Every new SQL shape this plan emits MUST include that predicate — property grouping must
  not become an unscoped side door. Requests in the transcripts below need whatever
  authentication EP-15 establishes; the transcripts note where a key/header goes.
- NamedRoutes API + same-commit contract discipline —
  `docs/plans/9-convert-kansoku-to-namedroutes-vertical-slices-and-multiverb.md` and
  `docs/plans/14-sdk-grade-ingest-contract-partial-batch-acceptance-cors-and-payload-limits.md`.
  The metrics routes are a `MetricsRoutes mode` record in
  `kansoku-api/src/Kansoku/Metrics/Api.hs` (fields like `featureAdoption :: mode :-
  "metrics" :> "feature-adoption" :> MetricQuery`); the OpenAPI document is generated from
  the served type by the `kansoku-openapi` executable into `docs/api/openapi.json`, with a
  CI check `cabal run kansoku-openapi && git diff --exit-code docs/api/openapi.json`. Any
  wire-contract change here regenerates the OpenAPI document and keeps `kansoku-client`
  compiling in the same commit.

Code standards for all Haskell written here (see
`/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/core/`): GHC2024, import `Kansoku.Prelude`
everywhere, postpositive qualified imports (`import Data.Map.Strict qualified as Map`),
generic-lens `#label` optics, strict fields, explicit deriving strategies, and
`MultilineStrings` for embedded SQL where a literal is clearer than concatenation.


## Plan of Work

The work is three milestones. Milestone 1 is a prototyping milestone: it produces evidence,
a decision, and one migration. Milestone 2 makes the query compiler property-aware.
Milestone 3 extends the wire contract and proves the whole path end-to-end. Each milestone
ends with a commit (or several small ones) using conventional-commit messages carrying the
trailers listed in Concrete Steps.

### Milestone 1 (prototyping) — storage representation: benchmark, decide, migrate

Scope: decide, with measurements on the pinned ClickHouse server, how event properties
become queryable columns; then land exactly one versioned migration implementing the
decision. This milestone is explicitly a prototype-then-promote exercise: the bench table
and all three candidate columns are scratch work that is dropped; only the winner's
migration is kept. At the end, `analytics.events_raw` has the chosen representation, the
migration is ledger-recorded, and both this plan's Decision Log and MasterPlan 3's
Integration Points ("Properties storage representation") name the choice and the evidence.

The three candidates, all `MATERIALIZED` from the existing `properties` String column
(mandatory — see the ClickHaskell finding in Surprises & Discoveries):

(a) One native `JSON` column. `properties_json JSON MATERIALIZED CAST(properties, 'JSON')`.
Every property — declared or not — becomes subcolumn-readable; reads of one property read
O(that subcolumn); no DDL churn when the registry grows. Risks to measure: storage overhead
of shredding, subcolumn read performance, and the exact `Dynamic`-conversion syntax the
server accepts.

(b) Registry-driven materialized columns. For each `PropertySpec` of each declared
`EventSchema`, a real typed column: `prop_plan LowCardinality(String) MATERIALIZED
JSONExtractString(properties, 'plan')`, `prop_amount Float64 MATERIALIZED
JSONExtractFloat(properties, 'amount')`, and so on (`PTString → LowCardinality(String)`,
`PTNumber → Float64`, `PTBool → UInt8`, `PTObject`/`PTArray`/`PTAny` → excluded from
materialization, groupable only if the decision is (a)). Hot properties become first-class
columns with ClickHouse's best compression and scan speed. Costs: an `ALTER TABLE … ADD
COLUMN … MATERIALIZED` + `MATERIALIZE COLUMN` migration every time the registry gains a
property (a generator emits the DDL from the Haskell registry, but each run is still a
ledger migration), and name collisions/renames become schema events. Until EP-20 gives the
registry a stable external declaration format, the generator reads the in-code
`defaultRegistry` — state this in the generated file header.

(c) A `Map(String, String)` shadow column: `props_map Map(String, String) MATERIALIZED
CAST(JSONExtractKeysAndValues(properties, 'String'), 'Map(String, String)')`. Reads are
`props_map['plan']`. Simple and uniform, but it stringifies everything — numeric
aggregation needs per-query casts, and map key reads historically scan the whole map column
for a row. Least preferred; kept as a candidate because it is the simplest possible thing
and the benchmark should show, with numbers, why it loses (or surprise us).

Benchmark protocol (exact commands in Concrete Steps): create a scratch table
`analytics.prop_bench_raw` with the minimal shape (`account_id String, event_name
LowCardinality(String), occurred_at DateTime64(3,'UTC'), event_id String, properties
String`, MergeTree with the v2 sort key); insert 10,000,000 rows of realistic
`payment_completed`-shaped JSON (4 plan values, ~500 distinct amounts, 20 accounts) via
`INSERT … SELECT … FROM numbers(10000000)`; add all three candidate columns via `ALTER
TABLE`, backfill each with `MATERIALIZE COLUMN`, and wait for mutations to finish. Then run
four query shapes per representation — (1) grouped aggregate: sum of `amount` grouped by
`plan`; (2) filtered count: count where `plan = 'pro'`; (3) point read of one property over
the full table (group by `plan` alone); (4) the raw-`JSONExtract*` baseline of shape (1) —
each five times with `FORMAT Null`, taking the median of `clickhouse-client --time`, and
capture `read_rows`/`read_bytes`/`query_duration_ms` from `system.query_log` plus
per-column `data_compressed_bytes` from `system.columns`. Record every number in Surprises
& Discoveries.

Acceptance criteria for the decision (write the outcome in the Decision Log): a candidate
is adoptable only if, at 10M rows, (i) its median grouped-aggregate latency is at most one
third of the raw-`JSONExtract` baseline, (ii) its added compressed storage is at most 60%
of the compressed size of the raw `properties` column, and (iii) all three SQL expression
kinds the compiler will emit (string group key, Float64 aggregate argument, string equality
predicate) execute correctly on the pinned server, with the exact working syntax recorded.
Among adoptable candidates, prefer (a), then (b), then (c) — (a) is recommended because it
serves undeclared-but-later-declared properties without schema churn; (b) is the fallback
if native JSON disappoints on this server; adopt both only if the benchmark shows (a)
adequate for grouping but materially worse for the aggregate column (then: (a) for group
keys, (b) for `aggregationProperty` columns — record precisely which representation serves
which compiler role). If a candidate fails criterion (iii) outright, it is out regardless
of speed.

Promotion: write the winning representation as the next-numbered migration under
`db/clickhouse/migrations/` (`0009_typed_properties.sql`), apply it with `just
ch-migrate`, verify the ledger row exists and that a freshly ingested event materializes
the column(s). If the decision is (b), also add the generator (a small executable or
script, `db/clickhouse/gen-property-columns.hs` or similar, reading `defaultRegistry`) and
commit its output as the migration — the generator is a convenience, the checked-in
migration file is the artifact. Discard: `DROP TABLE analytics.prop_bench_raw`.

Then update the parent MasterPlan: edit
`docs/masterplans/3-kansoku-analytics-extensions-queryable-properties-multi-signal-identity-and-experiment-analytics.md`,
Integration Points, "Properties storage representation" — replace the "decision … must be
recorded here when made" sentence with the actual decision, one line of evidence, and a
pointer to this plan's Decision Log. This is part of Milestone 1's acceptance, not an
afterthought.

Acceptance: benchmark numbers recorded; decision + exact SQL expressions in the Decision
Log; MasterPlan 3 updated; `just ch-migrate` applied the new migration exactly once (second
run skips it); `SELECT toString(<chosen group expr for 'plan'>) FROM analytics.events_raw
LIMIT 1` works against a freshly ingested fixture event; bench table gone.

### Milestone 2 — query compiler: property grouping, filters, aggregationProperty, featureAdoption fix

Scope: make the (post-EP-13) query compiler able to group by, filter on, and aggregate over
declared properties, using only the Milestone 1 representation. At the end, `cabal test`
proves the new SQL shapes via golden tests, and every property that reaches SQL has passed
registry validation.

Definition plumbing (`kansoku-core/src/Kansoku/Metrics/Definition.hs`): add
`aggregationProperty :: !(Maybe Text)` to `MetricDefinition` (strict field, additive;
update the `metric` helper in `Kansoku.Metrics.Registry` and every call site — keep the
helper's argument list explicit rather than growing a boolean-blindness tail; a record
update on the helper's result is fine). In `kansoku-core/src/Kansoku/Metrics/Registry.hs`,
`revenue` sets `aggregationProperty = Just "amount"`. Add a unit test asserting every
builtin `Simple` metric with `aggregation` `Sum` or `Average` has `Just` an
`aggregationProperty` that is declared (registry-checked) for every event in its
`eventNames` — this turns "forgot to declare the property" into a test failure, not a
runtime guess.

Registry additions (`kansoku-api/src/Kansoku/Event/Registry.hs`): extend `defaultRegistry`
with the two events the flagship metrics query:

```haskell
EventSchema
  (EventName "payment_completed")
  [ PropertySpec "amount" PTNumber True,
    PropertySpec "plan" PTString False
  ],
EventSchema
  (EventName "feature_used")
  [PropertySpec "feature" PTString True]
```

Property name validation: create `kansoku-core/src/Kansoku/Metrics/Query/Property.hs`. It owns the
boundary between "a Text that claims to be a property" and "a property the compiler may
splice into SQL". Contents (names indicative; align with post-EP-13 conventions found in
the tree):

```haskell
module Kansoku.Metrics.Query.Property
  ( PropertyName,        -- opaque; constructor not exported
    PropertyError (..),
    propertyNameText,
    resolveProperty,     -- :: EventRegistry -> [EventName] -> Text -> Either PropertyError PropertyName
    resolveNumericProperty, -- like resolveProperty but requires PTNumber (or PTAny) declared type
    propertyGroupExpr,   -- :: PropertyName -> Text   (SQL producing a String group key)
    propertyFloatExpr,   -- :: PropertyName -> Text   (SQL producing a Float64)
    propertyEqualsPredicate, -- :: PropertyName -> Aeson.Value -> Either PropertyError Text
  )
```

`resolveProperty` enforces, in order: the name matches `^[A-Za-z0-9_]{1,64}$` (note: this
deliberately admits uppercase, unlike EP-13's `SqlName` charset, because declared property
names such as `sessionId` in `defaultRegistry` are camelCase; the registry-membership check
below is the primary gate and this charset is belt-and-braces that keeps quoting trivial);
the queried event list is non-empty (a metric with `eventNames = []` scans all events, so
no registry schema can vouch for the property — reject with `PropertyErrorUnscopedMetric`);
and EVERY queried event's schema declares the property (`lookupSchema` for each
`EventName`; a missing schema or missing `PropertySpec` yields
`PropertyErrorUndeclared { property, event }`). The SQL-rendering functions
(`propertyGroupExpr` etc.) emit the Milestone 1 representation's expressions — e.g. for
candidate (a) something like `toString(properties_json.plan)` and
`CAST(properties_json.amount, 'Float64')`, for candidate (b) `prop_plan` and `prop_amount`
— using exactly the syntax the Milestone 1 prototype validated (copy it from the Decision
Log; do not improvise new expressions here). `propertyEqualsPredicate` renders `String`
values through EP-13's escaping-safe string rendering, `Number` as a numeric literal,
`Bool` as `true`/`false` (compared against the representation's typed read), and rejects
`Object`/`Array`/`Null` values with `PropertyErrorUnsupportedFilterValue`.

Group-by parsing (`kansoku-core/src/Kansoku/Metrics/Query.hs`, adapting to its post-EP-13 shape):
introduce a closed dimension type and parse the request's `groupBy` into it before any SQL
is built:

```haskell
data GroupDimension
  = GroupByEventName
  | GroupBySource
  | GroupByRoute
  | GroupByProperty !PropertyName
```

`event_name`/`source`/`route` map to the three existing fixed expressions; `prop:<rest>`
maps through `resolveProperty`; anything else is an error naming the value. The effective
grouping for a metric is: the request's `groupBy` if present, else the definition's
`groupBy` list resolved as bare property names via `resolveProperty` (this is the
`featureAdoption` fix: its declared `["feature"]` finally compiles to `GROUP BY` the
`feature` property instead of being silently ignored). Only the first dimension is honored,
as today — multi-dimension grouping stays out of scope; reject a request list with more
than one entry with a clear 400 rather than silently taking the head (today's silent-head
behavior is exactly the class of quiet lie this MasterPlan exists to remove; note the
behavior change in the OpenAPI description). The compiled group expression feeds both the
`SELECT … AS group_key` position and `GROUP BY`; the group label returned in
`MetricPoint.group` keys on the property name (so a `prop:plan` grouping yields points
like `{"group": {"plan": "pro"}}` — same shape the `route` grouping uses today).

Filters: in the simple-metric SQL builders, for every `(name, value)` in `def ^. #filters`,
resolve `name` via `resolveProperty` (against the metric's `eventNames`) and append `AND
<propertyEqualsPredicate>` to the WHERE clause. Builtin metrics all have empty `filters`
today, so behavior is unchanged for them; add a golden test with a synthetic
`MetricDefinition` carrying `filters = Map.fromList [("plan", Aeson.String "pro")]` to pin
the emitted SQL. A filter naming an undeclared property fails compilation with
`PropertyErrorUndeclared` — surfaced, like all these errors, as HTTP 400.

Aggregation: the Sum/Average builder takes the metric's `aggregationProperty`, resolves it
with `resolveNumericProperty`, and emits `sum(<propertyFloatExpr>)` /
`avg(<propertyFloatExpr>)`. `aggregationProperty = Nothing` on a Sum/Average metric is a
compilation error (`PropertyErrorMissingAggregationProperty`, surfaced as 400 with the
metric name — unreachable for builtins thanks to the registry unit test, reachable for
future user-defined metrics). Delete the hardcoded `'amount'` expression.

Compilation becomes fallible. Whatever the post-EP-13 builder signatures are, the property
paths introduce `Either`: the end-state shape is

```haskell
compileMetricSQL :: EventRegistry -> BuiltinMetric -> QueryRequest -> Either QueryCompileError Text
```

(or the equivalent adjustment to the existing names — reconcile with the tree and record
the actual signatures in Interfaces and Dependencies when known). The handler layer
(`kansoku-core/src/Kansoku/Metrics/Handler.hs` or its post-plan-9 successor) passes
`defaultRegistry` and maps `Left` to the EP-13-style HTTP 400 JSON error naming the
offending property/value. Un-stub the `feature-adoption` endpoint: replace its
`notImplemented` wiring with the standard metric handler for `feature_adoption` (MasterPlan
3 explicitly allows implementing a stub when a plan needs it; this plan needs a working
grouped example).

Account scoping: every SQL shape touched or added must retain EP-15's account predicate. Do
not write any builder that assembles WHERE clauses without threading it.

Tests (`kansoku-core/test/Kansoku/QuerySpec.hs`, extending the existing golden style):
revenue grouped by `prop:plan` (full golden SQL — bucket expr, group expr from the chosen
representation, `sum(<float expr>)`, account predicate, event-name predicate);
feature_adoption with no request groupBy compiles its definition's `feature` grouping;
synthetic filters metric emits the equality predicate; `prop:nope` on revenue yields
`Left (PropertyErrorUndeclared "nope" …)`; `prop:plan` on a metric whose `eventNames` don't
all declare `plan` fails; Sum metric without `aggregationProperty` fails; hostile names
(`prop:pl'an`, `prop:a b`, 65+ chars) fail the charset. Plus the builtin-registry
Sum/Average declaration test described above.

Acceptance: `cabal test` green with the new specs; `git grep "JSONExtractFloat(properties"
kansoku-core/src` returns nothing (the hardcoding is gone); compiling revenue with
`groupBy=["prop:plan"]` produces SQL containing the Milestone 1 group expression and no
`JSONExtract` over the raw column.

### Milestone 3 — wire contract, client, OpenAPI, and end-to-end proof

Scope: document property grouping in the served contract, regenerate the published
artifacts in the same commits, and prove the whole path with live transcripts. At the end,
a novice can reproduce the Purpose section's story with curl.

Contract: in `kansoku-api/src/Kansoku/Metrics/Api.hs` (the post-plan-9 `MetricsRoutes`
record), extend the `groupBy` query parameter's servant `Description` on the shared
`MetricQuery` alias to state the full grammar: built-in dimensions `event_name`, `source`,
`route`; declared-property grouping as `prop:<name>` where `<name>` must be declared in the
event registry for every event the metric queries; exactly one dimension; unknown or
undeclared values return 400 naming the value. If the `feature-adoption` route (or the
metrics family) carries a 501-related response description from earlier plans, update it —
the endpoint now serves real data. These are documentation and behavior changes to an
existing optional parameter, additive for existing callers (all previously valid requests
behave identically).

Same-commit discipline (established by plan 9 / MP-2 EP-14): in the SAME commit as any
`kansoku-api` change, run `cabal run kansoku-openapi` and commit the regenerated
`docs/api/openapi.json`, and ensure `kansoku-client` compiles (it derives from the same
types; `cabal build kansoku-client`). The CI regeneration check will enforce the OpenAPI
half; do not rely on it — run it locally.

Fixtures and transcripts: with services up (`process-compose up`) and migrations applied
(`just ch-migrate`), ingest fixture events via curl (using whatever ingest path and
authentication MP-2 landed — post-plan-9 the single-event route is `POST /v1/events`;
post-EP-15 attach the required key header; post-EP-14 note the batch-ack shape): three
`payment_completed` events (two `{"amount": 49.0, "plan": "pro"}` from different users, one
`{"amount": 9.0, "plan": "free"}`), and three `feature_used` events (two users on
`{"feature": "search"}`, one on `{"feature": "export"}`), all with `occurred_at` inside a
known day and the same test account. Wait for a writer flush (or use the flush interval),
then capture the three transcripts shown in Validation and Acceptance: revenue grouped by
plan, feature adoption grouped by feature, and the 400 for an undeclared property. Paste
the actual transcripts into this plan (replacing the expected ones if they differ, with a
Surprises entry explaining any delta). Consider committing the fixture INSERT/curl script
under `db/clickhouse/fixtures/` next to the EP-5/EP-6 fixtures (e.g. `ep17_fixtures.sql`
or a `just`-recipe-driven curl script) so the transcript is reproducible.

Acceptance: the three transcripts below reproduce on a fresh environment; `cabal run
kansoku-openapi && git diff --exit-code docs/api/openapi.json` passes after the commit;
`cabal build all && cabal test` green; MasterPlan 3's Progress checkboxes for EP-17 ticked.


## Concrete Steps

All commands run from the repository root
(`/Users/shinzui/Keikaku/bokuno/kansoku-project/kansoku`) inside `nix develop`, with
services started by `process-compose up` in another terminal. `clickhouse-client` below
means `clickhouse-client --port $CLICKHOUSE_TCP_PORT`.

Milestone 0 — reconcile. Read the post-MP-2 versions of
`kansoku-core/src/Kansoku/Metrics/Query.hs` and
`kansoku-core/src/Kansoku/Metrics/Query/Validate.hs`,
`kansoku-core/src/Kansoku/Metrics/Handler.hs`, `kansoku-api/src/Kansoku/Metrics/Api.hs`, `db/clickhouse/
migrations/`, and `db/clickhouse/migrate.sh`. Confirm each contract bullet in Context and
Orientation; record deltas in the Decision Log. Run `just build && just test` to confirm a
green baseline.

Milestone 1 — bench table and fixtures:

```sql
CREATE TABLE analytics.prop_bench_raw
(
    account_id  String,
    event_name  LowCardinality(String),
    occurred_at DateTime64(3, 'UTC'),
    event_id    String,
    properties  String
)
ENGINE = MergeTree
ORDER BY (account_id, event_name, occurred_at, event_id);

INSERT INTO analytics.prop_bench_raw
SELECT
    concat('acct-', toString(number % 20)),
    'payment_completed',
    now64(3) - toIntervalSecond(number % 2592000),
    toString(number),
    concat(
        '{"amount":', toString((number % 500) + 0.99),
        ',"plan":"', ['free', 'pro', 'team', 'enterprise'][(number % 4) + 1], '"}')
FROM numbers(10000000);
```

Add the candidates (run each `ALTER`, then `MATERIALIZE COLUMN`, then wait until
`SELECT count() FROM system.mutations WHERE table = 'prop_bench_raw' AND NOT is_done`
returns 0):

```sql
ALTER TABLE analytics.prop_bench_raw
    ADD COLUMN properties_json JSON MATERIALIZED CAST(properties, 'JSON');
ALTER TABLE analytics.prop_bench_raw MATERIALIZE COLUMN properties_json;

ALTER TABLE analytics.prop_bench_raw
    ADD COLUMN prop_plan LowCardinality(String) MATERIALIZED JSONExtractString(properties, 'plan'),
    ADD COLUMN prop_amount Float64 MATERIALIZED JSONExtractFloat(properties, 'amount');
ALTER TABLE analytics.prop_bench_raw MATERIALIZE COLUMN prop_plan;
ALTER TABLE analytics.prop_bench_raw MATERIALIZE COLUMN prop_amount;

ALTER TABLE analytics.prop_bench_raw
    ADD COLUMN props_map Map(String, String)
        MATERIALIZED CAST(JSONExtractKeysAndValues(properties, 'String'), 'Map(String, String)');
ALTER TABLE analytics.prop_bench_raw MATERIALIZE COLUMN props_map;
```

Pin the exact read syntax for candidate (a) first — this is the prototype's most valuable
output, because Milestone 2's `propertyGroupExpr`/`propertyFloatExpr` emit it verbatim. On
26.5 a `JSON` subcolumn is `Dynamic`; try, in order, and record what works:

```sql
SELECT toString(properties_json.plan), CAST(properties_json.amount, 'Float64')
FROM analytics.prop_bench_raw LIMIT 3;
```

Benchmark runs (repeat each 5 times; median of the `--time` output; the baseline is the
JSONExtract shape):

```bash
clickhouse-client --port $CLICKHOUSE_TCP_PORT --time --query "
  SELECT JSONExtractString(properties, 'plan') AS plan,
         sum(JSONExtractFloat(properties, 'amount'))
  FROM analytics.prop_bench_raw GROUP BY plan FORMAT Null"

clickhouse-client --port $CLICKHOUSE_TCP_PORT --time --query "
  SELECT toString(properties_json.plan) AS plan,
         sum(CAST(properties_json.amount, 'Float64'))
  FROM analytics.prop_bench_raw GROUP BY plan FORMAT Null"

clickhouse-client --port $CLICKHOUSE_TCP_PORT --time --query "
  SELECT prop_plan AS plan, sum(prop_amount)
  FROM analytics.prop_bench_raw GROUP BY plan FORMAT Null"

clickhouse-client --port $CLICKHOUSE_TCP_PORT --time --query "
  SELECT props_map['plan'] AS plan, sum(toFloat64OrZero(props_map['amount']))
  FROM analytics.prop_bench_raw GROUP BY plan FORMAT Null"
```

Repeat the same four-way comparison for the filtered-count shape (`count() … WHERE <plan
expr> = 'pro'`) and the group-only shape (`GROUP BY <plan expr>`, `count()`). Then collect
evidence:

```sql
SELECT query_duration_ms, read_rows, formatReadableSize(read_bytes) AS read, query
FROM system.query_log
WHERE type = 'QueryFinish' AND query LIKE '%prop_bench_raw%'
ORDER BY event_time DESC LIMIT 20;

SELECT name, formatReadableSize(data_compressed_bytes) AS compressed
FROM system.columns
WHERE database = 'analytics' AND table = 'prop_bench_raw';
```

Expected shape of the evidence (illustrative numbers — replace with real ones):

```text
baseline JSONExtract  : ~2.1 s   read ~1.1 GiB
(a) properties_json   : ~0.35 s  read ~90 MiB    +col ~180 MiB vs properties ~450 MiB
(b) prop_plan/amount  : ~0.12 s  read ~45 MiB    +cols ~60 MiB
(c) props_map         : ~0.9 s   read ~600 MiB   +col ~350 MiB
```

Apply the acceptance criteria from Plan of Work, write the Decision Log entry, update
MasterPlan 3's Integration Points, then drop the scratch table and write the real
migration (adjust to the winning candidate; shown here for (a)):

```bash
clickhouse-client --port $CLICKHOUSE_TCP_PORT --query "DROP TABLE analytics.prop_bench_raw"
ls db/clickhouse/migrations/   # take the next unused number, expected 0009
```

```sql
-- db/clickhouse/migrations/0009_typed_properties.sql
-- EP-17 Milestone 1 decision: <candidate> (see docs/plans/17-…md Decision Log).
-- properties is always valid JSON (written by Kansoku.ClickHouse.EventRow.objectBytes
-- from a parsed aeson Object), so the CAST cannot fail on ingested rows.
ALTER TABLE analytics.events_raw
    ADD COLUMN IF NOT EXISTS properties_json JSON MATERIALIZED CAST(properties, 'JSON');
ALTER TABLE analytics.events_raw MATERIALIZE COLUMN properties_json;
```

```bash
just ch-migrate     # applies 0009, records it in analytics.schema_migrations
just ch-migrate     # second run must print it as already applied / skip it
```

Commit (conventional commits; every commit in this plan carries both trailers):

```text
feat(storage): add typed properties storage chosen by EP-17 benchmark

MasterPlan: docs/masterplans/3-kansoku-analytics-extensions-queryable-properties-multi-signal-identity-and-experiment-analytics.md
ExecPlan: docs/plans/17-queryable-event-properties-typed-storage-and-property-based-grouping.md
```

(plus a `docs(plans):` commit for the Decision Log / MasterPlan updates, or fold them into
the same commit — keep plan updates and the code they describe together.)

Milestone 2 — in order: registry additions (`kansoku-api/src/Kansoku/Event/Registry.hs`);
`aggregationProperty` field + `revenue` declaration + registry unit test
(`kansoku-core/src/Kansoku/Metrics/Definition.hs`, `Registry.hs`, new spec); new module
`kansoku-core/src/Kansoku/Metrics/Query/Property.hs` (add to `kansoku-core.cabal`
exposed-modules and the test stanza's build path); compiler changes in
`kansoku-core/src/Kansoku/Metrics/Query.hs`
(GroupDimension parsing, filters, Sum/Average, Either plumbing); handler 400 mapping and
feature-adoption un-stub; golden tests in `kansoku-core/test/Kansoku/QuerySpec.hs`. After
each coherent step: `just build && just test`. Suggested commits:

```text
feat(registry): declare payment_completed and feature_used schemas
feat(metrics): aggregationProperty on MetricDefinition; revenue declares amount
feat(query): registry-validated property grouping, filtering, and aggregation
fix(metrics): honor feature_adoption declared groupBy; un-stub feature-adoption route
```

Milestone 3 — contract + proof: edit the `groupBy` `Description` in
`kansoku-api/src/Kansoku/Metrics/Api.hs`; `cabal run kansoku-openapi`; `cabal build
kansoku-client`; commit together:

```text
feat(api): document prop:<name> grouping in metrics contract; regenerate OpenAPI
```

Then fixtures + transcripts (see Validation and Acceptance), a fixtures commit
(`test(fixtures): EP-17 property-grouping fixtures and transcript script`), and the final
plan-update commit ticking MasterPlan 3's EP-17 Progress entries.


## Validation and Acceptance

Unit level: `just test` (from the repo root, inside `nix develop`). The new `QuerySpec`
cases must fail before the Milestone 2 compiler changes and pass after; the
builtin-registry test must fail if anyone adds a Sum/Average builtin without
`aggregationProperty`. Expected tail of a green run:

```text
Kansoku.Metrics.Query
  compileMetricSQL
    groups revenue by the plan property using the typed representation
    honors feature_adoption's declared feature grouping when the request has none
    compiles filters into equality predicates over declared properties
    rejects undeclared properties naming the property and event
    rejects Sum metrics without an aggregation property
...
N examples, 0 failures
```

End to end (services via `process-compose up`, migrations via `just ch-migrate`,
authentication per EP-15 — shown as `-H "Authorization: Bearer $KANSOKU_KEY"`; adjust to
the landed header/scheme). Ingest fixtures (repeat with varied `event_id`/`user_id`; two
pro payments, one free; then the three `feature_used` events):

```bash
curl -s -X POST http://localhost:8080/v1/events \
  -H 'content-type: application/json' \
  -H "Authorization: Bearer $KANSOKU_KEY" \
  -d '{
    "eventId": "ep17-pay-1", "eventName": "payment_completed", "source": "service",
    "occurredAt": "2026-07-10T12:00:00Z", "receivedAt": "2026-07-10T12:00:01Z",
    "userId": "u1", "accountId": "acct-test",
    "properties": {"amount": 49.0, "plan": "pro"}, "context": {}
  }'
```

After the writer flush, the three acceptance transcripts:

```bash
curl -s -H "Authorization: Bearer $KANSOKU_KEY" \
  'http://localhost:8080/metrics/revenue?from=2026-07-10&to=2026-07-11&groupBy=prop:plan'
```

```json
{ "metric": "revenue",
  "points": [
    { "bucket": "2026-07-10", "group": { "plan": "free" }, "value": 9.0 },
    { "bucket": "2026-07-10", "group": { "plan": "pro" }, "value": 98.0 } ] }
```

```bash
curl -s -H "Authorization: Bearer $KANSOKU_KEY" \
  'http://localhost:8080/metrics/feature-adoption?from=2026-07-10&to=2026-07-11&groupBy=prop:feature'
```

```json
{ "metric": "feature_adoption",
  "points": [
    { "bucket": "2026-07-10", "group": { "feature": "export" }, "value": 1.0 },
    { "bucket": "2026-07-10", "group": { "feature": "search" }, "value": 2.0 } ] }
```

(Values are distinct users; exact numbers depend on the fixture users — assert the shape
and the per-group arithmetic against what was ingested. Note `feature_adoption` counts via
`canonical_user` over the identity-resolved view, so fixture users must be resolvable;
if the fixtures bypass identity resolution, ingest `identify`-linked users or assert
against `events_raw`-based counts as the landed EP-13 builders dictate — record which in
the transcript.)

```bash
curl -s -i -H "Authorization: Bearer $KANSOKU_KEY" \
  'http://localhost:8080/metrics/revenue?from=2026-07-10&to=2026-07-11&groupBy=prop:nope'
```

```text
HTTP/1.1 400 Bad Request
content-type: application/json

{"error":"unknown property","details":{"property":"nope","event":"payment_completed"}}
```

Storage-level spot check (proves the query really used the typed representation): run the
revenue query, then inspect `system.query_log` for it — `read_bytes` must be a small
fraction of the raw `properties` column size, and the logged SQL must contain the Milestone
1 expression and no `JSONExtract` over `properties`.

Acceptance is all of: the three transcripts reproduce; `just test` green; the OpenAPI
regeneration check passes; `git grep "JSONExtractFloat(properties"` in `kansoku-core/src`
is empty; MasterPlan 3's Integration Points name the chosen representation.


## Idempotence and Recovery

The benchmark is entirely scratch: `analytics.prop_bench_raw` can be dropped and rebuilt at
any point (`DROP TABLE IF EXISTS` + re-run the CREATE/INSERT); `MATERIALIZE COLUMN`
re-runs are safe (they re-enqueue a mutation over the same deterministic expression). The
bench never touches `analytics.events_raw`.

The real migration goes through EP-12's ledger, so `just ch-migrate` is idempotent by
construction — a second run skips the recorded file. The migration itself uses `ADD COLUMN
IF NOT EXISTS`, so a half-applied run (column added, backfill mutation interrupted) is
recovered by re-running the two statements manually with `clickhouse-client --multiquery`
and letting the mutation finish (`system.mutations` where `NOT is_done` drains to zero);
then, if the ledger row is missing, re-run `just ch-migrate`. Never edit an applied
migration file — remediation DDL is a new numbered file. Rollback, if the representation
must be abandoned: a new migration `ALTER TABLE analytics.events_raw DROP COLUMN …` —
materialized columns are additive and dropping one cannot lose ingested data (the raw
`properties` string remains the source of truth throughout).

All Haskell changes are additive (new field with `Maybe`, new module, new registry entries)
and land behind `just build && just test`; any step can be redone from a clean checkout of
the previous commit. The fixture curl script can be re-run freely: `event_id` is the
ReplacingMergeTree dedup identity, so re-ingesting the same fixture ids does not double
counts (revenue sums use `sum` over rows, so verify fixtures were not double-flushed
pre-merge — if numbers look doubled, `OPTIMIZE TABLE analytics.events_raw FINAL` on the
dev instance or re-check with fresh event ids).


## Interfaces and Dependencies

Services: ClickHouse (pinned 26.5.1 in the dev shell via nixpkgs; the JSON type, `CAST(…,
'JSON')`, `MATERIALIZED` columns, and `MATERIALIZE COLUMN` are all long-stable at that
version) and Postgres/pgmq, both via `process-compose up`. No new Haskell dependencies:
`aeson`, `containers`, `text`, and ClickHaskell (pinned checkout at
`/Users/shinzui/Keikaku/hub/haskell/clickhaskell-project/`) already cover everything.
Hard constraint restated: ClickHaskell speaks no `JSON`/`Map` column types, so those types
must exist only server-side (MATERIALIZED), and every value crossing the client wire in
query results must be a String/Float64 produced by `toString`/`CAST` in the SQL itself.

Module contracts at the end of the plan (signatures indicative; reconcile names with the
post-EP-11/EP-13 tree and record the final forms here):

```haskell
module Kansoku.Metrics.Query.Property
  ( PropertyName,               -- opaque validated property; constructor not exported
    PropertyError (..),         -- Undeclared {property, event} | BadCharset | UnscopedMetric
                                -- | NotNumeric | UnsupportedFilterValue | MissingAggregationProperty
    propertyNameText,           -- :: PropertyName -> Text
    resolveProperty,            -- :: EventRegistry -> [EventName] -> Text -> Either PropertyError PropertyName
    resolveNumericProperty,     -- :: EventRegistry -> [EventName] -> Text -> Either PropertyError PropertyName
    propertyGroupExpr,          -- :: PropertyName -> Text   (String-typed SQL, M1 representation)
    propertyFloatExpr,          -- :: PropertyName -> Text   (Float64-typed SQL, M1 representation)
    propertyEqualsPredicate,    -- :: PropertyName -> Aeson.Value -> Either PropertyError Text
  )

module Kansoku.Metrics.Definition
  -- MetricDefinition gains: aggregationProperty :: !(Maybe Text)
  -- filters :: Map Text Value is now consumed by the compiler (no longer dead)

module Kansoku.Metrics.Query
  ( QueryRequest (..),          -- post-EP-13/EP-15 shape, unchanged by this plan except use
    GroupDimension (..),        -- GroupByEventName | GroupBySource | GroupByRoute | GroupByProperty PropertyName
    QueryCompileError (..),     -- wraps PropertyError and any EP-13 validation errors
    compileMetricSQL,           -- :: EventRegistry -> BuiltinMetric -> QueryRequest -> Either QueryCompileError Text
    -- run/runSessions/runRetention/runFunnel keep their post-MP-2 signatures; the metric
    -- run path threads the Either through to the handler's 400 mapping
  )
```

Wire contract at end of plan: the `groupBy` query parameter on the metrics routes
(`kansoku-api/src/Kansoku/Metrics/Api.hs`, `MetricsRoutes` record / `MetricQuery` alias)
accepts exactly one of `event_name`, `source`, `route`, or `prop:<declared property>`;
its servant `Description` states this grammar; errors are the EP-13 JSON 400 shape naming
the offending value. `MetricPoint`/`MetricResult` DTOs are unchanged — property groupings
reuse `MetricPoint.group :: Map Text Text` keyed by the property name. The
`feature-adoption` route serves real data (no longer 501). `docs/api/openapi.json` and
`kansoku-client` move in the same commits as any of these changes.

Downstream consumers of this plan's outputs: EP-19
(`docs/plans/19-experiment-analytics-assignment-events-variant-rollups-and-per-variant-metrics.md`)
consumes the storage representation (its rollup MVs must use the Milestone 1 expressions,
never raw `JSONExtract*`) and the `prop:` grouping (per-variant metrics are `prop:variant`);
EP-20 will externalize the registry that gates property declarations — if the Milestone 1
decision is candidate (b), EP-20's declaration format also feeds the column generator, and
that coupling must be recorded in MasterPlan 3's Integration Points when the decision is
made.
