---
id: 5
slug: identity-stitching-and-materialized-view-rollups
title: "Identity stitching and materialized view rollups"
kind: exec-plan
created_at: 2026-07-01T16:04:44Z
intention: "intention_01kwf425fxenc904ear54cr2n7"
master_plan: "docs/masterplans/1-kansoku-analytics-service-mvp.md"
---

# Identity stitching and materialized view rollups

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Kansoku (観測, "observation") is a self-hostable analytics service. Its raw events already
land in a ClickHouse table called `analytics.events_raw` (created by the sibling plan
`docs/plans/3-clickhouse-storage-schema-and-batch-writer.md`, "EP-3"). Raw events are the
truth, but answering everyday product questions by scanning every raw row on each request is
slow and, worse, gives *wrong* numbers for "how many people are active" because one human
being can appear in the raw data under several different identifiers.

After this plan is complete, two new capabilities exist and can be demonstrated end to end:

First, **identity stitching**. Before a person logs in, the events they generate carry only
an `anonymous_id` (a random id the browser SDK assigns) and a `session_id`. After they log
in, their events carry a real `user_id` (and often an `account_id`/`organization_id`). A
special "identify" event ties the anonymous id to the user id. Kansoku must be able to treat
"the anonymous visitor who browsed the pricing page" and "the logged-in user who then created
a document" as **one person** when counting active users — without editing the historical
raw rows. We do this with a small lookup table, `analytics.identity_map`, that maps
`anonymous_id → user_id`, plus a query-time rule that resolves any event to a single
canonical user id using
`coalesce(nullIf(user_id, ''), nullIf(identity_map.user_id, ''), nullIf(anonymous_id, ''), '')`.
You will be able to insert a few anonymous events, then an identify event, plus one page view
from a second visitor who never logs in, then run one query and see the count come back as
**2** — the stitched visitor counts once, and the never-identified visitor still counts as one
real actor under their anonymous id — where the unstitched data naively shows 3.

Second, **materialized-view rollups**. A ClickHouse *materialized view* (hereafter "MV") is a
trigger: every time rows are inserted into a source table, the MV runs a small `SELECT` over
just those new rows and appends the result into a second, much smaller "target" table. We
build MVs that continuously maintain: daily event counts broken down by event name; daily
active users (DAU) and weekly active users (WAU) counted by resolved user id; and page views
grouped by route (the path part of a URL). After this plan, querying "how many events of each
type happened on 2026-06-01" or "DAU for last week" reads a handful of pre-aggregated rows
instead of the full raw table, and the next plan
(`docs/plans/6-semantic-metrics-layer-and-typed-query-api.md`, "EP-6") builds its HTTP
metrics API directly on top of the object names this plan defines.

The single trickiest correctness requirement, called out explicitly so it is never lost:
because `analytics.events_raw` accepts the *same event more than once* (the ingestion
pipeline is at-least-once, so a crash can redeliver a batch), MVs fire on every inserted row
including those duplicates. If a rollup naively did `count()`, a redelivered batch would
double-count. This plan makes every rollup **idempotent under duplicate rows** by counting
`uniqExact(event_id)` (the exact number of *distinct* event ids) rather than raw row counts,
and by counting `uniqExact(canonical_user)` for active users. You will prove this with a
redelivery test that re-inserts a batch and shows the numbers do not move.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Milestone 0: confirm prerequisites — `clickhouse-client` on PATH reaches the dev server,
  `analytics.events_raw` exists (create a compatible stand-in if EP-3 has not landed yet), and
  the repo `.gitignore` no longer ignores `db/clickhouse/` (EP-3 owns that narrowing; verify
  with `git check-ignore`).
- [ ] Milestone 1: create `db/clickhouse/migrations/0002_identity.sql` with
  `analytics.identity_map` (ReplacingMergeTree), the `analytics.mv_identity_map` materialized
  view, and the `analytics.events_resolved` view; apply it idempotently.
- [ ] Milestone 1: worked example — insert anonymous events, then an identify event, then a
  post-login event, plus a page view from a never-identified visitor; query
  `analytics.events_resolved` and observe **two** distinct actors (the stitched pair collapses
  to one; the never-identified visitor survives under their own anonymous id, not `''`).
- [ ] Milestone 2: create `db/clickhouse/migrations/0003_rollups.sql` with the four target
  tables (`daily_event_counts`, `dau`, `wau`, `page_views_by_route`) and their four MVs.
- [ ] Milestone 2: verify daily event counts and DAU/WAU against fixtures with exact expected
  numbers (including the never-identified visitor counting toward DAU/WAU), using
  `uniqExactMerge` read-back.
- [ ] Milestone 2: redelivery test — re-insert a batch with duplicate `event_id`s and assert
  every rollup number is unchanged (proves duplicate-tolerant aggregation).
- [ ] Milestone 3: verify `page_views_by_route` (created in Milestone 2's `0003_rollups.sql`)
  extracts the route from `url` and counts each route once per distinct page-view event,
  duplicate-safe.
- [ ] Wire the two SQL files into the migration mechanism (a `just` recipe and/or the bash
  apply loop documented here) so they run on a fresh checkout.
- [ ] Update Surprises & Discoveries, Decision Log, and Outcomes as work proceeds; commit with
  the trailers documented in Concrete Steps.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Resolve identity at query time via a lookup table `analytics.identity_map`
  (`anonymous_id → user_id`) plus a
  `coalesce(nullIf(user_id,''), nullIf(identity_map.user_id,''), nullIf(anonymous_id,''), '')`
  rule, rather than mutating historical rows in `analytics.events_raw`.
  Rationale: `docs/initial-spec.md` ("Identity Stitching") explicitly says to avoid mutating
  raw historical events and to resolve identity in query-time views or derived tables.
  Rewriting past rows in a columnar store is expensive and destroys the audit trail; a small
  side table keyed on `anonymous_id` is cheap to maintain and read.
  Date: 2026-07-01

- Decision: Make `analytics.identity_map` a `ReplacingMergeTree(version)` ordered by
  `anonymous_id`, populated by a materialized view from `identify`/`alias` events, with
  `version` taken from the event's `received_at`.
  Rationale: A person may re-identify; we want the *latest* `user_id` for an `anonymous_id`.
  ReplacingMergeTree keyed on `anonymous_id` collapses to one row per anonymous id, and the
  `version` column lets both merges and `argMax(user_id, version)` pick the newest mapping.
  Duplicate identify events (from at-least-once redelivery) produce identical rows that
  collapse harmlessly.
  Date: 2026-07-01

- Decision: Count `uniqExact(event_id)` (distinct event ids) for event-count and page-view
  rollups, and `uniqExact(canonical_user)` for DAU/WAU, using `AggregatingMergeTree` target
  tables and the `uniqExactState`/`uniqExactMerge` state combinators — never plain `count()`
  or `SummingMergeTree` of row counts.
  Rationale: `analytics.events_raw` is a `ReplacingMergeTree` and can hold duplicate
  `event_id` rows before a background merge collapses them; MVs fire on the raw inserted rows
  including those duplicates. A `count()`/`SummingMergeTree` rollup would double-count a
  redelivered batch. `uniqExact` over the natural key (`event_id`) is idempotent: inserting
  the same event twice adds the same id, which is still counted once. This is the MVP's chosen
  answer to the at-least-once redelivery hazard recorded in the MasterPlan.
  Date: 2026-07-01

- Decision: Resolve the canonical user id *inside* the DAU/WAU materialized views by
  `LEFT JOIN`ing the inserted block against `analytics.identity_map`
  (`coalesce(nullIf(user_id,''), nullIf(m.user_id,''), nullIf(anonymous_id,''), '')`), and
  additionally provide a query-time view `analytics.events_resolved` that performs the same
  resolution over the whole raw table for authoritative, order-independent counts.
  Rationale: A ClickHouse MV resolves only with the mapping that exists at insert time, so an
  event that arrives *before* its identify event is aggregated under its anonymous id and is
  not retroactively re-keyed (MVs never re-fire for old rows). This is an inherent limitation
  of insert-time rollups. We accept it for the fast DAU/WAU rollups (correct whenever identify
  precedes or accompanies the events, which is the common case since post-login events carry
  `user_id` directly), and we give EP-6 an exact, late-identify-correct path via
  `analytics.events_resolved` for correctness-critical user numbers. Documenting both keeps the
  precision boundary explicit.
  Date: 2026-07-01

- Decision: Derive the page route with ClickHouse's `path()` function (the path portion of
  a URL, e.g. `/pricing` from `https://app.example.com/pricing?ref=x`), written as
  `path(coalesce(url, ''))` because EP-3's `url` column is `Nullable(String)`, grouping page
  views by `(day, route)`.
  Rationale: `path()` strips the scheme, host, and query string, giving a stable route key
  without custom parsing. Query-string variation would otherwise fragment one logical page
  into many rows. The `coalesce(url, '')` keeps the expression non-Nullable so a `page_view`
  with an absent url produces route `''` instead of a `NULL` that would fail insertion into
  the non-Nullable `route String` target column.
  Date: 2026-07-01

- Decision: Ship the DDL as numbered, re-runnable `IF NOT EXISTS` SQL files under
  `db/clickhouse/migrations/` (`0002_identity.sql`, `0003_rollups.sql`), applied by the same
  file-based mechanism EP-3 establishes (a `just` recipe) with a self-contained `clickhouse-client`
  bash loop documented as the fallback.
  Rationale: The MasterPlan's Integration Points require this plan to wire into EP-3's
  migration mechanism. Numbered files applied in lexical order, each idempotent, are safe to
  re-run and easy for a novice to apply without the Haskell toolchain. `0001_*` is reserved for
  EP-3's `events_raw` migration.
  Date: 2026-07-01

- Decision: Write every canonical-user expression as
  `coalesce(nullIf(e.user_id, ''), nullIf(m.user_id, ''), nullIf(e.anonymous_id, ''), '')` —
  wrapping the join-side column `m.user_id` in `nullIf(..., '')` and terminating the coalesce
  with a literal `''` — in all three definitions (`events_resolved`, `mv_dau`, `mv_wau`).
  Rationale: ClickHouse defaults to `join_use_nulls = 0`, which means a `LEFT JOIN` **miss**
  fills the right side's columns with the type's *default value*, not SQL `NULL`; for a
  `String` column that default is `''`, which is NOT NULL. With the earlier
  `coalesce(nullIf(e.user_id,''), m.user_id, nullIf(e.anonymous_id,''))`, every
  never-identified anonymous event (no row in `identity_map`) made `coalesce` stop at the
  non-NULL `m.user_id = ''` and return `''` — the anonymous-id fallback could never fire.
  Consequences of the defect: never-identified visitors were silently dropped from DAU/WAU
  (the MVs filter `... != ''`) and all collapsed into a single `''` bucket in
  `events_resolved`. Wrapping `m.user_id` in `nullIf` turns the join-miss `''` back into
  `NULL` so the fallback fires, and the trailing `''` literal makes the whole expression a
  plain (non-Nullable) `String` — so `uniqExactState(canonical_user)` still produces
  `AggregateFunction(uniqExact, String)` matching the declared target columns, and the
  existing `!= ''` filters keep meaning "unattributable". The alternative — adding
  `SETTINGS join_use_nulls = 1` to each view — was rejected so the DDL stays correct
  independent of server/session settings.
  Date: 2026-07-01

- Decision: Keep `uniqExactState` for all MVP rollups, accepting its state size, and record
  `uniqCombinedState` as the at-volume replacement for DAU/WAU.
  Rationale: `uniqExactState` stores the exact set of distinct values per aggregation bucket —
  for DAU the state for one day is literally the set of every canonical user id seen that day.
  That is what makes the rollups exactly correct and replay/redelivery-tolerant, and at MVP
  volumes the per-day/per-week sets are small, so this is a deliberate correctness-first
  trade. At volume (states of millions of ids per bucket) the DAU/WAU tables should switch to
  `uniqCombinedState`/`uniqCombinedMerge` (an approximate distinct-count sketch with a fixed,
  roughly kilobyte-sized state) while keeping the exact path available at query time via
  `uniqExact(canonical_user)` over `analytics.events_resolved` when a precise number is
  required. Changing the state function requires new target tables and a backfill (states are
  not convertible in place), which is why the choice is recorded now for the post-MVP owner.
  Date: 2026-07-01


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

Read this section assuming you know nothing about this repository. Everything you need to
succeed is here.

**Where you are.** The repository root is
`/Users/shinzui/Keikaku/bokuno/kansoku-project/kansoku`. It is a Haskell project built with
Nix (GHC 9.12.4). The development environment starts a ClickHouse server for you; there is a
`clickhouse-client` command-line program on your PATH that connects to it over TCP port 9000
(the HTTP interface is on port 8123). ClickHouse is a *columnar* SQL database: it stores each
column separately, which makes it very fast at scanning and aggregating huge append-only
tables but poor at row-by-row updates. That property is exactly why this plan resolves
identity with a side table and query-time rules instead of updating existing rows.

**Terms used in this plan, defined once.**

- **`analytics.events_raw`**: the ClickHouse table that stores every ingested analytics event,
  one row per event. It is created by EP-3
  (`docs/plans/3-clickhouse-storage-schema-and-batch-writer.md`). This plan only *reads* from
  it (via materialized views and views); it never alters it. The columns this plan depends on,
  taken from the MasterPlan's "ClickHouse `analytics.events_raw` schema and `EventRow`"
  integration point, are: `event_id` (the unique id of the event), `event_name` (a string like
  `page_view`, `identify`, `feature_used`), `source` (one of `web`/`app`/`service`/`worker`/
  `email`/`agent`), `occurred_at` and `received_at` (timestamps), `anonymous_id`, `user_id`,
  `organization_id`, `account_id`, `session_id`, `url`, and the `utm_*` marketing columns.
  Per EP-3's authoritative DDL, `user_id` and `account_id` are non-nullable `String` (absent =
  `''`, the type default), while the optional columns (`anonymous_id`, `session_id`, `url`,
  `referrer`, the `utm_*` family, and the lineage columns) are `Nullable(String)` (absent =
  `NULL`, though writers may also store `''`). This plan's emptiness tests are written to be
  robust to **both** conventions: `nullIf(col, '')` maps `''` to `NULL` and passes `NULL`
  through unchanged, so `coalesce` fallback chains treat `''` and `NULL` identically, and a
  `col != ''` predicate excludes both `''` (compares false) and `NULL` (comparison yields
  `NULL`, which is not true). Per EP-3, `event_id` is a ClickHouse `String` (ClickHaskell
  `ChString`) — because
  `AnalyticsEvent.eventId` is a free-form `Text` id from many external emitters, not necessarily
  a UUID — so this plan keys on `event_id` as a `String`. The `toString(event_id)` wrappers used
  below are therefore harmless no-ops kept only for defensiveness, and every timestamp is handled
  with `toDate(...)`/`toMonday(...)` which accept both `DateTime` and `DateTime64`.

- **`ReplacingMergeTree`**: a ClickHouse table engine that, during background merges, keeps
  only the last row for each value of the table's sort key (`ORDER BY`). "Last" is decided by
  an optional version column. It does *not* deduplicate instantly on insert — duplicates coexist
  until a merge runs — so any query that must not see duplicates either uses the `FINAL`
  keyword (which forces the collapse at read time) or aggregates in a duplicate-tolerant way.
  EP-3 uses this engine for `events_raw` so that a redelivered event (same `event_id`)
  eventually collapses to one physical row.

- **`AggregatingMergeTree`**: a ClickHouse table engine whose columns can hold *partial
  aggregation states* (type `AggregateFunction(func, argType)`). During merges it combines the
  states of rows that share the sort key. You write states into it with `func`**`State`**
  (e.g. `uniqExactState(x)`) and read finished values out with `func`**`Merge`** (e.g.
  `uniqExactMerge(col)`) under a `GROUP BY`. We use it for every rollup so that the running
  total of "distinct event ids" or "distinct users" is maintained incrementally.

- **`uniqExact`**: an aggregate that returns the exact number of distinct values it saw. Its
  state combinator `uniqExactState` stores a set of the distinct values; `uniqExactMerge`
  unions those sets and returns the count. Because it counts *distinct* values, feeding it the
  same `event_id` twice (a duplicate) still counts one. This is the property that makes our
  rollups immune to at-least-once redelivery.

- **Materialized view (MV)**: in ClickHouse, `CREATE MATERIALIZED VIEW v TO target AS SELECT
  ...` creates an insert trigger. Whenever rows are inserted into the table named in the
  `SELECT`'s `FROM`, ClickHouse runs the `SELECT` over *only that newly inserted block of
  rows* and appends the result into `target`. It does **not** re-run over historical rows and
  it does **not** re-run when some *other* table (such as `identity_map`) changes. Understanding
  this "fires once, on the new block, at insert time" behavior is essential to the identity
  design below.

- **Canonical user id / identity stitching**: mapping the several ids a single human can carry
  (`anonymous_id` before login, `user_id` after) down to one id so counts of "people" are
  correct. Our rule is
  `coalesce(nullIf(user_id, ''), nullIf(identity_map.user_id, ''), nullIf(anonymous_id, ''), '')`:
  prefer the real user id on the event; otherwise look up the user id that a prior `identify`
  event tied to this `anonymous_id`; otherwise fall back to the anonymous id itself (a visitor
  we have never seen log in still counts as one distinct actor); otherwise `''`, meaning "no
  attributable actor at all". The `nullIf(identity_map.user_id, '')` wrapper is load-bearing —
  see the join_use_nulls trap explained in Milestone 1 and the Decision Log — and the trailing
  `''` literal keeps the expression's type a plain non-Nullable `String`.

- **Identity events**: ordinary `AnalyticsEvent`s whose `event_name` is one of `identify`,
  `alias`, or `group`. This convention is defined by EP-2
  (`docs/plans/2-canonical-event-model-and-schema-registry.md`). `identify` and `alias`
  associate an `anonymous_id` with a `user_id`; `group` associates a `user_id` with an
  `account_id`/`organization_id`. This plan builds the `anonymous_id → user_id` map from
  `identify` and `alias` (that is what active-user counting needs); `group` handling is noted
  as an optional extension and is not required for the MVP metrics. **Pinned `alias`
  semantics:** the anon→user reading of `alias` follows EP-2's `aliasEvent` smart constructor,
  which places the `anonymousId` and the `userId` directly on the event itself (so
  `anonymous_id` and `user_id` are both populated on the same `events_raw` row). That is
  exactly what `analytics.mv_identity_map`'s `WHERE event_name IN ('identify', 'alias') AND
  anonymous_id != '' AND user_id != ''` and its `(anonymous_id, user_id, received_at)` column
  selection assume. If EP-2 ever changes `aliasEvent`'s definition (for example, moving the
  previous id into a property instead of the `anonymous_id` field), `mv_identity_map`'s WHERE
  clause and selected columns must be changed in lockstep, or alias mappings will silently
  stop being learned.

**What already exists vs. what this plan adds.** EP-3 owns `analytics.events_raw`, the Haskell
`EventRow` record, and the batched `insertEvents` function that writes rows into it. This plan
adds only ClickHouse DDL, under a new directory `db/clickhouse/migrations/`, plus fixture SQL
under `db/clickhouse/fixtures/`. It writes no Haskell application code. The tests here insert
fixture rows with `clickhouse-client` directly (which produces exactly the same rows
`insertEvents` would), so this plan is fully verifiable even if EP-4's live ingestion pipeline
is not running yet.

**Coding standards (for the SQL here and any Haskell that reads these objects).** This plan
adds only ClickHouse DDL (`.sql` files) and fixtures; it writes no Haskell. Those SQL files stay
as plain files applied with `clickhouse-client`, so they are not subject to the Haskell house
style. They are, however, the source of truth for the object names and read patterns that EP-6
will wrap in ClickHaskell, and that Haskell must follow the shared conventions in
`/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/core/` (`standards.md`, `custom-prelude.md`,
`record-patterns.md`, `multiline-strings.md`): every module opens with `import Kansoku.Prelude`
(the prelude EP-1 exposes from the `kansoku:kansoku-api` sub-library, re-exporting `Text`,
`Generic`, aeson, `time`, `NonEmpty`, and the `lens` operators); EP-1's `common` cabal stanza
sets `default-language: GHC2024` with `default-extensions: DeriveAnyClass, DuplicateRecordFields,
OverloadedLabels, OverloadedStrings, MultilineStrings` and every stanza does `import: common`;
qualified imports are postpositive (`import X qualified as M`); records use strict `!` fields, no
field prefixes, and explicit deriving; field access uses generic-lens `#label`; and any SQL
embedded in Haskell (for example the `uniqExactMerge` read queries EP-6 issues) is written as a
`"""..."""` MultilineString literal rather than `unlines` or an escaped one-liner. When EP-6
mirrors a `SELECT` shown here into ClickHaskell, keep the query text byte-for-byte and use the
MultilineString form.

**Sequencing note.** This plan hard-depends on EP-3 (it layers views on `events_raw`). If you
arrive here before EP-3 has been implemented, Milestone 0 tells you how to create a minimal,
compatible `analytics.events_raw` stand-in so you can still build and verify everything; when
EP-3 lands, its migration `0001_*.sql` supersedes the stand-in and no rework is needed because
the column names match the MasterPlan contract.


## Plan of Work

The work proceeds in one preparatory step and three verifiable milestones. Each milestone ends
with concrete `clickhouse-client` output you can compare against expected numbers.

### Milestone 0 — Prerequisites and directory layout

Scope: make sure the tools and the source table are present, and create the directory this
plan writes into. At the end, `clickhouse-client -q "SELECT 1"` returns `1`, the database
`analytics` exists, and `analytics.events_raw` exists (either from EP-3 or from the stand-in
below). Nothing here changes application code.

Create the directory `db/clickhouse/migrations/` and `db/clickhouse/fixtures/` at the repo
root. If EP-3 has already created `db/clickhouse/migrations/0001_events_raw.sql`, leave it. If
`analytics.events_raw` does not yet exist, apply the compatible stand-in given in Concrete
Steps (a byte-for-byte copy of EP-3's authoritative `CREATE TABLE`) so this plan can proceed
independently; it uses `CREATE ... IF NOT EXISTS`, so it is harmless once EP-3's real
migration is present.

One repository precondition, owned by EP-3: the repo `.gitignore` historically ignored `db/`
wholesale (it is the Postgres state directory, `PGHOST=$PWD/db`), which would make every file
this plan writes under `db/clickhouse/` uncommittable. EP-3 owns narrowing that ignore from
`db/` to `db/*` plus the negation `!db/clickhouse/` so migrations are tracked. Before
committing this plan's files, verify the narrowing has landed:
`git check-ignore db/clickhouse/migrations/0002_identity.sql` must print nothing and exit
non-zero (exit 1 means "not ignored" — that is the good outcome). If it prints the path, stop
and apply EP-3's `.gitignore` change first; do not work around it with `git add -f`.

### Milestone 1 — Identity map, resolution view, and the worked example

Scope: introduce query-time identity resolution. At the end there is a new file
`db/clickhouse/migrations/0002_identity.sql` that creates `analytics.identity_map`, the
materialized view `analytics.mv_identity_map` that fills it from `identify`/`alias` events, and
the view `analytics.events_resolved` that exposes each event together with its canonical user
id. The acceptance test inserts two anonymous page views under `anon-1`, then an `identify`
event tying `anon-1` to `user-1`, then a post-login event under `user-1`, and finally a page
view under `anon-3` from a visitor who **never** identifies, and shows that
`SELECT uniqExact(canonical_user) FROM analytics.events_resolved` returns **2** — the anonymous
visitor and the logged-in user are recognized as one person, and the never-identified visitor
still counts as one distinct actor under `anon-3` (not dropped, not collapsed into an empty
string). It also shows the raw, unresolved count would have been 3, making the value of
stitching visible, and it checks the never-identified event's `canonical_user` literally
equals `anon-3` — the regression guard for the join_use_nulls trap described there.

The MV that fills the map reads, for every newly inserted `identify`/`alias` event with a
non-empty `anonymous_id` and `user_id`, the pair `(anonymous_id, user_id, received_at)` and
appends it to `identity_map`. Because `identity_map` is a `ReplacingMergeTree(version)` ordered
by `anonymous_id`, only the newest mapping per anonymous id survives a merge, and reads use
`argMax(user_id, version)` so the answer is correct even before a merge runs. The
`events_resolved` view left-joins each raw event to the latest mapping and computes the
canonical id with the `coalesce` rule; it reads `events_raw FINAL` so that duplicate raw rows
do not appear twice in row-level queries.

### Milestone 2 — Daily event counts and DAU/WAU rollups, duplicate-tolerant

Scope: introduce the count rollups. At the end there is
`db/clickhouse/migrations/0003_rollups.sql` creating **all four** `AggregatingMergeTree` target
tables — `analytics.daily_event_counts`, `analytics.dau`, `analytics.wau`, and
`analytics.page_views_by_route` — and their four materialized views
`analytics.mv_daily_event_counts`, `analytics.mv_dau`, `analytics.mv_wau`, and
`analytics.mv_page_views_by_route`. (Creating all four in one file keeps the DDL together and
lets one fixture batch feed every rollup; Milestone 3 then *verifies* the page-views rollup, it
does not create it.) Daily event counts are keyed on `(day, event_name)` and store
`uniqExactState(toString(event_id))`. DAU is keyed on `day` and stores
`uniqExactState(canonical_user)` where the canonical user is resolved against `identity_map`
at insert time; WAU is the same but keyed on the Monday of the week (`toMonday(occurred_at)`).
The acceptance test inserts a known fixture batch — which deliberately includes a
never-identified visitor (`anon-3`) so the join_use_nulls trap can never silently regress —
and reads each rollup back with `uniqExactMerge`, comparing to exact expected numbers, then
re-inserts the same batch (with duplicate `event_id`s) and shows every number is unchanged.
This is the milestone that proves the redelivery-safety requirement.

Because the DAU/WAU MVs resolve identity at insert time, the fixture for the rollup inserts the
`identify` event *before* the events it stitches, which is the deterministic, common case; the
authoritative late-identify path (where anonymous events precede the identify) is demonstrated
through `analytics.events_resolved` from Milestone 1 and is what EP-6 uses when exactness across
a late login matters.

### Milestone 3 — Page views by route

Scope: verify `analytics.page_views_by_route` (an `AggregatingMergeTree` keyed on
`(day, route)`) and its materialized view `analytics.mv_page_views_by_route`, both **created in
Milestone 2's `0003_rollups.sql`**. The MV selects only `page_view` events, derives
`route = path(coalesce(url, ''))`, and stores `uniqExactState(toString(event_id))` so that a
route's view count is the number of *distinct* page-view events on that route. The acceptance
test asserts each fixture route shows the expected count and that a duplicated page-view event
does not inflate its route. This milestone reuses the fixtures from Milestone 2 and adds no new
DDL — it is verification only.


## Concrete Steps

Run every command from the repository root
`/Users/shinzui/Keikaku/bokuno/kansoku-project/kansoku` unless stated otherwise. The commands
assume `clickhouse-client` connects to the dev server with no extra flags (the dev environment
configures host/port); if your environment needs them, add `--host 127.0.0.1 --port 9000`.

### Milestone 0 — prerequisites

Confirm connectivity and create the working directories:

```bash
cd /Users/shinzui/Keikaku/bokuno/kansoku-project/kansoku
clickhouse-client -q "SELECT 1"
mkdir -p db/clickhouse/migrations db/clickhouse/fixtures
```

Expected output:

```text
1
```

If `analytics.events_raw` does not yet exist (EP-3 not implemented), create a compatible
stand-in. This is a **TEMPORARY stand-in used only when EP-3 has not yet been applied.** EP-3
owns the authoritative `db/clickhouse/migrations/0001_events_raw.sql`, and EP-5 must not diverge
from it: once EP-3's migration is present it supersedes this file, and this file must live at the
same canonical path so EP-3's version replaces it. The content below is a byte-for-byte copy of
EP-3's authoritative `CREATE TABLE` (all 24 columns, the `Nullable`/`LowCardinality` types, and
the `ReplacingMergeTree(received_at)` engine with `received_at` as the version column), so there
is nothing to reconcile later. Write it to `db/clickhouse/migrations/0001_events_raw.sql`
**only if that file is absent** (do not overwrite EP-3's real migration):

```sql
CREATE DATABASE IF NOT EXISTS analytics;

CREATE TABLE IF NOT EXISTS analytics.events_raw
(
    event_id               String,
    event_name             LowCardinality(String),
    source                 LowCardinality(String),
    source_service         Nullable(String),
    occurred_at            DateTime64(3, 'UTC'),
    received_at            DateTime64(3, 'UTC'),
    anonymous_id           Nullable(String),
    user_id                String,
    organization_id        Nullable(String),
    account_id             String,
    session_id             Nullable(String),
    url                    Nullable(String),
    referrer               Nullable(String),
    utm_source             Nullable(String),
    utm_medium             Nullable(String),
    utm_campaign           Nullable(String),
    utm_content            Nullable(String),
    utm_term               Nullable(String),
    correlation_id         Nullable(String),
    causation_id           Nullable(String),
    source_event_id        Nullable(String),
    source_global_position Nullable(UInt64),
    properties             String,
    context                String
)
ENGINE = ReplacingMergeTree(received_at)
PARTITION BY toYYYYMM(occurred_at)
ORDER BY (account_id, user_id, event_name, occurred_at, event_id);
```

Apply whatever migrations exist so far:

```bash
for f in db/clickhouse/migrations/*.sql; do
  echo "applying $f"
  clickhouse-client --multiquery < "$f"
done
clickhouse-client -q "EXISTS TABLE analytics.events_raw"
```

Expected final line:

```text
1
```

Note on the stand-in's engine and `ORDER BY` (copied from EP-3): the sort key appends
`event_id` so that `ReplacingMergeTree` deduplicates on the full natural key including the
event id, matching the MasterPlan's "dedup on event_id" intent, and `received_at` is the
explicit version argument (`ReplacingMergeTree(received_at)`) so the *latest-received* copy of
a redelivered event wins the collapse. EP-3's real migration owns the definitive schema; this
plan does not depend on the exact `ORDER BY`, only on the column names and types.

### Milestone 1 — identity map, resolution view, worked example

Create `db/clickhouse/migrations/0002_identity.sql` with the following content:

```sql
CREATE DATABASE IF NOT EXISTS analytics;

-- Latest anonymous_id -> user_id mapping, one row per anonymous_id after merges.
-- `version` is the event's received_at; the newest mapping wins.
CREATE TABLE IF NOT EXISTS analytics.identity_map
(
    anonymous_id  String,
    user_id       String,
    version       DateTime64(3, 'UTC')
)
ENGINE = ReplacingMergeTree(version)
ORDER BY anonymous_id;

-- Fill identity_map from identify/alias events as they arrive in events_raw.
-- Fires on each inserted block; ignores identity events missing either id.
CREATE MATERIALIZED VIEW IF NOT EXISTS analytics.mv_identity_map
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

-- Query-time resolution: every raw event with its canonical user id.
-- Reads events_raw FINAL so duplicate raw rows collapse before row-level use.
-- The subquery collapses identity_map to the latest user_id per anonymous_id.
-- NOTE: nullIf(m.user_id, '') is load-bearing. With ClickHouse's default
-- join_use_nulls = 0, a LEFT JOIN miss fills m.user_id with '' (NOT NULL);
-- without the nullIf, coalesce would stop there and never reach the
-- anonymous-id fallback. The trailing '' keeps the type plain String.
CREATE VIEW IF NOT EXISTS analytics.events_resolved
AS
SELECT
    e.event_id                                   AS event_id,
    e.event_name                                 AS event_name,
    e.occurred_at                                AS occurred_at,
    e.url                                         AS url,
    coalesce(nullIf(e.user_id, ''), nullIf(m.user_id, ''), nullIf(e.anonymous_id, ''), '') AS canonical_user
FROM analytics.events_raw AS e FINAL
LEFT JOIN
(
    SELECT anonymous_id, argMax(user_id, version) AS user_id
    FROM analytics.identity_map
    GROUP BY anonymous_id
) AS m
ON e.anonymous_id = m.anonymous_id;
```

A trap worth understanding before you run anything, because it once lurked in this very plan:
ClickHouse ships with the setting `join_use_nulls = 0` by default, which means a `LEFT JOIN`
that finds **no match** does not produce SQL `NULL` on the right side — it produces the column
type's *default value*, which for `String` is the empty string `''`. `''` is not `NULL`, so a
plain `coalesce(nullIf(e.user_id,''), m.user_id, nullIf(e.anonymous_id,''))` stops at
`m.user_id = ''` for every event whose `anonymous_id` has no `identity_map` row, and the
anonymous-id fallback never fires: every never-identified visitor resolves to `''`. The fix is
to wrap the join-side column too — `nullIf(m.user_id, '')` — so a join miss becomes `NULL` and
`coalesce` falls through to the anonymous id, and to end the chain with a literal `''` so the
expression's type stays a plain non-Nullable `String` (`''` = "unattributable"), which is what
the rollup tables' `AggregateFunction(uniqExact, String)` columns and the `!= ''` filters
expect. The alternative fix, `SETTINGS join_use_nulls = 1` on each view, was rejected so the
DDL behaves identically regardless of server or session settings (see the Decision Log).

Apply it:

```bash
clickhouse-client --multiquery < db/clickhouse/migrations/0002_identity.sql
```

Now run the worked example. Insert two anonymous page views, then the identify event, then a
post-login event, and finally a page view from `anon-3`, a visitor who **never** identifies —
this last row is the regression guard for the join_use_nulls trap explained above. These
INSERTs name only the columns we set; every other column takes its type default, which is
exactly what EP-3's `insertEvents` would produce for an event lacking those fields:

```bash
clickhouse-client --multiquery <<'SQL'
INSERT INTO analytics.events_raw
    (event_id, event_name, source, occurred_at, received_at, anonymous_id, user_id, url)
VALUES
    ('e1', 'page_view', 'web', '2026-06-01 09:00:00.000', '2026-06-01 09:00:00.100', 'anon-1', '', 'https://app.example.com/pricing'),
    ('e2', 'page_view', 'web', '2026-06-01 09:01:00.000', '2026-06-01 09:01:00.100', 'anon-1', '', 'https://app.example.com/signup');

INSERT INTO analytics.events_raw
    (event_id, event_name, source, occurred_at, received_at, anonymous_id, user_id, url)
VALUES
    ('e3', 'identify', 'app', '2026-06-01 09:05:00.000', '2026-06-01 09:05:00.100', 'anon-1', 'user-1', '');

INSERT INTO analytics.events_raw
    (event_id, event_name, source, occurred_at, received_at, anonymous_id, user_id, url)
VALUES
    ('e4', 'feature_used', 'app', '2026-06-01 09:10:00.000', '2026-06-01 09:10:00.100', 'anon-1', 'user-1', '');

INSERT INTO analytics.events_raw
    (event_id, event_name, source, occurred_at, received_at, anonymous_id, user_id, url)
VALUES
    ('e5', 'page_view', 'web', '2026-06-01 09:15:00.000', '2026-06-01 09:15:00.100', 'anon-3', '', 'https://app.example.com/docs');
SQL
```

Confirm the map learned the mapping (note: `anon-3` must NOT appear — no identify event ever
mentioned it):

```bash
clickhouse-client -q "SELECT anonymous_id, argMax(user_id, version) AS user_id FROM analytics.identity_map GROUP BY anonymous_id"
```

Expected:

```text
anon-1	user-1
```

Now the payoff — count distinct people among these five events on 2026-06-01. Without
stitching, the ids present are `anon-1` (on e1, e2), `user-1` (on e3, e4), and `anon-3`
(on e5), which naively looks like three actors. With stitching, `anon-1` and `user-1` unify
into one person while `anon-3` correctly remains a distinct actor:

```bash
clickhouse-client -q "SELECT uniqExact(canonical_user) AS people FROM analytics.events_resolved WHERE toDate(occurred_at) = '2026-06-01'"
```

Expected:

```text
2
```

Check the never-identified event resolved to its own anonymous id — this is the direct probe
for the join_use_nulls trap (the buggy coalesce returns `''` here, which the count above alone
cannot distinguish):

```bash
clickhouse-client -q "SELECT canonical_user FROM analytics.events_resolved WHERE event_id = 'e5'"
```

Expected (must be the literal anonymous id, not an empty line):

```text
anon-3
```

To make the contrast explicit, the unresolved count (what you would get without the map) is:

```bash
clickhouse-client -q "SELECT uniqExact(if(user_id != '', user_id, anonymous_id)) AS people_unstitched FROM analytics.events_raw FINAL WHERE toDate(occurred_at) = '2026-06-01'"
```

Expected (three, because `anon-1` and `user-1` are not yet unified without the map):

```text
3
```

Seeing `2` from `events_resolved` (with `e5` resolving to `anon-3`) and `3` from the
unstitched query demonstrates identity stitching working. This holds even though the anonymous
events (e1, e2) were inserted *before* the identify event (e3): `events_resolved` resolves
against the final map, so it is correct regardless of arrival order. Record any surprising
output in Surprises & Discoveries.

### Milestone 2 — daily event counts and DAU/WAU rollups

Create `db/clickhouse/migrations/0003_rollups.sql`:

```sql
CREATE DATABASE IF NOT EXISTS analytics;

-- ---------- Daily event counts, by event_name ----------
CREATE TABLE IF NOT EXISTS analytics.daily_event_counts
(
    day         Date,
    event_name  String,
    events      AggregateFunction(uniqExact, String)
)
ENGINE = AggregatingMergeTree
ORDER BY (day, event_name);

CREATE MATERIALIZED VIEW IF NOT EXISTS analytics.mv_daily_event_counts
TO analytics.daily_event_counts
AS
SELECT
    toDate(occurred_at)             AS day,
    event_name                      AS event_name,
    uniqExactState(toString(event_id)) AS events
FROM analytics.events_raw
GROUP BY day, event_name;

-- ---------- Daily active users (canonical, resolved at insert time) ----------
-- NOTE: nullIf(m.user_id, '') is load-bearing (join_use_nulls = 0 fills a LEFT
-- JOIN miss with '', not NULL); the trailing '' keeps the argument a plain
-- String so the state stays AggregateFunction(uniqExact, String).
CREATE TABLE IF NOT EXISTS analytics.dau
(
    day    Date,
    users  AggregateFunction(uniqExact, String)
)
ENGINE = AggregatingMergeTree
ORDER BY day;

CREATE MATERIALIZED VIEW IF NOT EXISTS analytics.mv_dau
TO analytics.dau
AS
SELECT
    toDate(e.occurred_at) AS day,
    uniqExactState(coalesce(nullIf(e.user_id, ''), nullIf(m.user_id, ''), nullIf(e.anonymous_id, ''), '')) AS users
FROM analytics.events_raw AS e
LEFT JOIN
(
    SELECT anonymous_id, argMax(user_id, version) AS user_id
    FROM analytics.identity_map
    GROUP BY anonymous_id
) AS m
ON e.anonymous_id = m.anonymous_id
WHERE coalesce(nullIf(e.user_id, ''), nullIf(m.user_id, ''), nullIf(e.anonymous_id, ''), '') != ''
GROUP BY day;

-- ---------- Weekly active users (canonical), keyed on the Monday of the week ----------
CREATE TABLE IF NOT EXISTS analytics.wau
(
    week   Date,
    users  AggregateFunction(uniqExact, String)
)
ENGINE = AggregatingMergeTree
ORDER BY week;

CREATE MATERIALIZED VIEW IF NOT EXISTS analytics.mv_wau
TO analytics.wau
AS
SELECT
    toMonday(e.occurred_at) AS week,
    uniqExactState(coalesce(nullIf(e.user_id, ''), nullIf(m.user_id, ''), nullIf(e.anonymous_id, ''), '')) AS users
FROM analytics.events_raw AS e
LEFT JOIN
(
    SELECT anonymous_id, argMax(user_id, version) AS user_id
    FROM analytics.identity_map
    GROUP BY anonymous_id
) AS m
ON e.anonymous_id = m.anonymous_id
WHERE coalesce(nullIf(e.user_id, ''), nullIf(m.user_id, ''), nullIf(e.anonymous_id, ''), '') != ''
GROUP BY week;

-- ---------- Page views by route ----------
-- url is Nullable(String) in EP-3's schema; coalesce(url, '') keeps path()
-- non-Nullable so the insert into the String route column cannot fail.
CREATE TABLE IF NOT EXISTS analytics.page_views_by_route
(
    day    Date,
    route  String,
    views  AggregateFunction(uniqExact, String)
)
ENGINE = AggregatingMergeTree
ORDER BY (day, route);

CREATE MATERIALIZED VIEW IF NOT EXISTS analytics.mv_page_views_by_route
TO analytics.page_views_by_route
AS
SELECT
    toDate(occurred_at)                AS day,
    path(coalesce(url, ''))            AS route,
    uniqExactState(toString(event_id)) AS views
FROM analytics.events_raw
WHERE event_name = 'page_view'
GROUP BY day, route;
```

Apply it:

```bash
clickhouse-client --multiquery < db/clickhouse/migrations/0003_rollups.sql
```

Important: a materialized view only aggregates rows inserted **after** it exists. The events
e1–e4 from Milestone 1 were inserted before these rollup MVs were created, so they are not in
the rollups. That is expected and correct. Load a dedicated, self-contained fixture batch now
so the rollup numbers are deterministic. Write it to
`db/clickhouse/fixtures/ep5_fixtures.sql`:

```sql
-- EP-5 rollup fixtures. All events on 2026-06-08 (a Monday), so day = week = 2026-06-08.
-- The identify event is inserted FIRST so the DAU/WAU MVs resolve anon-2 -> user-10
-- at insert time (deterministic, common ordering).
-- f7 is a NEVER-identified visitor (anon-3, no identify anywhere): it must count
-- as one DAU/WAU actor under its own anonymous id. If it vanishes from DAU, the
-- join_use_nulls trap has regressed (see Milestone 1 and the Decision Log).
INSERT INTO analytics.events_raw
    (event_id, event_name, source, occurred_at, received_at, anonymous_id, user_id, url)
VALUES
    ('f-id', 'identify', 'app', '2026-06-08 08:00:00.000', '2026-06-08 08:00:00.100', 'anon-2', 'user-10', '');

INSERT INTO analytics.events_raw
    (event_id, event_name, source, occurred_at, received_at, anonymous_id, user_id, url)
VALUES
    ('f1', 'page_view',    'web', '2026-06-08 09:00:00.000', '2026-06-08 09:00:00.100', 'anon-2', '',        'https://app.example.com/pricing'),
    ('f2', 'page_view',    'web', '2026-06-08 09:01:00.000', '2026-06-08 09:01:00.100', 'anon-2', '',        'https://app.example.com/signup?ref=x'),
    ('f3', 'page_view',    'app', '2026-06-08 09:05:00.000', '2026-06-08 09:05:00.100', 'anon-2', 'user-10', 'https://app.example.com/dashboard'),
    ('f4', 'feature_used', 'app', '2026-06-08 09:06:00.000', '2026-06-08 09:06:00.100', 'anon-2', 'user-10', ''),
    ('f5', 'page_view',    'web', '2026-06-08 10:00:00.000', '2026-06-08 10:00:00.100', 'anon-9', 'user-20', 'https://app.example.com/pricing'),
    ('f6', 'feature_used', 'app', '2026-06-08 10:05:00.000', '2026-06-08 10:05:00.100', '',       'user-20', ''),
    ('f7', 'page_view',    'web', '2026-06-08 11:00:00.000', '2026-06-08 11:00:00.100', 'anon-3', '',        'https://app.example.com/docs');
```

Apply the fixtures:

```bash
clickhouse-client --multiquery < db/clickhouse/fixtures/ep5_fixtures.sql
```

Reasoning about the expected numbers for 2026-06-08. There are seven non-identify events plus
one identify event. Distinct event ids per name: `page_view` = {f1, f2, f3, f5, f7} = 5;
`feature_used` = {f4, f6} = 2; `identify` = {f-id} = 1. Canonical users: anon-2 resolves to
user-10 (via the identify inserted first), so f1–f4 and f-id all map to user-10; f5, f6 carry
user-20; f7's anon-3 has no mapping and no `user_id`, so it resolves to `anon-3` itself via
the anonymous-id fallback. Distinct canonical users = {user-10, user-20, anon-3} = 3. Page
routes among page_view events: `/pricing` from f1 and f5 = 2 distinct events; `/signup` from
f2 = 1 (query string stripped by `path`); `/dashboard` from f3 = 1; `/docs` from f7 = 1.

Read the daily event counts:

```bash
clickhouse-client -q "SELECT day, event_name, uniqExactMerge(events) AS events FROM analytics.daily_event_counts WHERE day = '2026-06-08' GROUP BY day, event_name ORDER BY event_name"
```

Expected:

```text
2026-06-08	feature_used	2
2026-06-08	identify	1
2026-06-08	page_view	5
```

Read DAU:

```bash
clickhouse-client -q "SELECT day, uniqExactMerge(users) AS dau FROM analytics.dau WHERE day = '2026-06-08' GROUP BY day"
```

Expected (3, not 2 — if you see `2`, the never-identified visitor anon-3 was dropped and the
join_use_nulls trap is back; re-check the `nullIf(m.user_id, '')` wrappers in `mv_dau`):

```text
2026-06-08	3
```

Read WAU (the week's Monday is 2026-06-08):

```bash
clickhouse-client -q "SELECT week, uniqExactMerge(users) AS wau FROM analytics.wau WHERE week = '2026-06-08' GROUP BY week"
```

Expected:

```text
2026-06-08	3
```

Cross-check the insert-time rollup against the authoritative query-time path — both must see
the same three actors for this fixture (the identify preceded the events it stitches, so
insert-time and query-time resolution agree):

```bash
clickhouse-client -q "SELECT uniqExact(canonical_user) AS people FROM analytics.events_resolved WHERE toDate(occurred_at) = '2026-06-08'"
```

Expected:

```text
3
```

Now the redelivery test. Re-apply the exact same fixture file. Because ingestion is
at-least-once, this simulates a redelivered batch: the same `event_id`s arrive again, the MVs
fire again, and duplicate-tolerant `uniqExact` counting must leave every number unchanged:

```bash
clickhouse-client --multiquery < db/clickhouse/fixtures/ep5_fixtures.sql
clickhouse-client -q "SELECT event_name, uniqExactMerge(events) AS events FROM analytics.daily_event_counts WHERE day = '2026-06-08' GROUP BY event_name ORDER BY event_name"
clickhouse-client -q "SELECT uniqExactMerge(users) AS dau FROM analytics.dau WHERE day = '2026-06-08' GROUP BY day"
```

Expected (identical to before — no double counting):

```text
feature_used	2
identify	1
page_view	5
3
```

If instead you see `page_view	10` or `dau 6`, the rollup is double-counting and the
aggregation is not using `uniqExact` over `event_id`/`canonical_user`; fix the MV definitions
in `0003_rollups.sql` before proceeding, and record the finding in Surprises & Discoveries.
If DAU reads `2` (before or after redelivery), the never-identified visitor is being dropped —
that is the join_use_nulls trap, not a duplication bug.

### Milestone 3 — page views by route

The page-views MV was created in Milestone 2's `0003_rollups.sql` and has been receiving the
fixtures; this milestone only verifies it. Read it back:

```bash
clickhouse-client -q "SELECT day, route, uniqExactMerge(views) AS views FROM analytics.page_views_by_route WHERE day = '2026-06-08' GROUP BY day, route ORDER BY route"
```

Expected (note `/pricing` = 2 despite the redelivery, `/signup` has no query string, and
`/docs` = 1 from the never-identified visitor's page view):

```text
2026-06-08	/dashboard	1
2026-06-08	/docs	1
2026-06-08	/pricing	2
2026-06-08	/signup	1
```

### Wiring into the migration mechanism

EP-3 establishes a file-based migration mechanism applied by a `just` recipe. Add (or confirm)
a recipe that applies every file in `db/clickhouse/migrations/` in lexical order. If a
`justfile` exists at the repo root, ensure it contains a recipe equivalent to:

```text
# Apply all ClickHouse migrations in lexical order (idempotent; safe to re-run).
ch-migrate:
    for f in db/clickhouse/migrations/*.sql; do echo "applying $f"; clickhouse-client --multiquery < "$f"; done

# Load EP-5 verification fixtures.
ch-fixtures-ep5:
    clickhouse-client --multiquery < db/clickhouse/fixtures/ep5_fixtures.sql
```

If no `justfile` exists yet (EP-3 not landed), the bash loop shown in Milestone 0 is the
self-contained fallback and must be documented in EP-3's recipe when it arrives. Either way,
`0002_identity.sql` and `0003_rollups.sql` must be picked up automatically by the same
mechanism that applies `0001_events_raw.sql`.

### Commit

Before committing, confirm the files are actually committable. The repo `.gitignore` used to
ignore `db/` wholesale (the Postgres state directory); EP-3 owns narrowing it to `db/*` plus
`!db/clickhouse/`. Verify the narrowing has landed — `git check-ignore` must report *nothing*
for this plan's files:

```bash
git check-ignore db/clickhouse/migrations/0002_identity.sql db/clickhouse/migrations/0003_rollups.sql db/clickhouse/fixtures/ep5_fixtures.sql; echo "exit: $?"
```

Expected (exit code 1 means none of the paths are ignored — that is success here):

```text
exit: 1
```

If any path is printed, stop and apply EP-3's `.gitignore` change (`db/` → `db/*` +
`!db/clickhouse/`) first; do not force-add ignored files.

Commit the new SQL files and any `justfile` change with a Conventional Commits message and the
required trailers:

```bash
git add db/clickhouse/migrations/0002_identity.sql db/clickhouse/migrations/0003_rollups.sql db/clickhouse/fixtures/ep5_fixtures.sql
git commit -m "feat(clickhouse): add identity map and materialized-view rollups

Add analytics.identity_map + mv_identity_map, the analytics.events_resolved
query-time resolution view, and AggregatingMergeTree rollups
(daily_event_counts, dau, wau, page_views_by_route) with duplicate-tolerant
uniqExact aggregation.

MasterPlan: docs/masterplans/1-kansoku-analytics-service-mvp.md
ExecPlan: docs/plans/5-identity-stitching-and-materialized-view-rollups.md
Intention: intention_01kwf425fxenc904ear54cr2n7"
```


## Validation and Acceptance

The plan is accepted when a novice, starting from a clean checkout with the dev environment
running, can reproduce every expected transcript above. Concretely:

Identity stitching is proven when, after applying `0002_identity.sql` and inserting the
Milestone 1 events, `SELECT uniqExact(canonical_user) FROM analytics.events_resolved WHERE
toDate(occurred_at) = '2026-06-01'` returns `2`, the never-identified event `e5` shows
`canonical_user = 'anon-3'` (not `''`), and the unstitched query returns `3`. This shows one
human tracked across anonymous and logged-in states is counted once, that a visitor who never
logs in still counts as one real actor under their own anonymous id, and that the result holds
even though anonymous events arrived before the identify event.

Rollup correctness is proven when, after applying `0003_rollups.sql` and loading
`ep5_fixtures.sql`, the daily-event-counts read-back shows `page_view 5`, `feature_used 2`,
`identify 1`; DAU shows `3`; WAU shows `3`; the `events_resolved` cross-check for 2026-06-08
shows `3`; and page-views-by-route shows `/pricing 2`, `/signup 1`, `/dashboard 1`, `/docs 1`.
The DAU/WAU value `3` (not `2`) is the standing regression guard for the join_use_nulls trap:
it can only be reached when the never-identified visitor `anon-3` survives resolution.

Redelivery safety is proven when re-applying `ep5_fixtures.sql` (which re-inserts identical
`event_id`s) leaves every one of those numbers unchanged. This is the acceptance for the
at-least-once duplicate hazard the MasterPlan flagged: `uniqExact` over `event_id` and over
`canonical_user` makes the rollups idempotent.

Acceptance is behavioral, not structural: it is the exact query outputs above, not merely the
existence of the tables. Every number is small and hand-checkable from the fixture, so a
reviewer can confirm correctness without trusting the implementation.


## Idempotence and Recovery

Every DDL statement uses `IF NOT EXISTS`, so applying `0002_identity.sql` and `0003_rollups.sql`
repeatedly is safe and creates nothing twice. The migration loop and the `just ch-migrate`
recipe can be run any number of times.

The rollups are idempotent with respect to duplicate *events* by construction (`uniqExact`),
which is the whole point of Milestone 2's redelivery test. Re-loading the fixtures does not
corrupt any number.

If you need to reset the derived state during development without touching raw data, drop only
the derived objects and re-apply the migrations; `events_raw` is untouched:

```bash
clickhouse-client --multiquery <<'SQL'
DROP VIEW IF EXISTS analytics.mv_identity_map;
DROP VIEW IF EXISTS analytics.mv_daily_event_counts;
DROP VIEW IF EXISTS analytics.mv_dau;
DROP VIEW IF EXISTS analytics.mv_wau;
DROP VIEW IF EXISTS analytics.mv_page_views_by_route;
DROP VIEW IF EXISTS analytics.events_resolved;
DROP TABLE IF EXISTS analytics.identity_map;
DROP TABLE IF EXISTS analytics.daily_event_counts;
DROP TABLE IF EXISTS analytics.dau;
DROP TABLE IF EXISTS analytics.wau;
DROP TABLE IF EXISTS analytics.page_views_by_route;
SQL
clickhouse-client --multiquery < db/clickhouse/migrations/0002_identity.sql
clickhouse-client --multiquery < db/clickhouse/migrations/0003_rollups.sql
```

Note that dropping and recreating a materialized view does **not** backfill it from historical
`events_raw` rows — MVs only see inserts that happen after they exist. To rebuild a rollup from
existing raw data (for example after a definition change), populate the target table once with a
one-off `INSERT INTO analytics.<target> SELECT ... FROM analytics.events_raw FINAL GROUP BY ...`
using the same `SELECT` body as the MV (with `FINAL` to avoid duplicates in the backfill), then
let the MV maintain it going forward. Keep such backfill statements out of the migration files
so they are not re-run on every apply.

Recovery from a half-applied state is trivial: because each file is independent and idempotent,
simply re-run `just ch-migrate` (or the bash loop). If a single statement failed (for example a
typo), fix the file and re-apply; already-created objects are skipped by `IF NOT EXISTS`.


## Interfaces and Dependencies

**Hard dependency: EP-3.** This plan reads `analytics.events_raw` and relies on its column
names (`event_id`, `event_name`, `occurred_at`, `received_at`, `anonymous_id`, `user_id`, `url`,
etc.) exactly as fixed in the MasterPlan's "ClickHouse `analytics.events_raw` schema and
`EventRow`" integration point. This plan does not modify that table. If EP-3 changes a column
name, the affected MV `SELECT`s here must be updated in lockstep. EP-3 also owns a repository
precondition this plan needs: narrowing the repo `.gitignore` from `db/` (the wholesale ignore
protecting the Postgres state directory) to `db/*` plus `!db/clickhouse/`, so that
`db/clickhouse/migrations/*.sql` and `db/clickhouse/fixtures/*.sql` are committable. Verify
with `git check-ignore` (see the Commit step) before committing `0002_identity.sql` and
`0003_rollups.sql`; if the paths are still ignored, EP-3's `.gitignore` change has not landed.

**Convention dependency: EP-2.** The `identify`/`alias` event-name convention and, critically,
the `alias` shape come from EP-2's smart constructors: `aliasEvent` puts both the
`anonymousId` and the `userId` on the event row itself, which is what `mv_identity_map`'s
filter and column selection assume (see "Identity events" in Context and Orientation). A
change to EP-2's `aliasEvent` definition requires a lockstep change to `mv_identity_map`.

**Soft dependency: EP-4.** Live rollups are best observed with events flowing through ingestion,
but this plan is fully validated with fixture rows inserted via `clickhouse-client` (equivalent
to EP-3's `insertEvents`), so EP-4 is not required to complete or verify EP-5.

**Consumed by EP-6.** The next plan
(`docs/plans/6-semantic-metrics-layer-and-typed-query-api.md`) imports the object names and read
patterns defined here. They are, precisely (all in database `analytics`):

- `analytics.identity_map` — `ReplacingMergeTree(version)`, columns `(anonymous_id String,
  user_id String, version DateTime64(3,'UTC'))`, one latest row per `anonymous_id`. Read the
  current mapping with `SELECT anonymous_id, argMax(user_id, version) AS user_id FROM
  analytics.identity_map GROUP BY anonymous_id`.
- `analytics.events_resolved` — a `VIEW` exposing `(event_id, event_name, occurred_at, url,
  canonical_user)` per event, where `canonical_user = coalesce(nullIf(user_id,''),
  nullIf(identity_map.user_id,''), nullIf(anonymous_id,''), '')` — a plain non-Nullable
  `String`, `''` meaning "unattributable" — read over `events_raw FINAL`. EP-6 uses this
  for exact, late-identify-correct user counts, e.g. `SELECT toDate(occurred_at) AS day,
  uniqExact(canonical_user) AS active FROM analytics.events_resolved WHERE canonical_user != ''
  GROUP BY day`.
- `analytics.daily_event_counts` — `AggregatingMergeTree` keyed `(day Date, event_name String)`,
  column `events AggregateFunction(uniqExact, String)`. Read with `SELECT day, event_name,
  uniqExactMerge(events) FROM analytics.daily_event_counts GROUP BY day, event_name`.
- `analytics.dau` — `AggregatingMergeTree` keyed `(day Date)`, column `users
  AggregateFunction(uniqExact, String)`. Read with `SELECT day, uniqExactMerge(users) FROM
  analytics.dau GROUP BY day`.
- `analytics.wau` — `AggregatingMergeTree` keyed `(week Date)` (the Monday of the week), column
  `users AggregateFunction(uniqExact, String)`. Read with `SELECT week, uniqExactMerge(users)
  FROM analytics.wau GROUP BY week`.
- `analytics.page_views_by_route` — `AggregatingMergeTree` keyed `(day Date, route String)`,
  column `views AggregateFunction(uniqExact, String)`. Read with `SELECT day, route,
  uniqExactMerge(views) FROM analytics.page_views_by_route GROUP BY day, route`.
- The materialized views that maintain the above: `analytics.mv_identity_map`,
  `analytics.mv_daily_event_counts`, `analytics.mv_dau`, `analytics.mv_wau`,
  `analytics.mv_page_views_by_route`. EP-6 does not query the MVs directly; it queries their
  target tables and `events_resolved`.

Precision boundary EP-6 must know when choosing between these objects: the identity resolution
baked into `analytics.dau` and `analytics.wau` is **frozen at insert time** — an `identify`
event that arrives *after* the events it would stitch does not retroactively re-key the rollup
rows already written (MVs never re-fire over old rows); only `analytics.events_resolved`
re-resolves every event against the *current* map at query time and is therefore correct
across late identifies. Use `dau`/`wau` for fast dashboard numbers and `events_resolved` when
exactness across a late login matters (full rationale in the Decision Log entry on insert-time
resolution, dated 2026-07-01).

The critical read convention EP-6 must honor: every `AggregatingMergeTree` rollup is read with
the matching `-Merge` combinator under a `GROUP BY` on the key columns. Reading the raw
`AggregateFunction` column without `uniqExactMerge` returns an opaque binary state, not a number.

When is `FINAL` actually needed on `events_raw` reads? `uniqExact` over `event_id` or
`canonical_user` is already duplicate-tolerant: a redelivered duplicate row contributes the
same value, which hashes identically into the distinct set, so exact-unique queries return the
same answer with or without `FINAL` and can usually **drop it** (skipping `FINAL` avoids the
read-time merge of un-collapsed `ReplacingMergeTree` parts, which is significantly cheaper on
large scans). `FINAL` is needed only when row *multiplicity* matters — raw `count()`s, `sum()`s
over per-row values, or row-level listings like `events_resolved` (which keeps `FINAL` because
consumers see individual rows, not distinct-aggregates).

Post-MVP scaling note (recorded here so EP-6 and future work know the path): the per-query
`argMax(user_id, version) ... GROUP BY anonymous_id` subquery builds an in-memory hash table of
the whole `identity_map` on every resolved query and every DAU/WAU insert block. That is fine
while the map is small, but when it grows, replace the join with a ClickHouse *dictionary* — an
in-memory key-value structure the server keeps loaded and refreshes on an interval — defined
over `identity_map`, and resolve with `dictGet('analytics.identity_dict', 'user_id',
anonymous_id)` instead of the `LEFT JOIN`. Dictionaries give O(1) per-row lookups without
rebuilding the hash table per query. This is deliberately out of MVP scope.

**File paths this plan creates.** `db/clickhouse/migrations/0002_identity.sql`,
`db/clickhouse/migrations/0003_rollups.sql`, and `db/clickhouse/fixtures/ep5_fixtures.sql`, all
under the repository root `/Users/shinzui/Keikaku/bokuno/kansoku-project/kansoku`. If a
`justfile` exists, the `ch-migrate` and `ch-fixtures-ep5` recipes are added or confirmed there.

**Libraries and services.** ClickHouse (dev server on TCP 9000 / HTTP 8123) and the
`clickhouse-client` CLI are the only tools this plan requires. No Haskell code is added by this
plan; EP-6 will wrap the read patterns above in ClickHaskell (`KovalevDima/ClickHaskell`)
selects, following the Haskell house style noted in Context and Orientation
(`import Kansoku.Prelude`, postpositive qualified imports, strict-field records with explicit
deriving, generic-lens `#label` access, and any embedded query SQL as a `"""..."""`
MultilineString literal). The ClickHouse features relied upon are all standard:
`ReplacingMergeTree`, `AggregatingMergeTree`, `MATERIALIZED VIEW ... TO`, the
`uniqExactState`/`uniqExactMerge` combinators, `argMax`, `coalesce`/`nullIf`,
`toDate`/`toMonday`, and `path` for URL routes.


## Revision Note

- Revision (2026-07-01): Aligned this plan with the shared Haskell standards in
  `/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/core/` without altering any schema, view name,
  dedup/`uniqExact` strategy, migration layout (`db/clickhouse/migrations/000N_*.sql` +
  `just ch-migrate`), fixture, or expected transcript. Because this plan adds only ClickHouse
  `.sql` migration/fixture files and `clickhouse-client` transcripts — and no Haskell — the SQL
  fenced blocks were left as-is (they are standalone files, not Haskell-embedded SQL). The change
  is documentary: a "Coding standards" paragraph was added to Context and Orientation, and the
  "Libraries and services" note now points EP-6 at those conventions (prelude import, postpositive
  imports, strict-field records with explicit deriving, generic-lens `#label` access, and
  MultilineStrings for any SQL embedded in Haskell) so that the ClickHaskell code EP-6 builds on
  these object names is written in the project's house style. Reason: keep the plan family's
  standards guidance consistent even where the plan itself emits no Haskell, so the reconciled
  object contract flows into EP-6 as compliant Haskell.

- Revision (2026-07-01): Pre-implementation validation pass plus architecture review. The
  blocking finding was the **join_use_nulls defect** in the identity-resolution SQL: ClickHouse
  defaults to `join_use_nulls = 0`, so a `LEFT JOIN` miss fills `m.user_id` with `''` (not
  `NULL`), and the previous `coalesce(nullIf(e.user_id,''), m.user_id, nullIf(e.anonymous_id,''))`
  returned `''` for every never-identified anonymous event — the anonymous-id fallback could
  never fire, silently dropping never-identified visitors from DAU/WAU (filtered by `!= ''`)
  and collapsing them into one `''` bucket in `events_resolved`. All three definitions
  (`events_resolved`, `mv_dau`, `mv_wau`) now use
  `coalesce(nullIf(e.user_id, ''), nullIf(m.user_id, ''), nullIf(e.anonymous_id, ''), '') AS
  canonical_user`, whose trailing `''` keeps the type plain `String` so the
  `AggregateFunction(uniqExact, String)` columns and `!= ''` filters are unchanged; a Decision
  Log entry records the trap and why `SETTINGS join_use_nulls = 1` was rejected. Because the
  old fixtures masked the bug (every anonymous fixture was eventually identified), both fixture
  sets gained a never-identified visitor: Milestone 1 adds `e5` (`anon-3`, `page_view`,
  `/docs`), moving the stitched count to 2 and the unstitched count to 3, with a direct
  `canonical_user = 'anon-3'` probe; Milestone 2 adds `f7` (`anon-3`, `page_view`, `/docs`),
  moving `page_view` to 5, DAU/WAU to 3 (`{user-10, user-20, anon-3}`), adding route `/docs 1`,
  plus an `events_resolved` cross-check of 3 — so this bug class can never again pass the
  acceptance transcripts unnoticed. Other validation fixes: the Milestone 0 TEMPORARY
  `0001_events_raw.sql` stand-in was regenerated verbatim from EP-3's authoritative
  `CREATE TABLE` (all 24 columns, `Nullable`/`LowCardinality` types, and
  `ENGINE = ReplacingMergeTree(received_at)` — the old stand-in omitted the version argument
  and half the columns); the events_raw term definition now describes the real NULL-vs-`''`
  conventions and why `nullIf`/`!= ''` are robust to both; `mv_page_views_by_route` derives
  `path(coalesce(url, ''))` since `url` is `Nullable(String)`; the Milestone 2 narrative was
  reconciled with the Progress checklist (0003 creates all four target tables and four MVs in
  Milestone 2; Milestone 3 is verification-only for page views); `alias` semantics are pinned
  to EP-2's `aliasEvent` smart constructor with a lockstep-change warning; and the `.gitignore`
  precondition (EP-3 narrows `db/` to `db/*` + `!db/clickhouse/`) is recorded in Milestone 0,
  the Commit step (`git check-ignore` guard), and Interfaces and Dependencies. Architecture
  review additions: a "when `FINAL` is actually needed" rule (duplicate-tolerant `uniqExact`
  queries can drop `FINAL`; only row-multiplicity reads need it), a post-MVP note to replace
  the per-query `argMax` join with a ClickHouse dictionary (`dictGet`) when `identity_map`
  grows, and a Decision Log entry recording the `uniqExactState` (exact, per-bucket id sets)
  vs `uniqCombinedState` (approximate, fixed-size) state-size trade as a deliberate MVP
  choice. No milestone was renumbered; all object names and read patterns consumed by EP-6
  are unchanged except the corrected `canonical_user` expression.
