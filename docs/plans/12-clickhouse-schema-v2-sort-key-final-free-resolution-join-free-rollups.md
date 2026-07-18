---
id: 12
slug: clickhouse-schema-v2-sort-key-final-free-resolution-join-free-rollups
title: "ClickHouse schema v2: sort key, FINAL-free resolution, join-free rollups"
kind: exec-plan
created_at: 2026-07-15T21:30:34Z
intention: intention_01kxr5jt2heyvt0n768ym9dwqd
master_plan: "docs/masterplans/2-kansoku-production-hardening-review-fixes-and-portfolio-service-readiness.md"
---

# ClickHouse schema v2: sort key, FINAL-free resolution, join-free rollups

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This is child plan EP-12 of the MasterPlan at
`docs/masterplans/2-kansoku-production-hardening-review-fixes-and-portfolio-service-readiness.md`.
It has one hard dependency: EP-10
(`docs/plans/10-restore-the-build-and-supervise-the-writer.md`), which is complete. EP-10
restored the build after the Shibuya handler-facing message type changed and established the
green baseline required to validate this plan. Every milestone here must keep `cabal build all`
and `cabal test all` green.


## Purpose / Big Picture

Kansoku stores every analytics event in ClickHouse, and ClickHouse is the system of record.
A 2026-07-15 architecture and performance review found that the current ClickHouse layer has
five defects that are cheap to fix now and expensive to fix later: there is no record of
which schema migrations have been applied (and the table DDL is duplicated in Haskell code),
the raw-event sort key does not serve any query the service runs, a dozen columns pay the
storage and CPU tax of `Nullable` for no benefit, the identity-resolution view forces
read-time merges with `FINAL`, and the "rollup" tables are as large as the raw data they
summarize because they store exact-distinct states, with two of their materialized views
performing an insert-time join whose cost grows forever.

After this plan, a developer can run `just ch-migrate` and see only *unapplied* migration
files run, each recorded in a ledger table; the raw events table has a sort key that matches
the account-scoped, event-name-and-time queries the service runs (and will run after EP-15
adds account scoping); inserts and queries no longer pay for null masks on columns where the
codebase already treats the empty string as "absent"; identity resolution reads without
`FINAL`; DAU/WAU materialized views aggregate without joining the identity map on every
inserted block; and the rollup tables are demonstrably orders of magnitude smaller than the
raw table under load, verified with a `system.parts` storage comparison and fixture-based
metric equivalence checks.

The single most important framing: kansoku is pre-production and experimental, so the raw
events table is small (thousands of rows in dev, zero in any deployed environment). A
rewrite migration — copy the table, swap names, drop the old one — costs seconds today and
would cost hours of careful orchestration once real traffic accumulates. That is exactly why
this plan sits in Phase 2 of the MasterPlan and should land as early as possible: every week
of delay makes the same change strictly more expensive.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-07-18 14:24Z) M1: `db/clickhouse/migrate.sh` written (ledger bootstrap + apply-unapplied-in-order)
- [x] (2026-07-18 14:24Z) M1: justfile `ch-migrate` recipe delegates to the script; `ch-reset` recipe added
- [x] (2026-07-18 14:24Z) M1: `ensureSchema`, `createEventsRawTable`, `openBootstrapConnection` deleted from
      `kansoku-core/src/Kansoku/ClickHouse.hs` (exports and unused imports cleaned)
- [x] (2026-07-18 14:24Z) M1: `kansoku-core/test/Kansoku/ClickHouseSpec.hs` and
      `kansoku-core/test/Kansoku/Writer/BatchSpec.hs` bootstrap via migrations, pending with
      a "run just ch-migrate" hint when the schema is absent
- [x] (2026-07-18 14:24Z) M1: migration-immutability rule documented in `db/clickhouse/migrations/` (header
      comment in the runner script) and verified: `just ch-migrate` twice shows skips
- [x] (2026-07-18 14:31Z) M2: `db/clickhouse/migrations/0004_events_raw_v2.sql` written (v2 table, copy,
      exchange, dependent objects recreated with v1 semantics)
- [x] (2026-07-18 14:31Z) M2: row-count verification run on the dev database; old table retained
- [x] (2026-07-18 14:31Z) M2: `kansoku-core/src/Kansoku/ClickHouse/EventRow.hs` updated (`Maybe ChString` →
      `ChString` for the cleaned columns; `source_global_position` stays `Maybe`)
- [x] (2026-07-18 14:31Z) M2: `Kansoku.Query.buildSessionsSQL` predicate reduced to `session_id != ''`
- [x] (2026-07-18 14:31Z) M2: `cabal build all` and `cabal test all` green against the v2 table
- [x] (2026-07-18 14:34Z) M3: `db/clickhouse/migrations/0005_final_free_resolution.sql` written (events_resolved
      without FINAL; mv_dau/mv_wau join-free; dau/wau truncated and backfilled)
- [x] (2026-07-18 14:34Z) M3: fixture check — stitched vs raw-identity active-user numbers both observable
- [x] (2026-07-18 14:45Z) M4: `db/clickhouse/migrations/0006_rollups_v2.sql` written (count states, uniqCombined
      states, tables rebuilt, MVs recreated, backfilled)
- [x] (2026-07-18 14:45Z) M4: `db/clickhouse/migrations/0007_drop_events_raw_v1.sql` written (final DROP of the
      retained old table, after verification)
- [x] (2026-07-18 14:45Z) M4: `Kansoku.Query` merge functions updated (`countMerge`, `uniqCombinedMerge`)
- [x] (2026-07-18 14:45Z) M4: `db/clickhouse/fixtures/ep5_fixtures.sql` and `ep6_fixtures.sql` comments and
      expectations updated for v2 semantics
- [x] (2026-07-18 14:45Z) M4: fresh `just ch-reset` + fixture load + metric equivalence transcript captured
- [x] (2026-07-18 14:45Z) M4: synthetic 100k-event load + `system.parts` storage comparison transcript captured
- [ ] MasterPlan registry row for EP-12 updated to Complete; Outcomes written


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-07-18: The predicted EP-6 drift is observed: the replay-proof raw query returns 3
  distinct page-view event IDs on 2026-06-01, while the count-state rollup returns 4 rows.
  This is the accepted count-vs-distinct tradeoff, made visible by the fixture rather than a
  regression.

- 2026-07-18: Current Cabal rejects bare `cabal test` with `Cabal-7134` because no target is
  selected. `cabal test all` is the explicit project-wide equivalent and passed both suites
  (35 core examples, 7 client examples with the live-server case intentionally pending).
  The `just test` recipe and this plan's validation commands now use `cabal test all`.

- 2026-07-18: The pre-0006 storage baseline confirms the review finding more strongly than
  expected. After a 100,000-page-view load, `events_raw` occupied 731,952 bytes while each
  exact-distinct event rollup occupied about 1.61 MB (`daily_event_counts` 1,607,416 bytes;
  `page_views_by_route` 1,607,423 bytes). The v1 “rollups” were each over twice the size of
  the raw table; M4's bounded states must reverse this relationship.

- 2026-07-18: ClickHouse 26.5 does not resolve the first arm's `src` alias in a trailing
  `ORDER BY` attached directly to the second arm of the fixture UNION. Wrapping both arms in
  `SELECT * FROM (...) ORDER BY event_name, src` works and is now the documented command.

- 2026-07-18: The plan's highly regular 100,000-row load compressed raw data to 731,952
  bytes; the four v2 rollups totaled 10,898 bytes (67x smaller), while each event-id rollup
  individually shrank from about 1.61 MB to under 1 KB (over 1,700x). Adding deterministic
  per-event JSON entropy made the raw fixture representative of real payloads: 8,034,824
  bytes raw versus the same 10,898 rollup bytes, or 0.136% / about 737x smaller. A nested
  subquery used to calculate that ratio triggered `std::bad_alloc`; one `system.parts` scan
  with `sumIf` returned the ratio reliably.

- 2026-07-18: HTTP validation exposed three local workflow facts unrelated to the rollup
  implementation. The persistent Postgres database has pre-pg-migrate PGMQ objects without
  matching ledger history, so `just run` fails its migration prerequisite with
  `message_record already exists`; port 8080 is also occupied by another process-compose
  project; and bare `cabal run kansoku-server` is ambiguous now that the package has two
  executables. Direct startup on port 18080 with the fully qualified executable proved the
  metric endpoints, and `just run` now uses that explicit target.


## Decision Log

Record every decision made while working on the plan.

- Decision: `account_id` stays as the leading sort-key column in schema v2 even though no
  current query filters on it.
  Rationale: The MasterPlan's Decision Log and Integration Points record that EP-15
  (`docs/plans/15-api-keys-service-auth-and-account-scoped-queries.md`) makes every metric
  query account-scoped; the leading column becomes the primary pruning key then. Changing
  the sort key twice would mean two full-table rewrites. Today `account_id` is `''` for
  nearly every dev row, so the leading column is a constant prefix and costs nothing.
  Date: 2026-07-15

- Decision: Drop `user_id` from the sort key; v2 is
  `ORDER BY (account_id, event_name, occurred_at, event_id)`.
  Rationale: No query filters on `user_id`; identity-based queries resolve through the
  identity map, not through raw `user_id` equality. Placing `user_id` second fragments the
  physical locality of the `(event_name, occurred_at)` ranges every metric scans, so the
  primary index prunes almost nothing. `event_id` must stay in the key (and stays last)
  because the ORDER BY tuple is the ReplacingMergeTree dedup identity — see Context.
  Date: 2026-07-15

- Decision: Migrate all `Nullable(String)` columns — including `anonymous_id` and
  `organization_id`, which the review's enumeration did not explicitly list — to
  `String DEFAULT ''`, keeping only `source_global_position` as `Nullable(UInt64)`.
  Rationale: The codebase already treats `''` as absent for `user_id`/`account_id`, and
  0002's `mv_identity_map` already filters `anonymous_id != ''`; migrating every string
  column keeps one convention instead of two. A numeric column cannot join the convention —
  a `0` sentinel for `source_global_position` would be a lie (0 is a valid position), so it
  stays `Nullable`. `organization_id` is included for consistency; it is a plain identifier
  with the same absence semantics as the others.
  Date: 2026-07-15

- Decision: Wrap `utm_source`, `utm_medium`, `utm_campaign` in `LowCardinality(String)`;
  do not wrap `url`, `referrer`, `utm_content`, `utm_term`, or any id column.
  Rationale: The three wrapped columns are low-cardinality by nature (a handful of channels
  and campaign names). `LowCardinality` dictionary-encodes values, which backfires on
  unbounded domains: URLs, referrers, free-text utm content/term, and ids are effectively
  unique per row, so a dictionary would grow as large as the data plus overhead.
  Date: 2026-07-15

- Decision: Use a rewrite-and-exchange migration (create `events_raw_v2`, `INSERT … SELECT`,
  `EXCHANGE TABLES`, verify, drop later) instead of any in-place ALTER.
  Rationale: ClickHouse cannot ALTER a table's ORDER BY to remove a column, and converting
  `Nullable(String)` to `String` across the board is cleanest as a rewrite. The table is
  tiny now (pre-production), so the rewrite costs seconds; this is the whole reason EP-12
  lands early. The old table survives under the `events_raw_v2` name until a final DROP in
  a later migration, giving a rollback window.
  Date: 2026-07-15

- Decision: Migration files are immutable once applied; the ledger table
  `analytics.schema_migrations` (engine `MergeTree ORDER BY filename`) records what ran.
  Rationale: The old recipe re-applied every file on every run, which was only safe because
  every statement was `CREATE IF NOT EXISTS` — and that same property meant editing an
  applied file silently did nothing on an existing database. A ledger plus immutability
  makes "what is the schema?" answerable from the repo. `MergeTree` is chosen because the
  ledger is append-only and tiny; the runner checks for a filename before applying, so no
  replacing/dedup engine semantics are needed, and `ORDER BY filename` gives the natural
  key. Per the MasterPlan's Integration Points, EP-13, EP-15, and EP-16 add ClickHouse
  objects only through this mechanism.
  Date: 2026-07-15

- Decision: Delete `ensureSchema`/`createEventsRawTable` (and `openBootstrapConnection`,
  whose only purpose was serving `ensureSchema`) from
  `kansoku-core/src/Kansoku/ClickHouse.hs`; the migration files are the single owner of DDL.
  Rationale: `createEventsRawTable` duplicated migration 0001 verbatim — two sources of
  truth that would silently diverge the moment 0004 lands. Tests bootstrap via
  `just ch-migrate` instead (they already pend when ClickHouse is unreachable; they now
  also pend, with a hint, when the schema is missing).
  Date: 2026-07-15

- Decision: `daily_event_counts.events` and `page_views_by_route.views` become
  `AggregateFunction(count)` populated by `countState()`, replacing
  `AggregateFunction(uniqExact, String)` over `event_id`.
  Rationale: An exact-distinct state stores every id it has seen, so the "rollup" was as
  large as the raw `event_id` column and its merge cost scaled with event volume. A count
  state is a single integer per group. The distinct-vs-count drift this introduces is
  bounded by the duplicate rate, and duplicates in this system come only from at-least-once
  queue replays, which ReplacingMergeTree collapses in the raw table shortly after — the
  drift is rare, small, and transient. Queries needing replay-proof exactness read the raw
  table (as `countEventsSQL` already does with `count(DISTINCT event_id)`).
  Date: 2026-07-15

- Decision: `dau.users` and `wau.users` become `AggregateFunction(uniqCombined, String)`.
  Rationale: `uniqExact` states grow linearly with distinct users; `uniqCombined` is a
  bounded-size sketch (exact for small sets, switching to a HyperLogLog-style structure at
  scale with roughly 0.8% relative error). Active-user counts are trend metrics; sub-percent
  error is an acceptable price for rollups whose size no longer depends on user count.
  Date: 2026-07-15

- Decision: The new mv_dau/mv_wau count *raw identities* (`user_id` if present, else
  `anonymous_id`) with no identity-map join; the stitched number stays available at query
  time through `events_resolved`.
  Rationale: The old MVs joined the full identity map on every inserted block — insert cost
  grew with total identities forever, twice per batch — and insert-time resolution is
  *frozen*: an `identify` arriving after a user's anonymous events leaves those events
  attributed to the anonymous id in the rollup permanently, double-counting the person.
  Join-free raw-identity counting is cheap, stable, and honestly documented as
  pre-stitching. Which metric endpoint reads which source is EP-13's decision (see
  Interfaces and Dependencies for the explicit handoff).
  Date: 2026-07-15

- Decision: Milestone 2's migration (0004) recreates every dependent view and MV with
  *v1 semantics* (FINAL kept, identity joins kept), and Milestones 3 and 4 then replace
  them; the dau/wau MVs are therefore written twice across 0004/0005/0006.
  Rationale: Each milestone must leave a fully working system. Dropping the MVs around the
  table swap is required anyway (see Context on why we do not trust rename-following
  dependencies), so 0004 restores the exact prior behavior on the new table, and later
  files change one thing at a time. The duplication costs a few lines of SQL in immutable
  history and buys independent verifiability.
  Date: 2026-07-15

- Decision: This plan makes only the minimal `kansoku-core/src/Kansoku/Query.hs` edits
  needed to keep the system green (`isNotNull(session_id)` removal in M2;
  `uniqExactMerge` → `countMerge`/`uniqCombinedMerge` in M4). The wholesale SQL-builder
  rewrite is EP-13's.
  Rationale: MasterPlan boundary — EP-13 hard-depends on EP-12 precisely so its builders
  target the v2 schema once, not twice.
  Date: 2026-07-15

- Decision: Use `cabal test all` for project-wide test gates and make `just test` delegate
  to that explicit target.
  Rationale: The current Cabal executable rejects bare `cabal test` with `Cabal-7134`;
  selecting `all` preserves the intended four-package validation and is verified green.
  Date: 2026-07-18

- Decision: Update the built-in metric descriptions in M4 to match the behavior now served:
  page views are rollup event rows rather than replay-proof distinct IDs, and active users
  are approximate distinct raw identities rather than stitched identities.
  Rationale: EP-13 still owns the longer-term query-source choice, but the current public
  registry must not claim semantics the current endpoints no longer have.
  Date: 2026-07-18

- Decision: Add deterministic per-event `properties` and `context` entropy to the storage
  fixture and calculate the combined ratio with one `sumIf` scan.
  Rationale: The original all-default JSON payload compressed unlike real analytics events
  and understated raw storage by an order of magnitude. The revised 100,000-row fixture is
  deterministic, preserves the same 500-user/100,000-page-view expectations, and proves the
  intended bounded-state relationship without relying on a nested expression that crashes
  this local ClickHouse build.
  Date: 2026-07-18

- Decision: Qualify the server executable as
  `kansoku-server:exe:kansoku-server` in the `just run` recipe.
  Rationale: Current Cabal rejects the package-level target as ambiguous because the package
  exposes both `kansoku-server` and `kansoku-migrate`.
  Date: 2026-07-18


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

Milestones 1 and 2 are complete. ClickHouse now records immutable migrations and skips
applied files, Haskell no longer owns a duplicate raw-table DDL string, and tests probe the
migrated schema. Migration 0004 copied a non-empty dev table with equal v1/v2 row counts,
swapped in the account/event/time-oriented sort key, removed every `Nullable(String)`, and
retained the v1 table for rollback. Typed ClickHaskell inserts, replay deduplication, both
fixture sets, `cabal build all`, and `cabal test all` are green against the v2 table.

Milestone 3 is complete. `events_resolved` no longer forces `FINAL`, DAU/WAU inserts no
longer scan identity_map, and their tables were backfilled consistently with raw-identity
semantics. The EP-5 fixture demonstrates the intended distinction: the rollup reports 4 raw
identities while query-time stitching reports 3 users. The full test suite remains green.

Milestone 4 is complete. Event and page-view rollups now store constant-size count states;
DAU/WAU use bounded `uniqCombined` states; Haskell reads them with matching merge functions;
and the verified v1 raw-table copy is dropped. Fresh replay and repeat-skip both cover all
seven migrations. Fixture queries and live HTTP responses report active users 4, page views
4 on the duplicate day, and page views 5 on the EP-5 day. At 100,000 representative events,
raw storage is 8,034,824 bytes while all four rollups total 10,898 bytes (0.136%, roughly
737x smaller); the same metrics report 500 users and 100,000 page views. All 43 test examples
pass, with only the intentionally disabled client live-server case pending.


## Context and Orientation

Kansoku is a Haskell analytics service (GHC 9.12.4, nix flake) with four cabal packages:
`kansoku-api` (servant route types and DTOs), `kansoku-core` (domain logic, ClickHouse and
queue integration, metric SQL), `kansoku-server` (the executable), and `kansoku-client`
(SDK). Events arrive over HTTP, are queued durably in Postgres (pgmq), and a batch writer
inserts them into ClickHouse. ClickHouse is the system of record for analytics data.

Local development: `nix develop` provides the toolchain and sets environment variables
including `CLICKHOUSE_TCP_PORT`; `process-compose up` (or `just up`) starts Postgres and a
local ClickHouse server (`process-compose.yaml` at the repo root). All `just` recipes below
run from the repository root inside `nix develop`.

Terms used in this plan, in plain language:

*MergeTree* is ClickHouse's main table engine family: data is written as immutable sorted
"parts" that a background process merges. The `ORDER BY` clause of a MergeTree table is its
*sort key*: rows inside every part are physically sorted by that tuple, and a sparse primary
index over it lets queries skip data whose key range cannot match — but only for filters on
a *prefix* of the tuple.

*ReplacingMergeTree* is a MergeTree variant that, during background merges, collapses rows
whose entire ORDER BY tuple is equal, keeping the row with the greatest "version" column
(here `received_at`). This is how kansoku gets idempotency over an at-least-once queue: a
replayed event produces an identical tuple and is eventually collapsed. Two consequences
matter here. First, the ORDER BY tuple is the *dedup identity* — it must uniquely identify
an event, which is why `event_id` (globally unique per event) must appear in the tuple, and
it goes last so it does not disturb range locality for the columns queries actually filter
on. Remove `event_id` and two different events sharing account, name, and timestamp would
be silently merged into one. Second, dedup happens *eventually* (at merge time), so between
a replay and the next merge the table can briefly contain duplicate rows.

*FINAL* is a query modifier (`FROM table FINAL`) that forces ReplacingMergeTree collapsing
at read time, across all parts, on every query. It is expensive — it defeats most of the
engine's read optimizations — and it only buys deduplication of those transient duplicates.

*Materialized view (MV)* in ClickHouse is an insert trigger: `CREATE MATERIALIZED VIEW mv
TO target AS SELECT …` runs the SELECT over each *inserted block* of the source table and
inserts the result into `target`. It never sees old data (backfills are manual `INSERT …
SELECT`) and it sees blocks *as inserted*, before any merge-time dedup.

*AggregatingMergeTree* and aggregate states: a column typed `AggregateFunction(f, T)` stores
the partial state of aggregate function `f` (produced by `fState(...)`, e.g.
`uniqExactState`, `countState`, `uniqCombinedState`); reading it back requires `fMerge(...)`.
An AggregatingMergeTree table merges states for rows with equal ORDER BY keys. Critically,
the state of `uniqExact` contains *every distinct value seen* — it is not a summary — while
`count` is one integer and `uniqCombined` is a bounded-size sketch.

*LowCardinality(String)* dictionary-encodes a column: values are stored once in a dictionary
with small integer references. Excellent for columns with few distinct values, harmful for
unbounded ones. *Nullable(String)* stores a separate null-mask sidecar file per column and
disables several optimizations; a non-Nullable `String DEFAULT ''` is cheaper when the
application already treats `''` as absent.

Current state of the ClickHouse layer, file by file:

`db/clickhouse/migrations/0001_events_raw.sql` creates `analytics.events_raw`:
`ENGINE = ReplacingMergeTree(received_at) PARTITION BY toYYYYMM(occurred_at) ORDER BY
(account_id, user_id, event_name, occurred_at, event_id)`, with twelve `Nullable(String)`
columns (`source_service`, `anonymous_id`, `organization_id`, `session_id`, `url`,
`referrer`, five `utm_*` columns, `correlation_id`, `causation_id`, `source_event_id`) and
`source_global_position Nullable(UInt64)`.

`db/clickhouse/migrations/0002_identity.sql` creates `analytics.identity_map`
(ReplacingMergeTree keyed on `anonymous_id`, latest `user_id` wins by `version`), the MV
`analytics.mv_identity_map` that fills it from `identify`/`alias` events (already filtering
`anonymous_id != ''` — i.e., already treating `''` as absent), and the plain view
`analytics.events_resolved`, which reads `FROM analytics.events_raw AS e FINAL`, LEFT JOINs
a collapsed identity map, and exposes `canonical_user =
coalesce(nullIf(e.user_id,''), nullIf(m.user_id,''), nullIf(e.anonymous_id,''), '')`. (The
`nullIf(m.user_id,'')` is load-bearing: with ClickHouse's default `join_use_nulls = 0`, a
LEFT JOIN miss fills `m.user_id` with `''`, not NULL.)

`db/clickhouse/migrations/0003_rollups.sql` creates four AggregatingMergeTree rollups and
their MVs: `daily_event_counts` and `page_views_by_route` store
`AggregateFunction(uniqExact, String)` over `event_id` (an exact-distinct state that stores
every id — the rollup is as large as the raw column); `dau` and `wau` store
`AggregateFunction(uniqExact, String)` over the canonical user, and `mv_dau`/`mv_wau` each
LEFT JOIN the *entire* collapsed identity map on every inserted block.

`justfile` recipe `ch-migrate` runs every file in `db/clickhouse/migrations/*.sql` in
filename order through `clickhouse-client --port $CLICKHOUSE_TCP_PORT --multiquery`, with no
record of what was applied. Recipes `ch-fixtures-ep5`/`ch-fixtures-ep6` load
`db/clickhouse/fixtures/ep5_fixtures.sql` and `ep6_fixtures.sql`.

`kansoku-core/src/Kansoku/ClickHouse.hs` exposes `ensureSchema`, which executes
`createEventsRawTable` — a Haskell `MultilineStrings` literal duplicating migration 0001
verbatim — plus `openBootstrapConnection` (a connection to the `default` database used only
to run `ensureSchema`). `ensureSchema`'s only callers are the two integration specs,
`kansoku-core/test/Kansoku/ClickHouseSpec.hs` and
`kansoku-core/test/Kansoku/Writer/BatchSpec.hs`, in their `withClickHouse` helpers. The
server executable (`kansoku-server/app/Main.hs`) never calls it — it just opens a connection
with `openClickHouse`.

`kansoku-core/src/Kansoku/ClickHouse/EventRow.hs` defines the insert row: the type-level
`EventColumns` list uses `Maybe ChString` for every Nullable column, `EventRow` uses
`Maybe ByteString` fields, and `eventRowFromEvent` maps optional event fields with `<$>`.

`kansoku-core/src/Kansoku/Query.hs` builds metric SQL as text. Relevant to this plan:
`activeUsersDaySQL`/`activeUsersWeekSQL` read `uniqExactMerge(users)` from `analytics.dau`/
`analytics.wau`; `pageViewsDaySQL` reads `uniqExactMerge(views)` from
`analytics.page_views_by_route` (twice — grouped-by-route and ungrouped branches);
`buildSessionsSQL` filters `isNotNull(session_id) AND session_id != ''`;
`uniqueUsersSQL`, `buildRetentionSQL`, `buildFunnelSQL`, and `buildRatioSQL` all read
`analytics.events_resolved` and aggregate `canonical_user` with `uniqExact` or `min`;
`countEventsSQL` reads `events_raw` with `count(DISTINCT event_id)`.

Why the current sort key serves nothing: every metric query filters on `occurred_at` ranges
and (often) `event_name`; none filters on `account_id` (constant `''` in dev) or `user_id`.
With `user_id` in position two of the tuple, rows for a given `(event_name, occurred_at)`
range are scattered across every user's key range, so the sparse index cannot skip granules.
Moving to `(account_id, event_name, occurred_at, event_id)` puts each event name's time
range contiguous within an account; once EP-15 adds the mandatory account predicate, the
full prefix is used. Until then, with `account_id` effectively constant, the index behaves
as if it started at `event_name` — already a strict improvement.

Why FINAL buys nothing in `events_resolved`: the only thing FINAL removes is transient
duplicate rows awaiting merge. Every consumer of `events_resolved` aggregates
`canonical_user` with `uniqExact` (unique users, funnel steps, ratio metrics) or `min`
(retention's first-seen) — functions whose results are unchanged by duplicate input rows.
The one caveat: any future query that *counts rows* from `events_resolved` must protect
itself against duplicates (as `countEventsSQL` already does on the raw table with
`count(DISTINCT event_id)`). This caveat is restated where EP-13 will see it (Interfaces
and Dependencies).

Why the MVs must be dropped and recreated around the table swap: an MV is registered as a
dependency of its source table. Whether that dependency correctly follows an
`EXCHANGE TABLES` (which swaps two tables' names while each keeps its data) is a subtle,
version-dependent corner of ClickHouse. Rather than rely on it, migration 0004 explicitly
drops every object that reads `events_raw` and recreates them against the new table. This
is also semantically forced: the type changes (Nullable → plain String) alter the inferred
types of the MV SELECTs, and being explicit means every object's definition is visible in
exactly one migration file.

The write path (for confidence that nothing else touches these tables): the batch writer
(`kansoku-core/src/Kansoku/Writer/Batch.hs`) calls
`Kansoku.ClickHouse.insertEvents`, which inserts `EventRow`s into `events_raw` via the
clickhaskell library's typed `intoTable`. The column *types* in `EventColumns` must match
the table, which is why Milestone 2 pairs the migration with the `EventRow.hs` edit.


## Plan of Work

The work is four milestones. Old and new schema coexist during the rewrite, so each
milestone is independently verifiable and leaves the repository and the dev database fully
working: M1 changes only *how* migrations apply; M2 rewrites the raw table (and the Haskell
row type) while recreating all dependent objects with unchanged semantics; M3 changes the
resolution view and the DAU/WAU MVs; M4 changes the rollup state types, makes the matching
`Query.hs` merge edits, updates fixtures, and captures the verification transcripts.
Migration files added here: `0004_events_raw_v2.sql` (M2), `0005_final_free_resolution.sql`
(M3), `0006_rollups_v2.sql` and `0007_drop_events_raw_v1.sql` (M4).

One operational rule for every milestone: stop the kansoku server and writer while running
`just ch-migrate` on a database they are writing to. The migrations drop and recreate MVs,
and an insert landing in the window between a backfill and an MV recreation would be missed
by the rollups. In dev this means: do not have `just run` active while migrating.


### Milestone 1 — Versioned migration mechanism and a single DDL owner

Scope: introduce the `analytics.schema_migrations` ledger and a runner script that applies
only unapplied files in filename order, recording each; rewire the `ch-migrate` just recipe
to it and add a `ch-reset` recipe; delete the duplicated DDL from Haskell and fix the test
bootstrap. At the end, running `just ch-migrate` twice in a row shows files applied once
and skipped the second time, the ledger lists them, and `cabal test all` still passes (the
ClickHouse-touching specs pass when the schema exists, and pend with a helpful hint when it
does not). No schema *content* changes in this milestone.

Create `db/clickhouse/migrate.sh` with the following content and make it executable
(`chmod +x db/clickhouse/migrate.sh`):

```bash
#!/usr/bin/env bash
# ClickHouse migration runner.
#
# Applies db/clickhouse/migrations/*.sql in filename order, skipping files
# already recorded in analytics.schema_migrations, and recording each applied
# file. RULE: a migration file is IMMUTABLE once applied anywhere — never edit
# an applied file; add a new numbered file instead. The ledger keys on the
# filename, so an edited file would silently not re-run.
set -euo pipefail

port="${CLICKHOUSE_TCP_PORT:?CLICKHOUSE_TCP_PORT must be set (enter nix develop)}"

ch() {
  clickhouse-client --port "$port" "$@"
}

ch --query "CREATE DATABASE IF NOT EXISTS analytics"
ch --query "
  CREATE TABLE IF NOT EXISTS analytics.schema_migrations
  (
      filename   String,
      applied_at DateTime64(3, 'UTC') DEFAULT now64(3)
  )
  ENGINE = MergeTree
  ORDER BY filename"

for f in db/clickhouse/migrations/*.sql; do
  name="$(basename "$f")"
  applied="$(ch --query "SELECT count() FROM analytics.schema_migrations WHERE filename = '$name'")"
  if [ "$applied" = "0" ]; then
    echo "applying $name"
    ch --multiquery < "$f"
    ch --query "INSERT INTO analytics.schema_migrations (filename) VALUES ('$name')"
  else
    echo "skipping $name (already applied)"
  fi
done
```

Notes on the design, so a future reader does not "fix" it: the ledger table lives inside
the `analytics` database on purpose — `just ch-reset` (below) drops the whole database, and
a fresh replay of all migration files must also rebuild the ledger. The engine is plain
`MergeTree ORDER BY filename` because the ledger is append-only and the runner checks for a
filename *before* applying, so no dedup engine is needed; `ORDER BY filename` is simply the
natural key. Recording happens *after* the file applies, so a mid-file failure leaves the
file unrecorded and the next run retries it (see Idempotence and Recovery for what that
requires of file contents). Filenames are repository-controlled (no quotes or backslashes),
so interpolating `$name` into SQL is safe here.

Adoption on an existing dev database: files 0001–0003 were previously applied without a
ledger. The first run of the new runner re-applies them — harmless, since every statement
in them is `CREATE … IF NOT EXISTS` — and then records them. From that point on the
immutability rule is in force for them too.

Edit the `justfile`: replace the `ch-migrate` recipe body and add `ch-reset`:

```makefile
# Apply unapplied ClickHouse migrations in filename order, recording each in
# analytics.schema_migrations. Migration files are immutable once applied.
ch-migrate:
    ./db/clickhouse/migrate.sh

# Drop the analytics database (including the migration ledger) and replay all
# migrations from scratch. Dev-only; destroys all analytics data.
ch-reset:
    clickhouse-client --port $CLICKHOUSE_TCP_PORT --query "DROP DATABASE IF EXISTS analytics"
    ./db/clickhouse/migrate.sh
```

Delete the duplicated DDL from `kansoku-core/src/Kansoku/ClickHouse.hs`: remove the
functions `ensureSchema`, `createEventsRawTable`, and `openBootstrapConnection`; remove
`ensureSchema` and `openBootstrapConnection` from the module's export list; remove the now
unused imports (`command` from the `ClickHaskell` import list, and the entire
`Data.String (IsString)` import). Nothing outside the two test specs calls any of them
(verified by grep; `kansoku-server/app/Main.hs` only uses `openClickHouse`).

Fix the test bootstrap. Both `kansoku-core/test/Kansoku/ClickHouseSpec.hs` and
`kansoku-core/test/Kansoku/Writer/BatchSpec.hs` have a `withClickHouse` helper that
currently opens a bootstrap connection, pings, runs `ensureSchema`, then opens the real
connection. Replace that block so it opens only the real connection and *probes* the schema
by counting events; any failure (server down *or* schema missing) lands in the existing
`try`/`pendingWith` path, whose message now tells the developer what to do. The shape (both
files, adjusted to whatever EP-10 left in place — EP-10 touches `BatchSpec`'s shibuya types
but not this helper's structure):

```haskell
withClickHouse :: (Connection -> Expectation) -> Expectation
withClickHouse action = do
  configResult <- loadConfig
  case configResult of
    Left err -> expectationFailure ("failed to load config: " <> show err)
    Right cfg -> do
      setupResult <- try @SomeException $ do
        conn <- openClickHouse (clickHouseConfigFromConfig cfg)
        ping conn
        _ <- countEvents conn
        pure conn
      case setupResult of
        Left err ->
          pendingWith
            ("ClickHouse not reachable or schema missing (run `just ch-migrate`): " <> show err)
        Right conn -> action conn
```

`countEvents` runs `SELECT count() FROM events_raw` on the `analytics` database, so it
throws when migrations have not been applied — exactly the signal we want. Update both
files' imports accordingly (drop `ensureSchema`/`openBootstrapConnection`, keep
`countEvents`; `ClickHouseSpec` imports `Kansoku.ClickHouse` wholesale and needs no import
change). The documented dev/test bootstrap flow is now, in order: `just up` (services),
`just ch-migrate` (schema), `just test`. If `README.md`'s development section describes the
old "applies every file" behavior, update that sentence to match.

Acceptance: from the repo root inside `nix develop`, with ClickHouse running, `just
ch-reset` prints one `applying <file>` line per migration file; an immediate second `just
ch-migrate` prints only `skipping <file> (already applied)` lines; `clickhouse-client --port
$CLICKHOUSE_TCP_PORT --query "SELECT filename FROM analytics.schema_migrations ORDER BY
filename"` lists exactly the migration filenames; `cabal build all` and `cabal test all` are
green; and `grep -rn "ensureSchema\|createEventsRawTable" --include='*.hs' .` returns
nothing.

Suggested commit message:

```text
feat(clickhouse): versioned migration ledger; migrations own all DDL

Add analytics.schema_migrations and db/clickhouse/migrate.sh, which applies
only unapplied files in filename order and records each. Migration files are
immutable once applied. Delete the ensureSchema/createEventsRawTable DDL
duplication from Kansoku.ClickHouse; tests bootstrap via `just ch-migrate`
and pend with a hint when the schema is absent.

MasterPlan: docs/masterplans/2-kansoku-production-hardening-review-fixes-and-portfolio-service-readiness.md
ExecPlan: docs/plans/12-clickhouse-schema-v2-sort-key-final-free-resolution-join-free-rollups.md
```


### Milestone 2 — events_raw v2: sort key and Nullable cleanup, with the Haskell row updated

Scope: one migration (`0004_events_raw_v2.sql`) rewrites the raw table with the new sort
key and non-Nullable string columns, swaps it in atomically, and recreates every dependent
object with unchanged (v1) semantics against the new table; the Haskell insert row and the
one load-bearing `Query.hs` predicate are updated in the same change. At the end, the
system behaves exactly as before — same metric numbers, same dedup behavior — on a table
whose sort key and column types are v2, and the old table is retained (as
`analytics.events_raw_v2`, post-swap) for rollback until M4's verified final drop.

The new sort key is `ORDER BY (account_id, event_name, occurred_at, event_id)`:
`account_id` stays leading per the MasterPlan decision (EP-15 makes every metric query
account-scoped); `user_id` is dropped (no query filters on it, it fragments the locality of
the event-name/time ranges every metric scans, and identity-based queries resolve through
the identity map anyway); `event_id` stays, and stays last, because the ORDER BY tuple is
the ReplacingMergeTree dedup identity — it must uniquely identify an event so that only
true replays collapse, and putting the unique column last keeps the index prefix useful.
Note the partition key `toYYYYMM(occurred_at)` is unchanged, and the ReplacingMergeTree
version column is still `received_at`.

The Nullable cleanup: every `Nullable(String)` column becomes `String DEFAULT ''` —
`source_service`, `anonymous_id`, `organization_id`, `session_id`, `url`, `referrer`,
`utm_source`, `utm_medium`, `utm_campaign`, `utm_content`, `utm_term`, `correlation_id`,
`causation_id`, `source_event_id` — with `utm_source`/`utm_medium`/`utm_campaign`
additionally wrapped in `LowCardinality(String)` (bounded domains; see Decision Log for why
`url`/`referrer`/ids must not be wrapped). `anonymous_id` migrates with the rest: 0002's
`mv_identity_map` already filters `anonymous_id != ''`, so the codebase already treats `''`
as absent there. One join-semantics check, thought through so nobody re-derives it: after
the cleanup, `events_resolved`'s `LEFT JOIN … ON e.anonymous_id = m.anonymous_id` could in
principle match rows where both sides are `''` — but `mv_identity_map` never inserts a row
with `anonymous_id = ''` (the filter above), so a `''` key on the events side can never
find a partner; it takes the LEFT JOIN miss path exactly as NULL did. Safe.
`source_global_position` stays `Nullable(UInt64)`: it is a numeric stream position where
`0` is a legitimate value, so any sentinel would lie.

Create `db/clickhouse/migrations/0004_events_raw_v2.sql`:

```sql
-- Schema v2 for the raw events table: sort key (account_id, event_name,
-- occurred_at, event_id) and Nullable(String) -> String DEFAULT ''.
-- Strategy: build events_raw_v2, copy, EXCHANGE names, keep the old table
-- (now named events_raw_v2) until 0007 drops it after verification.
-- Every object reading events_raw is dropped first and recreated against the
-- new table with UNCHANGED v1 semantics; 0005/0006 change semantics later.

DROP TABLE IF EXISTS analytics.mv_identity_map;
DROP TABLE IF EXISTS analytics.mv_daily_event_counts;
DROP TABLE IF EXISTS analytics.mv_dau;
DROP TABLE IF EXISTS analytics.mv_wau;
DROP TABLE IF EXISTS analytics.mv_page_views_by_route;
DROP VIEW IF EXISTS analytics.events_resolved;
DROP TABLE IF EXISTS analytics.events_raw_v2;

CREATE TABLE analytics.events_raw_v2
(
    event_id               String,
    event_name             LowCardinality(String),
    source                 LowCardinality(String),
    source_service         String DEFAULT '',
    occurred_at            DateTime64(3, 'UTC'),
    received_at            DateTime64(3, 'UTC'),
    anonymous_id           String DEFAULT '',
    user_id                String,
    organization_id        String DEFAULT '',
    account_id             String,
    session_id             String DEFAULT '',
    url                    String DEFAULT '',
    referrer               String DEFAULT '',
    utm_source             LowCardinality(String) DEFAULT '',
    utm_medium             LowCardinality(String) DEFAULT '',
    utm_campaign           LowCardinality(String) DEFAULT '',
    utm_content            String DEFAULT '',
    utm_term               String DEFAULT '',
    correlation_id         String DEFAULT '',
    causation_id           String DEFAULT '',
    source_event_id        String DEFAULT '',
    source_global_position Nullable(UInt64),
    properties             String,
    context                String
)
ENGINE = ReplacingMergeTree(received_at)
PARTITION BY toYYYYMM(occurred_at)
ORDER BY (account_id, event_name, occurred_at, event_id);

INSERT INTO analytics.events_raw_v2
    (event_id, event_name, source, source_service, occurred_at, received_at,
     anonymous_id, user_id, organization_id, account_id, session_id, url,
     referrer, utm_source, utm_medium, utm_campaign, utm_content, utm_term,
     correlation_id, causation_id, source_event_id, source_global_position,
     properties, context)
SELECT
    event_id, event_name, source, coalesce(source_service, ''), occurred_at,
    received_at, coalesce(anonymous_id, ''), user_id,
    coalesce(organization_id, ''), account_id, coalesce(session_id, ''),
    coalesce(url, ''), coalesce(referrer, ''), coalesce(utm_source, ''),
    coalesce(utm_medium, ''), coalesce(utm_campaign, ''),
    coalesce(utm_content, ''), coalesce(utm_term, ''),
    coalesce(correlation_id, ''), coalesce(causation_id, ''),
    coalesce(source_event_id, ''), source_global_position, properties, context
FROM analytics.events_raw;

-- Atomic name swap: analytics.events_raw is now the v2 table; the old v1
-- table lives on under the name analytics.events_raw_v2 as the rollback copy.
EXCHANGE TABLES analytics.events_raw AND analytics.events_raw_v2;

-- ---- Recreate dependents against the new table, v1 semantics unchanged ----

CREATE MATERIALIZED VIEW analytics.mv_identity_map
TO analytics.identity_map
AS
SELECT
    anonymous_id,
    user_id,
    received_at AS version
FROM analytics.events_raw
WHERE event_name IN ('identify', 'alias')
  AND anonymous_id != ''
  AND user_id != '';

-- Still FINAL here; 0005 removes it.
CREATE VIEW analytics.events_resolved
AS
SELECT
    e.event_id AS event_id,
    e.event_name AS event_name,
    e.occurred_at AS occurred_at,
    e.url AS url,
    coalesce(nullIf(e.user_id, ''), nullIf(m.user_id, ''), nullIf(e.anonymous_id, ''), '') AS canonical_user
FROM analytics.events_raw AS e FINAL
LEFT JOIN
(
    SELECT
        anonymous_id,
        argMax(user_id, version) AS user_id
    FROM analytics.identity_map
    GROUP BY anonymous_id
) AS m
ON e.anonymous_id = m.anonymous_id;

CREATE MATERIALIZED VIEW analytics.mv_daily_event_counts
TO analytics.daily_event_counts
AS
SELECT
    toDate(occurred_at) AS day,
    event_name AS event_name,
    uniqExactState(toString(event_id)) AS events
FROM analytics.events_raw
GROUP BY day, event_name;

-- Still joining the identity map here; 0005 replaces these two MVs.
CREATE MATERIALIZED VIEW analytics.mv_dau
TO analytics.dau
AS
SELECT
    toDate(e.occurred_at) AS day,
    uniqExactState(coalesce(nullIf(e.user_id, ''), nullIf(m.user_id, ''), nullIf(e.anonymous_id, ''), '')) AS users
FROM analytics.events_raw AS e
LEFT JOIN
(
    SELECT
        anonymous_id,
        argMax(user_id, version) AS user_id
    FROM analytics.identity_map
    GROUP BY anonymous_id
) AS m
ON e.anonymous_id = m.anonymous_id
WHERE coalesce(nullIf(e.user_id, ''), nullIf(m.user_id, ''), nullIf(e.anonymous_id, ''), '') != ''
GROUP BY day;

CREATE MATERIALIZED VIEW analytics.mv_wau
TO analytics.wau
AS
SELECT
    toMonday(e.occurred_at) AS week,
    uniqExactState(coalesce(nullIf(e.user_id, ''), nullIf(m.user_id, ''), nullIf(e.anonymous_id, ''), '')) AS users
FROM analytics.events_raw AS e
LEFT JOIN
(
    SELECT
        anonymous_id,
        argMax(user_id, version) AS user_id
    FROM analytics.identity_map
    GROUP BY anonymous_id
) AS m
ON e.anonymous_id = m.anonymous_id
WHERE coalesce(nullIf(e.user_id, ''), nullIf(m.user_id, ''), nullIf(e.anonymous_id, ''), '') != ''
GROUP BY week;

CREATE MATERIALIZED VIEW analytics.mv_page_views_by_route
TO analytics.page_views_by_route
AS
SELECT
    toDate(occurred_at) AS day,
    path(url) AS route,
    uniqExactState(toString(event_id)) AS views
FROM analytics.events_raw
WHERE event_name = 'page_view'
GROUP BY day, route;
```

(Small mechanical adjustments versus the 0002/0003 texts: `path(coalesce(url, ''))` becomes
`path(url)` since `url` is no longer Nullable — `coalesce(url, '')` would still typecheck,
but the simpler form documents the new type. The `nullIf(e.anonymous_id, '')` and
`nullIf(e.user_id, '')` expressions work identically on plain `String`.)

`EXCHANGE TABLES` requires the database to use the `Atomic` engine, which is ClickHouse's
default; if a nonstandard setup ever refuses it, the fallback is
`RENAME TABLE analytics.events_raw TO analytics.events_raw_old, analytics.events_raw_v2 TO
analytics.events_raw, analytics.events_raw_old TO analytics.events_raw_v2` (one RENAME
statement, still atomic).

Apply with `just ch-migrate`, then run the verification query before considering the
milestone done — the old table must not be dropped until this has been observed to match:

```bash
clickhouse-client --port $CLICKHOUSE_TCP_PORT --query "
  SELECT
    (SELECT count() FROM analytics.events_raw)    AS v2_rows,
    (SELECT count() FROM analytics.events_raw_v2) AS v1_rows"
```

Expected: two equal numbers (`v2_rows` may exceed `v1_rows` only if the writer inserted
during the window — which the "stop the writer" rule forbids). Rollback path while the old
table exists: run `EXCHANGE TABLES analytics.events_raw AND analytics.events_raw_v2` again
(swaps v1 back into place), re-run the CREATE MATERIALIZED VIEW / CREATE VIEW statements
from 0002/0003 to restore the v1 dependents, and delete the 0004 row from the ledger
(`ALTER TABLE analytics.schema_migrations DELETE WHERE filename =
'0004_events_raw_v2.sql'`) so a corrected file can re-apply. The final drop of the old
table is deliberately deferred to migration 0007 in Milestone 4, after the fixture and
storage verification passes.

Haskell edits, same commit (code standards: GHC2024, `Kansoku.Prelude`, strict fields,
postpositive qualified imports — all already in force in these modules; keep them):

In `kansoku-core/src/Kansoku/ClickHouse/EventRow.hs`, change every cleaned column in the
type-level `EventColumns` list from `Maybe ChString` to `ChString` — that is
`source_service`, `anonymous_id`, `organization_id`, `session_id`, `url`, `referrer`,
`utm_source`, `utm_medium`, `utm_campaign`, `utm_content`, `utm_term`, `correlation_id`,
`causation_id`, `source_event_id` — leaving `source_global_position` as `Maybe UInt64`.
(clickhaskell's `LowCardinality(String)` columns accept `ChString` on the wire; no special
column type is needed for the three utm columns.) Change the corresponding `EventRow`
fields from `!(Maybe ByteString)` to `!ByteString`, and in `eventRowFromEvent` map each
optional event field through `maybe ""`, mirroring what `user_id`/`account_id` already do.
Representative before/after for one field of each shape:

```haskell
-- before
      source_service = textBytes <$> event ^. #sourceService,
      session_id = textBytes . unSessionId <$> event ^. #sessionId,
-- after
      source_service = maybe "" textBytes (event ^. #sourceService),
      session_id = maybe "" (textBytes . unSessionId) (event ^. #sessionId),
```

`source_global_position = nonNegativeWord64 =<< event ^. #sourceGlobalPosition` stays as
is.

In `kansoku-core/src/Kansoku/Query.hs`, `buildSessionsSQL` currently emits
`"  AND isNotNull(session_id) AND session_id != ''"`. `session_id` is no longer Nullable
(`isNotNull` would still evaluate — constant 1 — but it is dead weight and misdocuments the
schema). Make the minimal edit to
`"  AND session_id != ''"`. This is the *only* `Query.hs` change in this milestone; the
wholesale builder rewrite is EP-13's (this boundary is recorded in the Decision Log).

Acceptance: `just ch-migrate` applies 0004 (and skips 0001–0003); the row-count
verification matches; `SHOW CREATE TABLE analytics.events_raw` shows the v2 ORDER BY and
non-Nullable columns; `cabal build all` and `cabal test all` are green (the ClickHouseSpec
dedup test — insert twice, `OPTIMIZE TABLE analytics.events_raw FINAL`, count collapses to
1 — proves the new ORDER BY tuple still dedups replays); loading
`db/clickhouse/fixtures/ep5_fixtures.sql` and `ep6_fixtures.sql` on a `just ch-reset`
database still succeeds unchanged (their INSERT column lists are all v2-compatible: `''`
literals into `String DEFAULT ''` columns).

Suggested commit message:

```text
feat(clickhouse)!: events_raw v2 sort key and Nullable cleanup

Rewrite analytics.events_raw via copy + EXCHANGE TABLES: ORDER BY
(account_id, event_name, occurred_at, event_id) — user_id dropped, event_id
stays last as the ReplacingMergeTree dedup identity — and all Nullable(String)
columns become String DEFAULT '' (utm_source/medium/campaign LowCardinality).
Dependent views/MVs recreated with unchanged semantics. EventRow columns go
Maybe ChString -> ChString; sessions predicate drops isNotNull. Old table
retained as analytics.events_raw_v2 until 0007.

MasterPlan: docs/masterplans/2-kansoku-production-hardening-review-fixes-and-portfolio-service-readiness.md
ExecPlan: docs/plans/12-clickhouse-schema-v2-sort-key-final-free-resolution-join-free-rollups.md
```


### Milestone 3 — FINAL-free events_resolved and join-free DAU/WAU materialized views

Scope: one migration (`0005_final_free_resolution.sql`) recreates `events_resolved` without
`FINAL` and replaces `mv_dau`/`mv_wau` with join-free versions that count raw identities,
truncating and backfilling `dau`/`wau` so their contents have one consistent semantics. No
Haskell changes: the dau/wau tables keep their `AggregateFunction(uniqExact, String)`
column type in this milestone (the state function in the new MVs is still
`uniqExactState`), so `Query.hs`'s `uniqExactMerge(users)` keeps working unmodified —
state-type replacement is Milestone 4's single concern. At the end, inserting a block of
events no longer scans the identity map, and reading `events_resolved` no longer forces
merges.

Why removing FINAL is safe, spelled out: `FINAL` collapses not-yet-merged duplicate rows at
read time, and that is *all* it does. Every consumer of `events_resolved` in
`kansoku-core/src/Kansoku/Query.hs` — `uniqueUsersSQL`, `buildRetentionSQL`,
`buildFunnelSQL`, `buildRatioSQL` — aggregates `canonical_user` with `uniqExact` or `min`,
and duplicate input rows cannot change a distinct-count or a minimum. So FINAL was pure
cost. The caveat to carry forward: a query that counts *rows* through `events_resolved`
would see transient replay duplicates and must protect itself (distinct on `event_id`, as
`countEventsSQL` already does on the raw table). This caveat is restated in Interfaces and
Dependencies for EP-13, which owns all future builders.

Why the join-free MVs, spelled out: the old `mv_dau`/`mv_wau` each LEFT JOINed the entire
collapsed identity map (an `argMax … GROUP BY` subquery over all identities ever seen) on
*every inserted block*, twice per batch — insert cost growing with total identities,
forever. Worse, insert-time resolution is frozen: if a person browses anonymously today and
`identify`s tomorrow, today's rollup rows are attributed to the anonymous id permanently,
and the person is double-counted against their user id from tomorrow on. The replacement
aggregates the *raw identity*: the post-cleanup columns are plain `String` with `''` as
absent, so the review's `coalesce(nullIf(user_id,''), nullIf(anonymous_id,''), ''))` shape
simplifies to `if(user_id != '', user_id, anonymous_id)`, filtered to non-empty. The
accepted approximation: dau/wau count raw identities (pre-stitching); an anonymous-then-
identified person contributes both ids on the days each was active. The stitched number
remains available at query time via `events_resolved` (`uniqueUsersSQL` computes exactly
that). Today `activeUsersDaySQL`/`activeUsersWeekSQL` read the rollups, so the
`active_users` metric reports raw-identity counts after this milestone; reconciling which
metric endpoint reads which source is explicitly EP-13's decision (handoff recorded in
Interfaces and Dependencies).

Create `db/clickhouse/migrations/0005_final_free_resolution.sql`:

```sql
-- FINAL-free identity resolution and join-free DAU/WAU.
-- events_resolved consumers aggregate with uniqExact/min, which are
-- insensitive to the transient duplicate rows FINAL would remove; row-COUNT
-- consumers must protect themselves (count DISTINCT event_id).
-- mv_dau/mv_wau stop joining the identity map at insert time and count raw
-- identities (user_id if present, else anonymous_id); the stitched number
-- stays available at query time through events_resolved.

DROP VIEW IF EXISTS analytics.events_resolved;

CREATE VIEW analytics.events_resolved
AS
SELECT
    e.event_id AS event_id,
    e.event_name AS event_name,
    e.occurred_at AS occurred_at,
    e.url AS url,
    coalesce(nullIf(e.user_id, ''), nullIf(m.user_id, ''), nullIf(e.anonymous_id, ''), '') AS canonical_user
FROM analytics.events_raw AS e
LEFT JOIN
(
    SELECT
        anonymous_id,
        argMax(user_id, version) AS user_id
    FROM analytics.identity_map
    GROUP BY anonymous_id
) AS m
ON e.anonymous_id = m.anonymous_id;

DROP TABLE IF EXISTS analytics.mv_dau;
DROP TABLE IF EXISTS analytics.mv_wau;

-- Rebuild dau/wau contents under the new (raw-identity) semantics so the
-- tables are not a mix of stitched and unstitched day states. Column types
-- are unchanged in this migration (still AggregateFunction(uniqExact, String));
-- 0006 replaces the state type.
TRUNCATE TABLE analytics.dau;
TRUNCATE TABLE analytics.wau;

INSERT INTO analytics.dau (day, users)
SELECT
    toDate(occurred_at) AS day,
    uniqExactState(if(user_id != '', user_id, anonymous_id)) AS users
FROM analytics.events_raw
WHERE user_id != '' OR anonymous_id != ''
GROUP BY day;

INSERT INTO analytics.wau (week, users)
SELECT
    toMonday(occurred_at) AS week,
    uniqExactState(if(user_id != '', user_id, anonymous_id)) AS users
FROM analytics.events_raw
WHERE user_id != '' OR anonymous_id != ''
GROUP BY week;

CREATE MATERIALIZED VIEW analytics.mv_dau
TO analytics.dau
AS
SELECT
    toDate(occurred_at) AS day,
    uniqExactState(if(user_id != '', user_id, anonymous_id)) AS users
FROM analytics.events_raw
WHERE user_id != '' OR anonymous_id != ''
GROUP BY day;

CREATE MATERIALIZED VIEW analytics.mv_wau
TO analytics.wau
AS
SELECT
    toMonday(occurred_at) AS week,
    uniqExactState(if(user_id != '', user_id, anonymous_id)) AS users
FROM analytics.events_raw
WHERE user_id != '' OR anonymous_id != ''
GROUP BY week;
```

Acceptance (on a `just ch-reset` database with `just ch-fixtures-ep5` loaded — the ep5
fixture has an anonymous-then-identified visitor `anon-2`/`user-10`, an always-identified
`user-20`, and a never-identified `anon-3`, all on 2026-06-08):

```bash
clickhouse-client --port $CLICKHOUSE_TCP_PORT --query "
  SELECT uniqExactMerge(users) FROM analytics.dau WHERE day = '2026-06-08'"
```

returns `4` — raw identities `user-10`, `anon-2`, `user-20`, `anon-3` (the `f-id` identify
event and `f3`/`f4` carry `user-10`; `f1`/`f2` carry only `anon-2`). And

```bash
clickhouse-client --port $CLICKHOUSE_TCP_PORT --query "
  SELECT uniqExact(canonical_user) FROM analytics.events_resolved
  WHERE canonical_user != '' AND toDate(occurred_at) = '2026-06-08'"
```

returns `3` — the stitched count (`anon-2` resolves to `user-10`). Both numbers observable,
each labeled with its semantics: that is the design. Also verify FINAL is gone:
`SHOW CREATE VIEW analytics.events_resolved` contains no `FINAL`, and
`EXPLAIN SELECT uniqExact(canonical_user) FROM analytics.events_resolved` runs without a
merge-at-read step. `cabal test all` stays green (no Haskell changes here).

Suggested commit message:

```text
feat(clickhouse): FINAL-free events_resolved and join-free dau/wau MVs

events_resolved consumers aggregate with uniqExact/min, so read-time merges
bought nothing; drop FINAL. Replace the insert-time identity-map joins in
mv_dau/mv_wau with raw-identity aggregation (user_id else anonymous_id),
truncating and backfilling dau/wau; stitched counts remain available via
events_resolved at query time.

MasterPlan: docs/masterplans/2-kansoku-production-hardening-review-fixes-and-portfolio-service-readiness.md
ExecPlan: docs/plans/12-clickhouse-schema-v2-sort-key-final-free-resolution-join-free-rollups.md
```


### Milestone 4 — Rollup state replacement, matching Query.hs merges, fixtures, verification

Scope: one migration (`0006_rollups_v2.sql`) rebuilds all four rollup tables with
bounded-size aggregate states and recreates their MVs and contents; a final tiny migration
(`0007_drop_events_raw_v1.sql`) drops the retained v1 table; `Query.hs` gets the three
matching merge-function edits; the fixture files' comments and expected numbers are updated
for v2 semantics; and the full verification suite — fresh migrate, fixtures, metric
equivalence, storage comparison — is run and its transcripts recorded in this plan.

State choices, restated precisely. `countState()` (zero arguments) produces a state of type
`AggregateFunction(count)`, read back with `countMerge(...)` — that is the declaration used
for `daily_event_counts.events` and `page_views_by_route.views`. (A
`SimpleAggregateFunction(sum, UInt64)` fed by `count()` would also work and is marginally
lighter, but `AggregateFunction(count)` keeps the state/merge pairing explicit and uniform
with the other rollups, so it is the one this plan uses.) Replacing exact-distinct-over-
`event_id` with a plain count is justified because duplicate rows in `events_raw` come only
from at-least-once queue replays, which ReplacingMergeTree collapses at the next merge —
duplicates are rare and transient, so count-vs-distinct drift is negligible and temporary;
the raw table remains the source for replay-proof exactness. `dau.users`/`wau.users` become
`AggregateFunction(uniqCombined, String)` fed by `uniqCombinedState(...)` and read with
`uniqCombinedMerge(...)`: a bounded-size sketch, exact at small cardinalities and roughly
0.8% relative error at large ones — the tradeoff accepted for rollups whose size no longer
grows with user count.

Create `db/clickhouse/migrations/0006_rollups_v2.sql`:

```sql
-- Rollup states v2: bounded-size states instead of exact-distinct states that
-- stored every id. events/views: AggregateFunction(uniqExact, String) over
-- event_id -> AggregateFunction(count) (dedup makes duplicate rows rare and
-- transient, so count-vs-distinct drift is negligible; exactness lives in the
-- raw table). dau/wau users: uniqExact -> uniqCombined sketch (~0.8% error at
-- scale, exact for small sets). Tables are rebuilt (state types cannot be
-- ALTERed) and backfilled from events_raw.

DROP TABLE IF EXISTS analytics.mv_daily_event_counts;
DROP TABLE IF EXISTS analytics.mv_dau;
DROP TABLE IF EXISTS analytics.mv_wau;
DROP TABLE IF EXISTS analytics.mv_page_views_by_route;
DROP TABLE IF EXISTS analytics.daily_event_counts;
DROP TABLE IF EXISTS analytics.dau;
DROP TABLE IF EXISTS analytics.wau;
DROP TABLE IF EXISTS analytics.page_views_by_route;

CREATE TABLE analytics.daily_event_counts
(
    day        Date,
    event_name String,
    events     AggregateFunction(count)
)
ENGINE = AggregatingMergeTree
ORDER BY (day, event_name);

CREATE TABLE analytics.dau
(
    day   Date,
    users AggregateFunction(uniqCombined, String)
)
ENGINE = AggregatingMergeTree
ORDER BY day;

CREATE TABLE analytics.wau
(
    week  Date,
    users AggregateFunction(uniqCombined, String)
)
ENGINE = AggregatingMergeTree
ORDER BY week;

CREATE TABLE analytics.page_views_by_route
(
    day   Date,
    route String,
    views AggregateFunction(count)
)
ENGINE = AggregatingMergeTree
ORDER BY (day, route);

-- Backfill from the (already deduplicated-by-merges) raw table.
INSERT INTO analytics.daily_event_counts (day, event_name, events)
SELECT
    toDate(occurred_at) AS day,
    event_name AS event_name,
    countState() AS events
FROM analytics.events_raw
GROUP BY day, event_name;

INSERT INTO analytics.dau (day, users)
SELECT
    toDate(occurred_at) AS day,
    uniqCombinedState(if(user_id != '', user_id, anonymous_id)) AS users
FROM analytics.events_raw
WHERE user_id != '' OR anonymous_id != ''
GROUP BY day;

INSERT INTO analytics.wau (week, users)
SELECT
    toMonday(occurred_at) AS week,
    uniqCombinedState(if(user_id != '', user_id, anonymous_id)) AS users
FROM analytics.events_raw
WHERE user_id != '' OR anonymous_id != ''
GROUP BY week;

INSERT INTO analytics.page_views_by_route (day, route, views)
SELECT
    toDate(occurred_at) AS day,
    path(url) AS route,
    countState() AS views
FROM analytics.events_raw
WHERE event_name = 'page_view'
GROUP BY day, route;

CREATE MATERIALIZED VIEW analytics.mv_daily_event_counts
TO analytics.daily_event_counts
AS
SELECT
    toDate(occurred_at) AS day,
    event_name AS event_name,
    countState() AS events
FROM analytics.events_raw
GROUP BY day, event_name;

CREATE MATERIALIZED VIEW analytics.mv_dau
TO analytics.dau
AS
SELECT
    toDate(occurred_at) AS day,
    uniqCombinedState(if(user_id != '', user_id, anonymous_id)) AS users
FROM analytics.events_raw
WHERE user_id != '' OR anonymous_id != ''
GROUP BY day;

CREATE MATERIALIZED VIEW analytics.mv_wau
TO analytics.wau
AS
SELECT
    toMonday(occurred_at) AS week,
    uniqCombinedState(if(user_id != '', user_id, anonymous_id)) AS users
FROM analytics.events_raw
WHERE user_id != '' OR anonymous_id != ''
GROUP BY week;

CREATE MATERIALIZED VIEW analytics.mv_page_views_by_route
TO analytics.page_views_by_route
AS
SELECT
    toDate(occurred_at) AS day,
    path(url) AS route,
    countState() AS views
FROM analytics.events_raw
WHERE event_name = 'page_view'
GROUP BY day, route;
```

Create `db/clickhouse/migrations/0007_drop_events_raw_v1.sql` — apply this only after the
Milestone 2 row-count verification has been observed to match on every database that
carries data you care about (in practice: the dev box; fresh databases replay the whole
history and the table this drops is the empty v1 shell):

```sql
-- Final step of the events_raw v2 rewrite (0004): drop the retained v1 table.
-- 0004's row-count verification must have passed before this file is created.
DROP TABLE IF EXISTS analytics.events_raw_v2;
```

Edit `kansoku-core/src/Kansoku/Query.hs`, minimal merge-function swaps so the readers match
the new state types (these are the only Query.hs edits in this milestone; the builder
rewrite is EP-13's):

- `activeUsersDaySQL`: `toFloat64(uniqExactMerge(users))` → `toFloat64(uniqCombinedMerge(users))`
- `activeUsersWeekSQL`: `toFloat64(uniqExactMerge(users))` → `toFloat64(uniqCombinedMerge(users))`
- `pageViewsDaySQL`, both branches: `toFloat64(uniqExactMerge(views))` → `toFloat64(countMerge(views))`

Update the fixtures for v2. Neither file's INSERT statements need structural change (their
column lists and `''` literals are v2-compatible), but their guiding comments describe v1
semantics and v1 expected numbers, and comments in fixtures are load-bearing documentation
for anyone verifying by hand. In `db/clickhouse/fixtures/ep5_fixtures.sql`, replace the
header comment: the "identify inserted FIRST so the MVs resolve at insert time" rationale
is obsolete (the MVs no longer resolve anything at insert time; ordering no longer
matters), and the expected numbers are now — dau/wau on 2026-06-08 count **4 raw
identities** (`user-10`, `anon-2`, `user-20`, `anon-3`) while the stitched count through
`events_resolved` is **3**; `f7`/`anon-3` still guards the never-identified-visitor case
(it must appear in both numbers). In `db/clickhouse/fixtures/ep6_fixtures.sql`, extend the
header comment: the duplicate `e2` row still verifies that `countEventsSQL`'s
`count(DISTINCT event_id)` is replay-proof (returns 3 page views on 2026-06-01), **and**
now also makes the accepted rollup drift visible: `mv_page_views_by_route` counts inserted
rows, so the rollup-backed page-views metric reports **4** for 2026-06-01 (the duplicate is
counted; the later `OPTIMIZE … FINAL` collapses the raw rows but cannot retract the
recorded state). That drift is the documented cost of `countState`; production duplicates
are rare, replay-driven, and transient in the raw table.

Acceptance: the full verification suite in Validation and Acceptance below runs clean, its
transcripts are pasted into this plan, `cabal build all` and `cabal test all` are green, and
the MasterPlan's EP-12 milestones can be checked off.

Suggested commit message:

```text
feat(clickhouse): bounded rollup states (countState, uniqCombined) + merges

Rebuild daily_event_counts/page_views_by_route with AggregateFunction(count)
and dau/wau with AggregateFunction(uniqCombined, String); backfill from
events_raw and recreate the MVs. Swap Query.hs merges to countMerge /
uniqCombinedMerge. Update fixture docs for v2 expectations; drop the retained
v1 events_raw copy (0007) after verification.

MasterPlan: docs/masterplans/2-kansoku-production-hardening-review-fixes-and-portfolio-service-readiness.md
ExecPlan: docs/plans/12-clickhouse-schema-v2-sort-key-final-free-resolution-join-free-rollups.md
```


## Concrete Steps

All commands run from the repository root inside `nix develop`, with services up
(`just up` in another terminal) and the kansoku server/writer **stopped** during
migrations. EP-10 must have landed (`cabal build all` green) before starting.

Milestone 1:

```bash
# 1. Create the runner and make it executable
$EDITOR db/clickhouse/migrate.sh    # content in Milestone 1
chmod +x db/clickhouse/migrate.sh
# 2. Rewire justfile (ch-migrate, ch-reset), edit Kansoku/ClickHouse.hs and both specs
# 3. Verify
just ch-reset
just ch-migrate
cabal build all && cabal test all
```

Expected `just ch-reset` output (fresh database, only 0001–0003 exist yet):

```text
applying 0001_events_raw.sql
applying 0002_identity.sql
applying 0003_rollups.sql
```

Expected immediate `just ch-migrate` output:

```text
skipping 0001_events_raw.sql (already applied)
skipping 0002_identity.sql (already applied)
skipping 0003_rollups.sql (already applied)
```

Ledger check:

```bash
clickhouse-client --port $CLICKHOUSE_TCP_PORT \
  --query "SELECT filename FROM analytics.schema_migrations ORDER BY filename"
```

```text
0001_events_raw.sql
0002_identity.sql
0003_rollups.sql
```

Milestone 2:

```bash
$EDITOR db/clickhouse/migrations/0004_events_raw_v2.sql
just ch-migrate            # applies only 0004
clickhouse-client --port $CLICKHOUSE_TCP_PORT --query "
  SELECT (SELECT count() FROM analytics.events_raw) AS v2_rows,
         (SELECT count() FROM analytics.events_raw_v2) AS v1_rows"
# edit EventRow.hs and Query.hs (sessions predicate), then:
cabal build all && cabal test all
```

Expected: `applying 0004_events_raw_v2.sql` (three skips before it); the count query prints
two equal numbers; tests green.

Milestone 3:

```bash
$EDITOR db/clickhouse/migrations/0005_final_free_resolution.sql
just ch-migrate            # applies only 0005
just ch-reset && just ch-fixtures-ep5     # clean fixture state for the checks below
clickhouse-client --port $CLICKHOUSE_TCP_PORT --query \
  "SELECT uniqExactMerge(users) FROM analytics.dau WHERE day = '2026-06-08'"
clickhouse-client --port $CLICKHOUSE_TCP_PORT --query \
  "SELECT uniqExact(canonical_user) FROM analytics.events_resolved
   WHERE canonical_user != '' AND toDate(occurred_at) = '2026-06-08'"
```

Expected: `4` then `3` (raw-identity rollup vs stitched query-time count).

Milestone 4:

```bash
$EDITOR db/clickhouse/migrations/0006_rollups_v2.sql
$EDITOR db/clickhouse/migrations/0007_drop_events_raw_v1.sql   # only after 0004 verification
just ch-migrate            # applies 0006 then 0007
# edit Query.hs merges and both fixture files' comments, then:
cabal build all && cabal test all
# full verification (next section)
```


## Validation and Acceptance

Run every check below after Milestone 4; the milestone-local acceptance criteria above
cover the intermediate states. Paste actual transcripts into this section (replacing the
"expected" blocks) as evidence when done.

First, fresh-database bootstrap. `just ch-reset` on a running dev ClickHouse must replay
the entire history cleanly:

```text
applying 0001_events_raw.sql
applying 0002_identity.sql
applying 0003_rollups.sql
applying 0004_events_raw_v2.sql
applying 0005_final_free_resolution.sql
applying 0006_rollups_v2.sql
applying 0007_drop_events_raw_v1.sql
```

and a second `just ch-migrate` must print seven `skipping … (already applied)` lines.
`SHOW CREATE TABLE analytics.events_raw` must show
`ORDER BY (account_id, event_name, occurred_at, event_id)` and no `Nullable(String)`
column; `SHOW CREATE VIEW analytics.events_resolved` must contain no `FINAL`;
`SHOW CREATE TABLE analytics.mv_dau` must contain no `JOIN`.

Observed on 2026-07-18: the reset printed the seven `applying` lines above, the immediate
second migration printed the matching seven `skipping ... (already applied)` lines, and the
ledger contained all seven filenames in order. Direct schema probes returned:

```text
events_raw sorting key: account_id, event_name, occurred_at, event_id
Nullable(String) column count: 0
events_resolved FINAL position: 0
mv_dau JOIN position: 0
schema_migrations row count: 7
```

Second, fixture-based metric equivalence. Load both fixtures on the fresh database
(`just ch-fixtures-ep5 && just ch-fixtures-ep6`) and compare rollup-backed numbers against
raw-table ground truth. Counts are exact except where the adversarial ep6 duplicate makes
the documented drift visible; uniqCombined is exact at these tiny cardinalities (tolerance
only matters at scale).

```bash
clickhouse-client --port $CLICKHOUSE_TCP_PORT --multiquery <<'SQL'
-- (a) daily_event_counts vs raw distinct, ep5 day: must be EQUAL per event_name
SELECT *
FROM
(
    SELECT 'rollup' AS src, event_name, countMerge(events) AS n
    FROM analytics.daily_event_counts WHERE day = '2026-06-08' GROUP BY event_name
    UNION ALL
    SELECT 'raw' AS src, event_name, count(DISTINCT event_id) AS n
    FROM analytics.events_raw WHERE toDate(occurred_at) = '2026-06-08' GROUP BY event_name
)
ORDER BY event_name, src;
-- (b) dau vs raw identities, ep5 day: must be EQUAL (4); stitched is 3
SELECT uniqCombinedMerge(users) FROM analytics.dau WHERE day = '2026-06-08';
SELECT uniqExact(if(user_id != '', user_id, anonymous_id))
FROM analytics.events_raw
WHERE toDate(occurred_at) = '2026-06-08' AND (user_id != '' OR anonymous_id != '');
SELECT uniqExact(canonical_user) FROM analytics.events_resolved
WHERE canonical_user != '' AND toDate(occurred_at) = '2026-06-08';
-- (c) page_views_by_route, ep5 day: 5 total, split 2/1/1/1 — exact (no dupes)
SELECT route, countMerge(views) AS views
FROM analytics.page_views_by_route WHERE day = '2026-06-08'
GROUP BY route ORDER BY route;
-- (d) ep6 drift demo: raw distinct stays 3; rollup shows 4 (duplicate counted)
SELECT count(DISTINCT event_id) FROM analytics.events_raw
WHERE event_name = 'page_view' AND toDate(occurred_at) = '2026-06-01';
SELECT countMerge(views) FROM analytics.page_views_by_route WHERE day = '2026-06-01';
SQL
```

Observed on 2026-07-18:

```text
raw      feature_used  2
rollup   feature_used  2
raw      identify      1
rollup   identify      1
raw      page_view     5
rollup   page_view     5
4
4
3
/dashboard  1
/docs       1
/pricing    2
/signup     1
3
4
```

The first two `4` values prove the rollup matches raw-identity ground truth; `3` is the
stitched user count because `anon-2` resolves to `user-10`. The final `3`/`4` pair is the
accepted, documented replay drift: raw distinct IDs remain exact while the count-state
rollup preserves the inserted-row count.

Third, end-to-end through the Haskell query layer: `cabal test all` green, and with the server
running against the fixture-loaded database (`just run`), the active-users and page-views
metric endpoints return the numbers above (active_users day 2026-06-08 = 4; page_views day
2026-06-01 = 4, day 2026-06-08 = 5). Exercise whatever metric-query route the post-EP-10
(and possibly post-EP-9) server exposes; the point is that `uniqCombinedMerge`/`countMerge`
flow through `Kansoku.Query` without decode errors.

Observed on 2026-07-18, using the fully qualified executable on isolated port 18080 because
another local process occupied 8080:

```text
GET /health
OK

GET /metrics/users?from=2026-06-08&to=2026-06-09&timeGrain=day
{"metric":"active_users","points":[{"bucket":"2026-06-08","group":{},"value":4}]}

GET /metrics/page-views?from=2026-06-01&to=2026-06-02&timeGrain=day
{"metric":"page_views","points":[{"bucket":"2026-06-01","group":{},"value":4}]}

GET /metrics/page-views?from=2026-06-08&to=2026-06-09&timeGrain=day
{"metric":"page_views","points":[{"bucket":"2026-06-08","group":{},"value":5}]}
```

Fourth, the storage comparison that proves the rollups actually shrank. On the tiny
fixtures the effect is invisible, so generate a synthetic load first. Run this *before*
applying 0006 (i.e., pause after Milestone 3) to capture the "before" numbers, then apply
Milestone 4 and re-measure — or, if M4 already landed, capture only "after" and rely on the
before numbers recorded here. Load:

```bash
clickhouse-client --port $CLICKHOUSE_TCP_PORT --query "
INSERT INTO analytics.events_raw
    (event_id, event_name, source, occurred_at, received_at, user_id, url,
     properties, context)
SELECT
    concat('load-', toString(number)),
    'page_view',
    'web',
    toDateTime64('2026-06-20 00:00:00', 3, 'UTC') + toIntervalSecond(intDiv(number, 10)),
    toDateTime64('2026-06-20 00:00:00', 3, 'UTC') + toIntervalSecond(intDiv(number, 10)),
    concat('u-', toString(number % 500)),
    concat('https://load.test/r', toString(number % 20)),
    concat('{"sample":"', hex(MD5(concat('load-', toString(number)))),
           '","sequence":', toString(number), '}'),
    concat('{"request":"', hex(MD5(concat('ctx-', toString(number)))), '"}')
FROM numbers(100000)"
clickhouse-client --port $CLICKHOUSE_TCP_PORT --multiquery <<'SQL'
OPTIMIZE TABLE analytics.daily_event_counts FINAL;
OPTIMIZE TABLE analytics.page_views_by_route FINAL;
OPTIMIZE TABLE analytics.dau FINAL;
OPTIMIZE TABLE analytics.wau FINAL;
SELECT table, sum(bytes_on_disk) AS bytes
FROM system.parts
WHERE database = 'analytics' AND active
GROUP BY table
ORDER BY table;
SELECT round(
    100.0 * sumIf(bytes_on_disk, table IN
        ('daily_event_counts', 'dau', 'wau', 'page_views_by_route'))
    / sumIf(bytes_on_disk, table = 'events_raw'),
    3) AS combined_rollup_percent_of_raw
FROM system.parts
WHERE database = 'analytics' AND active;
SQL
```

Expected shape (absolute bytes vary by version and compression; the *ratios* are the
acceptance): before 0006, `page_views_by_route` and `daily_event_counts` are within the
same order of magnitude as `events_raw` because their uniqExact states store all 100,000
event IDs. After 0006, those tables collapse to sub-kilobyte count states and `dau`/`wau`
remain small constant-size sketches.

Observed pre-0006 baseline with the original regular/default-JSON load:

```text
daily_event_counts   1607416
dau                     8635
events_raw             731952
identity_map              563
page_views_by_route   1607423
schema_migrations          876
wau                     8613
```

Each event-ID rollup was more than twice the entire raw table. With v2 and the same regular
load, those tables fell to 839 and 946 bytes; all four rollups totaled 10,898 bytes, 67x
smaller than the unusually compressible 731,952-byte raw fixture. The deterministic JSON
entropy in the final command above represents real event payloads and produced this final
transcript:

```text
daily_event_counts       839
dau                     4567
events_raw           8034824
identity_map              563
page_views_by_route       946
schema_migrations         1382
wau                     4546
combined_rollup_percent_of_raw  0.136
dau_users  500
page_views 100000
```

Acceptance: rollup tables' combined bytes are at least two orders of magnitude below
`events_raw` under the representative 100k load (observed 0.136%, roughly 737x smaller),
each exact event-ID rollup has become a sub-kilobyte count-state table, and the page-views
metric over the load day returns 100000 via `countMerge` while
`uniqCombinedMerge(users)` for that day returns 500 (exact at this cardinality; at millions
of users, accept ±0.8%).

Finally, update the MasterPlan registry (EP-12 → Complete) and its Progress checkboxes for
the four EP-12 lines, and write this plan's Outcomes & Retrospective.


## Idempotence and Recovery

The migration runner is idempotent by construction: applied files are skipped, and
`just ch-migrate` can be run any number of times. Recording happens after a file fully
applies, so a failure mid-file leaves it unrecorded and the next run retries the whole
file. For that retry to be safe, every migration file must be internally re-runnable, which
these are: 0001–0003 are pure `CREATE IF NOT EXISTS`; 0004 begins with `DROP … IF EXISTS`
statements including `DROP TABLE IF EXISTS analytics.events_raw_v2`, so a retry that failed
after the copy rebuilds the copy from scratch (duplicate copied rows can never survive
anyway: identical ORDER BY tuples collapse under ReplacingMergeTree); 0005 and 0006 drop
and recreate everything they touch and their backfills follow a `TRUNCATE`/table-recreate;
0007 is `DROP IF EXISTS`.

Two sharp edges, called out. First, 0004's `EXCHANGE TABLES` is the point of no return
within that file: if the file somehow ran *twice* (which the ledger prevents — this is why
the ledger exists), the second exchange would swap the old table back in. Never re-apply
0004 by hand after it has succeeded; the rollback recipe in Milestone 2 (exchange back,
recreate v1 dependents, delete the ledger row) is the only sanctioned reversal, and it is
available only until 0007 drops the retained table. Second, the writer must be stopped
during migration runs: MVs only see inserts that happen while they exist, so an insert
landing between a backfill and its MV recreation would be permanently missing from that
rollup. If that is suspected to have happened in dev, the cheap fix is to re-run the
affected backfill semantics by hand: truncate the rollup table and re-execute its
`INSERT … SELECT` from 0005/0006 (safe because those inserts derive entirely from
`events_raw`).

`just ch-reset` is the universal dev recovery: it drops the `analytics` database (data,
rollups, and ledger together) and replays the full immutable history. It is destructive and
dev-only by design. Fixture loads are *not* idempotent (re-loading inserts duplicate rows
into `events_raw`, which dedup will collapse, but the count-state rollups will have counted
them) — always load fixtures onto a `just ch-reset` database when numbers matter.

Migration files are immutable once applied anywhere. If a landed migration is wrong, write
a new numbered migration that corrects it; never edit the file (the ledger keys on
filename, so an edit would silently not run on any database that already applied it —
exactly the failure mode the old mechanism had).


## Interfaces and Dependencies

Hard dependency: EP-10 (`docs/plans/10-restore-the-build-and-supervise-the-writer.md`).
EP-10 is complete and restored the build; every Haskell edit and `cabal test all` gate in this
plan uses that baseline. EP-10 also changed `kansoku-core/test/Kansoku/Writer/BatchSpec.hs`
from Shibuya `Ingested` to `Message`; Milestone 1 preserved that completed shape while changing
the file's `withClickHouse` helper.

ClickHouse objects that exist at the end (all owned exclusively by
`db/clickhouse/migrations/`): `analytics.schema_migrations` (MergeTree, `filename` +
`applied_at`); `analytics.events_raw` (ReplacingMergeTree(received_at), PARTITION BY
toYYYYMM(occurred_at), ORDER BY `(account_id, event_name, occurred_at, event_id)`, all
string columns non-Nullable with `''` = absent, `source_global_position Nullable(UInt64)`);
`analytics.identity_map` + `analytics.mv_identity_map` (unchanged semantics);
`analytics.events_resolved` (plain view, no FINAL, LEFT JOIN of the collapsed identity
map); `analytics.daily_event_counts(day, event_name, events AggregateFunction(count))`;
`analytics.dau(day, users AggregateFunction(uniqCombined, String))`;
`analytics.wau(week, users AggregateFunction(uniqCombined, String))`;
`analytics.page_views_by_route(day, route, views AggregateFunction(count))`; and the four
MVs feeding them, all join-free.

Haskell interfaces at the end: `Kansoku.ClickHouse` (in
`kansoku-core/src/Kansoku/ClickHouse.hs`) no longer exports `ensureSchema` or
`openBootstrapConnection` and contains no DDL; `openClickHouse`, `insertEvents`,
`countEvents`, `selectEventProjections` keep their signatures.
`Kansoku.ClickHouse.EventRow.EventColumns` uses `ChString` (not `Maybe ChString`) for all
cleaned columns and `Maybe UInt64` only for `source_global_position`;
`EventRow`'s corresponding fields are strict `ByteString`; `eventRowFromEvent` maps
optional event fields via `maybe ""`. `Kansoku.Query` builder signatures are unchanged;
only the emitted SQL differs (`session_id != ''`; `uniqCombinedMerge(users)`;
`countMerge(views)`).

Handoffs to sibling plans, stated explicitly per the MasterPlan's Integration Points:

To EP-13 (`docs/plans/13-safe-and-correct-metric-sql-validated-inputs-ordered-funnels-honest-failures.md`),
which hard-depends on this plan: (1) all SQL builders it rewrites target the v2 objects
above; (2) `events_resolved` has no FINAL, so any builder that counts *rows* through it
must protect itself with `count(DISTINCT event_id)` — distinct/min aggregations need
nothing; (3) dau/wau rollups now mean *raw identities pre-stitching*, while
`events_resolved` gives stitched counts — EP-13 owns deciding which metric endpoint reads
which source and documenting the choice user-visibly; (4) rollup readers must use
`countMerge`/`uniqCombinedMerge` (this plan already made those minimal swaps so the system
stays green); (5) any new ClickHouse object goes through a new numbered migration file —
never edit an applied one.

To EP-15 (`docs/plans/15-api-keys-service-auth-and-account-scoped-queries.md`):
`account_id` leads the v2 sort key precisely so its mandatory account predicate turns into
primary-index pruning; no schema change should be needed there. Note for EP-15: the rollup
tables are *not* account-scoped (no `account_id` in their keys); if account-scoped
active-users/page-views are required, that is a new rollup design routed through this
plan's migration mechanism (and likely EP-13's query-source decision).

To EP-16 (`docs/plans/16-pipeline-observability-queue-depth-writer-lag-and-exported-telemetry.md`):
same migration-mechanism rule for any observability tables.

External tools and libraries relied on: `clickhouse-client` (provided by the nix dev shell;
all recipes address it via `--port $CLICKHOUSE_TCP_PORT`), ClickHouse server with Atomic
database engine (default; required for `EXCHANGE TABLES`, RENAME fallback documented in
Milestone 2), the clickhaskell library (`ClickHaskell` module) for typed inserts/selects —
column types in `EventColumns` must mirror the table exactly — and `just`/`bash` for the
runner. Haskell code standards for all edits: GHC2024, `Kansoku.Prelude`, postpositive
qualified imports, generic-lens `#labels` optics, strict fields, explicit deriving;
embedded SQL in Haskell uses MultilineStrings (after this plan, the only embedded SQL left
in `kansoku-core` is query-side, in `Kansoku.Query` — DDL lives only in migration files).

---

Revision note (2026-07-18): implementation began with the MasterPlan Intention ID, M1 was
completed and verified, and project-wide test commands were corrected from bare
`cabal test` to `cabal test all` after current Cabal returned `Cabal-7134` without an
explicit target.

Revision note (2026-07-18, second revision): M2 completed the events_raw v2 rewrite, Haskell
wire-type alignment, sessions predicate cleanup, non-empty row-count verification, and
fresh-reset fixture compatibility checks.

Revision note (2026-07-18, third revision): M3 removed `FINAL`, made DAU/WAU materialized
views join-free, captured the 4-raw/3-stitched fixture evidence, and recorded the pre-M4
100,000-event storage baseline.

Revision note (2026-07-18, fourth revision): M4 replaced exact-distinct rollup states,
aligned Haskell merges and public metric descriptions, dropped the verified v1 table, and
captured fresh replay, fixture, HTTP, and representative 100,000-event storage evidence.
The ClickHouse 26 UNION alias workaround, deterministic JSON benchmark data, explicit Cabal
targets, local Postgres ledger drift, and port collision are documented for restartability.
