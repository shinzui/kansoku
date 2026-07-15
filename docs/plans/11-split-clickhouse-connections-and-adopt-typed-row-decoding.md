---
id: 11
slug: split-clickhouse-connections-and-adopt-typed-row-decoding
title: "Split ClickHouse connections and adopt typed row decoding"
kind: exec-plan
created_at: 2026-07-15T21:30:34Z
master_plan: "docs/masterplans/2-kansoku-production-hardening-review-fixes-and-portfolio-service-readiness.md"
---

# Split ClickHouse connections and adopt typed row decoding

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

**Hard dependency: EP-10 (`docs/plans/10-restore-the-build-and-supervise-the-writer.md`)
must be Complete before this plan starts.** The repository does not compile until EP-10
lands (the writer's batch handler still pattern-matches a shibuya message type that was
renamed upstream), so nothing in this plan can even be type-checked before then. EP-10 also
touches `kansoku-server/app/Main.hs` (writer supervision) and `kansoku-core/src/Kansoku/Config.hs`
(ClickHouse host/user/password variables). Where this plan quotes those files, it quotes the
pre-EP-10 state; apply the same edits to whatever shape EP-10 leaves behind and record any
adaptation in the Decision Log below.


## Purpose / Big Picture

Kansoku is an analytics service: HTTP handlers accept events, a background "writer" moves
them from a Postgres queue (pgmq) into ClickHouse in batches, and metrics HTTP endpoints
(`/metrics/events`, `/metrics/active_users`, `/metrics/retention`, ...) query ClickHouse and
return JSON time series. Two defects found by the 2026-07-15 architecture review live in the
ClickHouse client layer, and this plan removes both.

First, the whole process currently shares one ClickHouse TCP connection. The ClickHaskell
driver serializes every operation on a connection behind an `MVar`, held for the entire
duration of each query. So a slow dashboard query blocks the writer's batch `INSERT` (letting
queue messages reappear after their 60-second visibility timeout and get re-written — harmless
duplicates thanks to ReplacingMergeTree, but wasted work and pipeline lag), and two concurrent
dashboard queries execute one after the other. After this plan, the writer owns a dedicated
connection and the metrics handlers draw from a pool of `KANSOKU_CH_QUERY_POOL_SIZE`
connections (default 4). You can see it working: a test in which a 2-second query runs on the
query side while the writer inserts a batch completes the insert in well under a second, and
four concurrent 1-second metric queries finish in about 1 second of wall time, not 4.

Second, query results are currently decoded by having ClickHouse glue every row's columns
into one tab-separated string (`concat(col, '\t', col, ...) AS line`) and splitting on tab in
Haskell. If a group key contains a tab (an event name, a URL route), fields silently shift; if
a number fails to parse, `fromMaybe 0` substitutes a plausible zero. Wrong-but-plausible
numbers are the worst failure mode an analytics service can have. After this plan, every
select decodes real typed columns through ClickHaskell's column machinery (the same machinery
the insert path already uses), an event name containing a literal tab round-trips intact
through a grouped metric query, and any shape mismatch raises an exception that the handler
maps to HTTP 503 — never a silent zero.

Boundary with EP-13: the SQL-builder functions in `kansoku-core/src/Kansoku/Query.hs`
(`buildSQL`, `buildSessionsSQL`, `buildRetentionSQL`, `buildFunnelSQL`, and the private
helpers they call) keep their signatures — pure functions returning `Text`. EP-13
(`docs/plans/13-safe-and-correct-metric-sql-validated-inputs-ordered-funnels-honest-failures.md`)
rewrites *what* SQL those builders generate; this plan owns *how* the results come back and
get decoded. Later plans must not reintroduce string-splitting decode paths (MasterPlan
integration point "Kansoku.Query").


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").

- [ ] Confirm EP-10 is Complete: `cabal build all` and `cabal test` are green on `master`.
- [ ] M1: `runWriter` in `kansoku-core/src/Kansoku/Writer/Run.hs` takes `ClickHouseConfig` and opens its own dedicated `Connection`.
- [ ] M1: `kansoku-server/app/Main.hs` no longer shares one connection; the server side opens its own (still single) query connection.
- [ ] M1: integration test proving a 2-second query on the query connection does not delay a writer insert.
- [ ] M1: commit.
- [ ] M2: `resource-pool` added to `kansoku-core/kansoku-core.cabal` build-depends; `async` added to the test suite build-depends.
- [ ] M2: `QueryPool`, `newQueryPool`, `withQueryConnection` defined and exported from `Kansoku.ClickHouse`.
- [ ] M2: additive `clickHouseQueryPoolSize` Config field, env `KANSOKU_CH_QUERY_POOL_SIZE`, default 4, validated >= 1; `Kansoku.ConfigSpec` extended.
- [ ] M2: `QueryPool` threaded through `Kansoku.Server.kansokuApp` -> `Kansoku.Metrics.Handler.metricsApp`/`metricsServer` -> `Kansoku.Query` run functions; `Main.hs` builds the pool.
- [ ] M2: concurrency test proving N pooled queries progress in parallel (pool of 4 runs four 1-second queries in ~1s; pool of 1 runs them in ~4s).
- [ ] M2: commit.
- [ ] M3: `AggColumns`/`AggRow` decode three real columns in `Kansoku.Query`; `AggLine`, `parseAggLine`, and the concat wrapper are deleted.
- [ ] M3: `EventProjection` decodes five real columns in `Kansoku.ClickHouse`; `ProjectionLine`, `ProjectionLineColumns`, `parseProjectionLine` are deleted from `Kansoku.ClickHouse.EventRow` and `Kansoku.ClickHouse`.
- [ ] M3: `SETTINGS compile_expressions = 0, compile_sort_description = 0` re-investigated against the current local ClickHouse; finding recorded in Surprises & Discoveries; setting kept or dropped accordingly.
- [ ] M3: tab-in-group-key round-trip test; decode-mismatch-raises test; projection round-trip tests still green.
- [ ] M3: fixture-backed HTTP check (`just ch-fixtures-ep6`, curl a metrics endpoint) returns the same numbers as before the decode change.
- [ ] M3: commit.
- [ ] Living sections of this plan updated; MasterPlan registry row EP-11 set to Complete; MasterPlan Progress checkboxes for EP-11 ticked.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Hard-depend on EP-10 (`docs/plans/10-restore-the-build-and-supervise-the-writer.md`).
  Rationale: The repository does not compile until EP-10 lands, so no edit here can be
  validated before it. EP-10 also reshapes `Main.hs` (supervision) and `Config.hs`
  (ClickHouse credentials); this plan builds on that shape.
  Date: 2026-07-15

- Decision: Use the `resource-pool` package (`Data.Pool`) for the query-side pool, with a
  no-op destroy action, one stripe, an effectively infinite idle TTL, and a
  catch-inside/rethrow-outside wrapper (`withQueryConnection`) so the pool never destroys a
  connection.
  Rationale: ClickHaskell's public API has no way to close a `Connection`
  (`ClickHaskell.Connection` is an `Other-Module` in its cabal file, so `destroyBuff` is
  unreachable), and its `withConnection` already self-heals: on any exception it tears down
  the socket and reconnects before releasing its internal `MVar`. A connection is therefore
  always safe to return to the pool, and destroying one can only leak a socket. A hand-rolled
  round-robin vector of connections was considered and rejected: `resource-pool` gives
  lazy creation, checkout blocking, and exception safety for one small dependency, and the
  MasterPlan expects a named pool type either way.
  Date: 2026-07-15

- Decision: Split milestones so M1 only moves connection ownership (writer opens its own
  connection; the server keeps a single query connection) and M2 introduces the pool.
  Rationale: Each step is independently verifiable — M1 by a "slow query does not block
  insert" test, M2 by a parallelism test — and the handler plumbing is only rewritten once
  (Connection -> QueryPool in M2).
  Date: 2026-07-15

- Decision: Keep the SQL builders returning `Text` and wrap them in a thin typed outer
  select — `SELECT CAST(bucket, 'String') AS bucket, CAST(group_key, 'String') AS group_key,
  CAST(value, 'Float64') AS value FROM ( ... )` — instead of pushing typed column selection
  into every builder.
  Rationale: EP-13 owns the builders' SQL and rewrites it on the v2 schema; this plan owns
  decoding. The `CAST` wrapper pins the wire types the typed decoder declares no matter what
  the inner query produces (including `Nullable` results — `CAST(NULL, 'String')` fails loudly
  in ClickHouse rather than substituting a default), and it replaces the old
  `concat`/`ifNull` wrapper one-for-one, so builder signatures and their unit tests are
  untouched.
  Date: 2026-07-15

- Decision: In the projection select, `CAST(event_name, 'String')` and
  `CAST(source, 'String')` rather than declaring `LowCardinality ChString` columns.
  Rationale: Those table columns are `LowCardinality(String)`; ClickHaskell validates the
  server-reported type name against the declared column type and would raise `UnmatchedType`
  for a plain `ChString` declaration. Casting in SQL keeps the Haskell record five plain
  `ByteString` fields, matching what the old concatenated select did (it already used
  `CAST(event_name, 'String')`).
  Date: 2026-07-15

- Decision: Keep `SETTINGS compile_expressions = 0, compile_sort_description = 0` on the
  metric read path initially, and re-test its removal during M3.
  Rationale: It is a documented workaround, not an accident: EP-6's Decision Log
  (`docs/plans/6-semantic-metrics-layer-and-typed-query-api.md`, "Add ClickHouse read
  settings...") records that the local ClickHouse server crashed with `std::bad_alloc` inside
  LLVM/JIT expression and sort compilation while serving the funnel/retention queries, and
  disabling compilation stabilized them. Whether the current nix-pinned ClickHouse still
  crashes must be re-established empirically; record the outcome in Surprises & Discoveries
  and keep or drop with that evidence.
  Date: 2026-07-15

- Decision: Decode `ChString` columns to `ByteString` record fields and convert to `Text`
  with strict `Data.Text.Encoding.decodeUtf8` at the edge.
  Rationale: `ByteString` is the driver's native mapping for `ChString` (the insert-side
  `EventRow` already works this way). Strict decoding throws on invalid UTF-8, which matches
  this plan's loud-failure policy; the lenient variant would silently mangle group keys.
  Date: 2026-07-15


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

Kansoku lives in this repository as four cabal packages: `kansoku-api` (servant route types
and DTOs, plus the shared `Kansoku.Prelude`), `kansoku-core` (all runtime logic; everything
this plan touches except `Main.hs` is here), `kansoku-server` (the executable), and
`kansoku-client` (untouched here). Toolchain: GHC 9.12.4 inside `nix develop`; `just build`
runs `cabal build all`; `just test` runs `cabal test`; `just up` runs `process-compose up`,
which starts a local Postgres and a local ClickHouse (TCP port from `$CLICKHOUSE_TCP_PORT`,
default 9000, exported by the dev shell).

The data path: HTTP ingest handlers enqueue events into pgmq (a Postgres-backed message
queue). A background writer — wired in `kansoku-core/src/Kansoku/Writer/Run.hs` (`runWriter`)
and implemented as a shibuya batch processor whose handler is
`kansoku-core/src/Kansoku/Writer/Batch.hs` (`writerBatchHandler`) — reads queued messages and
performs one batched `INSERT` into the ClickHouse table `analytics.events_raw` per flush via
`Kansoku.ClickHouse.insertEvents`. The metrics side is a servant API: routing in
`kansoku-core/src/Kansoku/Server.hs` (`kansokuApp` dispatches `/metrics/*` to
`Kansoku.Metrics.Handler.metricsApp`), handlers in
`kansoku-core/src/Kansoku/Metrics/Handler.hs`, and SQL construction plus execution in
`kansoku-core/src/Kansoku/Query.hs`.

### How the ClickHaskell driver works (read this before editing)

The driver source is at
`/Users/shinzui/Keikaku/hub/haskell/clickhaskell-project/ClickHaskell/library/` (pinned in
`cabal.project` as a `source-repository-package`; the on-disk copy is the same code). The
facts below were verified against that source and everything this plan does depends on them.

A `Connection` is one TCP socket wrapped in an `MVar`:
`data Connection where MkConnection :: MVar ConnectionState -> Connection`
(`ClickHaskell/Connection.hs`). Every operation — `select`, `insert`, `command`, `ping` —
goes through `withConnection` (`ClickHaskell.hs`, around line 314), which does `takeMVar` and
holds the state until the operation finishes streaming its entire result. That is the defect:
two concurrent operations on the same `Connection` fully serialize, and a long select starves
a pending insert. `withConnection` also self-heals: if the action throws, it destroys the
socket, reconnects (`recreateConnectionState`), and puts the fresh state back into the
`MVar` — so a `Connection` remains usable after any failure. Note also that
`ClickHaskell.Connection` is not an exposed module of the ClickHaskell package, so there is
no public function to close a connection; the pool design below never needs one.

Typed decoding: a select statement is `Select (columns :: [Type]) output` where `columns` is
a type-level list like `'[Column "bucket" ChString, Column "value" Float64]` and `output` is
a Haskell record with `deriving anyclass (ClickHaskell columns)` (via `Generic`).
`unsafeMkSelect` builds a `Select` from raw SQL. When `select` runs, for each result block the
driver checks the server-reported column count against the declared list and throws
`ClientError (UnmatchedResult (UnmatchedColumnsCount ...))` on mismatch (`ClickHaskell.hs`,
`loopSelect`). It then decodes the block's columns *sequentially in record-field order*; for
each one, `validateColumnHeader` (`ClickHaskell/Protocol/Data.hs`, lines 112–124) compares the
server's column name and type name against the declared `Column name chType` and throws
`ClientError (UnmatchedResult (UnmatchedColumn ...))` or `... (UnmatchedType ...)` on any
difference. Malformed bytes surface as `ClientError (InternalError (DeserializationError ...))`.
Consequences: the SELECT's output columns must appear in exactly the record's field order
with exactly the declared names and types, and every mismatch is an exception — precisely the
loud failure this plan wants. Type mappings (from `ClickHaskell/Primitive/TFloat.hs`,
`TString.hs`, `TUInt.hs`): `Float64` is literally `type Float64 = Double` (decoded
little-endian with `getDoublele`), `ChString` maps to `ByteString` record fields
(`ToChType ChString ByteString`), `UInt64` to `Word64`. The insert path in this repo already
uses all of this: see `EventColumns`/`EventRow` and `CountColumns`/`CountRow` in
`kansoku-core/src/Kansoku/ClickHouse/EventRow.hs`.

### The two defects, concretely

Defect A — one connection for everything. `kansoku-server/app/Main.hs` currently calls
`openClickHouse` once and hands the same `Connection` to both `runWriter` (line 43) and
`kansokuApp` (line 37). Every dashboard query and every writer flush contend on one `MVar`.
The writer's pgmq visibility timeout is 60 seconds (`KANSOKU_WRITER_VT_SEC`); if enough slow
queries pile up in front of a flush, messages reappear in the queue and get inserted twice
(deduplicated later by the `ReplacingMergeTree` engine, but the pipeline lags and burns work).

Defect B — tab-joined string decoding. Two places ask ClickHouse to concatenate columns with
tab separators into a single `line` column and split client-side. In
`kansoku-core/src/Kansoku/ClickHouse.hs`, `projectionLineSelect` selects
`concat(event_id, '\t', CAST(event_name, 'String'), ...) AS line` and `parseProjectionLine`
splits on tab — and when the split does not yield exactly five fields it fabricates an
`EventProjection` with the whole line as `event_id` and empty everything else. In
`kansoku-core/src/Kansoku/Query.hs`, `unsafeSelect` wraps every metric query in
`SELECT concat(ifNull(toString(bucket), ''), '\t', ...) AS line FROM (...)` and `parseAggLine`
splits on tab; on any field-count mismatch it fabricates a row with `value = 0`, and
`fromMaybe 0 (readMaybe ...)` turns any unparseable number into 0. A tab inside a group key
shifts every subsequent field. The supporting wire types `ProjectionLine`,
`ProjectionLineColumns` (in `EventRow.hs`) and `AggLine` (in `Query.hs`) exist only to carry
the single glued column and are deleted by this plan.

### Code standards

Follow the repository-wide Haskell standards in
`/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/core/` (`standards.md`, `custom-prelude.md`,
`record-patterns.md`, `multiline-strings.md`). In practice for this plan: GHC2024 with the
`common` stanza extensions already in `kansoku-core.cabal`; import `Kansoku.Prelude` in every
module; postpositive qualified imports (`import Data.Pool qualified as Pool`, never
`import qualified`); records use strict fields (`!`), no field prefixes, explicit
`deriving stock (...)`/`deriving anyclass (...)` strategies; field access via generic-lens
`#label` optics with a per-module `import Data.Generics.Labels ()` (never via the prelude);
multiline SQL string literals may use the `MultilineStrings` extension already enabled in the
package.


## Plan of Work

The work is three milestones, each ending in a commit. All commits follow Conventional
Commits and carry these trailers (exact text):

```text
MasterPlan: docs/masterplans/2-kansoku-production-hardening-review-fixes-and-portfolio-service-readiness.md
ExecPlan: docs/plans/11-split-clickhouse-connections-and-adopt-typed-row-decoding.md
```

### Milestone 1 — the writer owns a dedicated connection

Scope: stop sharing one `Connection` between the writer and the HTTP handlers. After this
milestone the writer wiring opens and owns its own connection, `Main.hs` opens a separate
(still single) connection for the query side, and an integration test demonstrates that a
2-second query on the query connection no longer delays a writer insert. No handler
signatures change yet.

Edit `kansoku-core/src/Kansoku/Writer/Run.hs`: change `runWriter`'s third parameter from
`Connection` to `ClickHouseConfig` (import it from `Kansoku.ClickHouse` along with
`openClickHouse`; drop the `ClickHaskell (Connection)` import). At the top of the function
body, before `runEff`, open the dedicated connection:

```haskell
runWriter pool tracer chConfig queueName visibilityTimeoutSec adapterBatchSize maxBatchSize maxLatencyMs waitForShutdown = do
  clickHouse <- openClickHouse chConfig
  ...
```

and keep passing `clickHouse` to `writerBatchHandler` as before. Ownership now lives with the
writer wiring: nothing else can ever see this connection.

Edit `kansoku-server/app/Main.hs`: delete the shared `clickHouse <- openClickHouse ...`
single opening and instead pass `clickHouseConfigFromConfig cfg` to `runWriter`, and open a
query-side connection for the app (`queryConn <- openClickHouse (clickHouseConfigFromConfig cfg)`;
`let app = kansokuApp pool queueName queryConn`). EP-10 will have restructured this file
(writer death must exit the process); keep that structure and only change what is opened and
passed where. If EP-10 added `setPassword`/user configuration inside
`Kansoku.ClickHouse.connectionArgs`, both new connections inherit it automatically because
both go through `openClickHouse`.

Add the demonstration test to `kansoku-core/test/Kansoku/ClickHouseSpec.hs` (details and the
shared test-support refactor in Concrete Steps): with services up, start `SELECT sleep(2)` on
one connection asynchronously, then time `insertEvents` on a *different* connection; the
insert must finish in well under 2 seconds. Running the same body with both roles on the
*same* `Connection` demonstrates the old serialization (the insert waits the full 2 seconds)
— useful to convince yourself once, but the committed test only asserts the two-connection
behavior.

Acceptance: `cabal build all` is green; `cabal test` is green with `process-compose up`
running (the new test pends, like the existing ClickHouse specs, when ClickHouse is
unreachable); the new test proves the writer insert is not blocked by a slow query. Commit:

```text
refactor(clickhouse): give the writer a dedicated ClickHouse connection
```

### Milestone 2 — a query-side connection pool with configuration

Scope: replace the single query-side connection with a named pool type, `QueryPool`, sized by
a new additive Config field, and thread it through the metrics stack. After this milestone,
N concurrent metric requests progress in parallel, demonstrably.

Add `resource-pool` to the library `build-depends` in `kansoku-core/kansoku-core.cabal`, and
add `async` to the `kansoku-core-test` suite's `build-depends` (the library already has it;
the test suite needs it for the concurrency tests). `resource-pool` is a plain Hackage
package and is present in nixpkgs' GHC 9.12.4 package set, so neither `cabal.project` nor
`nix/haskell.nix` should need changes; if the nix package build (`packages.default`) ever
complains, add an override in `nix/haskell.nix` following the existing `callHackageNoCheck`
pattern and note it in Surprises & Discoveries.

Edit `kansoku-core/src/Kansoku/Config.hs`: add an additive strict field
`clickHouseQueryPoolSize :: !Int` to `Config` (additive fields only — MasterPlan integration
point "Kansoku.Config"; `loadConfig` stays total with dev-shell-friendly defaults). Read env
var `KANSOKU_CH_QUERY_POOL_SIZE` with the existing `parseInt` helper, default 4, and reject
values below 1 with a `ConfigError` naming the variable. Extend
`kansoku-core/test/Kansoku/ConfigSpec.hs` with the default and the invalid-value cases,
following its existing style.

Edit `kansoku-core/src/Kansoku/ClickHouse.hs`: define and export the pool type. This is the
stable name later plans consume — plan 9 (NamedRoutes conversion) wires handlers against it
and EP-13 (query rewrite) and EP-16 (telemetry gauges) take it as given, per the MasterPlan
integration point "ClickHouse connection ownership". Exact shape:

```haskell
import Data.Pool qualified as Pool

-- | A fixed-size pool of ClickHouse connections for the metrics query path.
-- The writer never uses this; it owns its own dedicated connection.
newtype QueryPool = QueryPool (Pool.Pool Connection)

newQueryPool :: ClickHouseConfig -> Int -> IO QueryPool
newQueryPool cfg size =
  QueryPool
    <$> Pool.newPool
      ( Pool.setNumStripes (Just 1) $
          Pool.defaultPoolConfig (openClickHouse cfg) (const (pure ())) queryConnectionIdleSeconds size
      )

-- | Effectively never reap idle connections: ClickHaskell exposes no close,
-- so reaping could only leak sockets.
queryConnectionIdleSeconds :: Double
queryConnectionIdleSeconds = 1e9

withQueryConnection :: QueryPool -> (Connection -> IO a) -> IO a
withQueryConnection (QueryPool pool) action = do
  result <- Pool.withResource pool (try @SomeException . action)
  either throwIO pure result
```

The `try`/rethrow shape is deliberate, not decoration. `Data.Pool.withResource` destroys the
resource when the action throws; our destroy action is a no-op because ClickHaskell has no
public close, so a destroyed connection would leak its socket. But ClickHaskell's
`withConnection` self-heals — after any exception the connection already holds a fresh,
reconnected state — so the right move is always to return it to the pool. Catching inside the
`withResource` action means the pool sees a normal return and calls `putResource`; the caller
still sees the original exception. `setNumStripes (Just 1)` matters because resource-pool
divides `size` across stripes (default: one per capability), which would silently shrink an
undersized pool's per-stripe capacity.

Thread the type through, replacing `Connection` in each signature:

- `Kansoku.Server`: `kansokuApp :: Pool.Pool -> QueueName -> QueryPool -> Application`
  (the `Pool.Pool` there is hasql's Postgres pool — unrelated; the distinct `QueryPool` name
  avoids the collision). Import `QueryPool` from `Kansoku.ClickHouse` instead of `Connection`
  from `ClickHaskell`.
- `Kansoku.Metrics.Handler`: `metricsApp :: QueryPool -> Application` and
  `metricsServer :: QueryPool -> Server MetricsAPI`. The body only forwards the handle to
  `Query.run`/`runSessions`/`runFunnel`/`runRetention`, so this is a type-and-import change.
  Note `effToHandler` already maps any exception from the query path to HTTP 503 with a JSON
  body — that is the loudness sink M3 relies on; leave it as is.
- `Kansoku.Query`: `run`, `runSessions`, `runRetention`, `runFunnel` take `QueryPool` instead
  of `Connection`; `runSQLWith` becomes
  `runSQLWith :: QueryPool -> Text -> (AggRow -> MetricPoint) -> Text -> IO MetricResult` and
  wraps its `select` call in `withQueryConnection`.
- `kansoku-server/app/Main.hs`: replace M1's `queryConn` with
  `queryPool <- newQueryPool (clickHouseConfigFromConfig cfg) (cfg ^. #clickHouseQueryPoolSize)`
  and pass it to `kansokuApp`.

Add the parallelism test (Concrete Steps below): four concurrent `SELECT sleep(1)` queries
through a `QueryPool` of size 4 finish in about 1 second of wall clock; the same four through
a pool of size 1 take at least 4 seconds. This is also observable over HTTP once the server
runs: four parallel `curl` requests to a metrics endpoint all make progress concurrently
(each request holds a pooled connection only for its own query).

Acceptance: build and tests green (ClickHouse-backed tests pend without services, pass with
them); the parallelism test shows the 4-vs-1 timing split. Commit:

```text
feat(clickhouse): pool query-side connections behind QueryPool
```

### Milestone 3 — typed multi-column decoding with loud failures

Scope: delete both tab-glue decode paths and select real columns, typed. After this
milestone, a tab inside a group key round-trips intact, and any decode mismatch raises (and
surfaces as HTTP 503 through the untouched `effToHandler`), never a fabricated zero.

In `kansoku-core/src/Kansoku/Query.hs`, replace the wire types:

```haskell
type AggColumns =
  '[ Column "bucket" ChString,
     Column "group_key" ChString,
     Column "value" Float64
   ]

data AggRow = AggRow
  { bucket :: !ByteString,
    group_key :: !ByteString,
    value :: !Double
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ClickHaskell AggColumns)
```

(import `Float64` from `ClickHaskell`; field order must match the column list — the driver
decodes columns in record-field order and validates each name, as explained in Context and
Orientation). Delete `AggLine` and `parseAggLine`, and the `Text.Read (readMaybe)` import.
Replace `unsafeSelect` with a typed wrapper that selects the three aliased columns every
builder already produces, pinning their types with `CAST`:

```haskell
aggSelect :: Text -> Select AggColumns AggRow
aggSelect sql =
  unsafeMkSelect $
    const $
      Text.encodeUtf8Builder $
        Text.unlines
          [ "SELECT CAST(bucket, 'String') AS bucket, CAST(group_key, 'String') AS group_key, CAST(value, 'Float64') AS value",
            "FROM (",
            sql,
            ")",
            "SETTINGS compile_expressions = 0, compile_sort_description = 0"
          ]
```

`runSQLWith` becomes `withQueryConnection pool $ \conn -> concat <$> select (aggSelect sql) conn pure`
with no per-row parsing; the point-builder functions (`defaultPoint`, `retentionPoint`,
`funnelPoint`) now take the `ByteString` fields and convert with strict
`Text.decodeUtf8` (`Data.Text.Encoding`) — invalid UTF-8 throws, which is the loud behavior
we want. Keep the existing `List.sortOn` re-sort exactly as is (removing it is EP-13's
explicitly listed job, not this plan's). Keep `funnelPoint`'s split of the synthetic
`"index|step"` composite key: that string is built by our own SQL builder from a literal, is
not wire decoding, and EP-13's `windowFunnel` rewrite replaces it wholesale — note this
remnant in your Decision Log entry if you touch it.

About the `SETTINGS` suffix carried into `aggSelect`: it disables ClickHouse's LLVM JIT
compilation of expressions and of sort descriptions for the query. EP-6 added it because the
local ClickHouse crashed with `std::bad_alloc` in those JIT paths on the funnel/retention
queries (evidence: `docs/plans/6-semantic-metrics-layer-and-typed-query-api.md`, Surprises
and Decision Log, dated 2026-07-02). During this milestone, temporarily remove the line, run
the fixture-backed HTTP checks and the integration tests against the current nix-pinned
ClickHouse, and record the observed result in Surprises & Discoveries: if everything passes
repeatedly, drop the setting for good (it predates the typed path and may have been
version-specific); if ClickHouse still misbehaves, restore the line and record the failure
output as the justification. Either way the decision must end up written down with evidence.

In `kansoku-core/src/Kansoku/ClickHouse.hs` and
`kansoku-core/src/Kansoku/ClickHouse/EventRow.hs`, do the same for projections. In
`EventRow.hs`: delete `ProjectionLine` and `ProjectionLineColumns`, add

```haskell
type ProjectionColumns =
  '[ Column "event_id" ChString,
     Column "event_name" ChString,
     Column "source" ChString,
     Column "account_id" ChString,
     Column "user_id" ChString
   ]
```

and attach the instance to the existing record (its five `ByteString` fields are already in
this exact order): `deriving anyclass (ClickHaskell ProjectionColumns)` on `EventProjection`.
Export `ProjectionColumns`, drop the deleted exports. In `ClickHouse.hs`: delete
`parseProjectionLine` and `projectionLineSelect`, and replace `selectEventProjections` with a
five-column select — `CAST` on the two `LowCardinality(String)` columns so the reported type
is `String` (see Decision Log):

```haskell
selectEventProjections :: Connection -> IO [EventProjection]
selectEventProjections conn =
  concat <$> select projectionSelect conn pure

projectionSelect :: Select ProjectionColumns EventProjection
projectionSelect =
  unsafeMkSelect $ \_ ->
    "SELECT event_id, CAST(event_name, 'String') AS event_name, CAST(source, 'String') AS source, account_id, user_id FROM events_raw"
```

`countEvents`/`CountRow` are already typed; leave them alone. The `Data.ByteString.Char8`
import in `ClickHouse.hs` becomes unused — remove it.

Tests (full bodies sketched in Concrete Steps): the existing `ClickHouseSpec` projection
round-trip must still pass unchanged — that is the proof the typed path decodes real data.
Add a projection case whose `event_name` contains a literal tab and assert the projection
comes back intact (the old parser fabricated a garbage row for exactly this input). Add a
new `Kansoku.QueryIntegrationSpec` that inserts events (one with a tab-bearing event name),
runs the real `events` metric grouped by `event_name` through `Query.run` with a `QueryPool`,
and asserts the tab-bearing group key appears verbatim with the right count. Add a
loud-failure case: a deliberately mistyped select (declared `Float64`, server returns
`String`) must throw `ClientError` — assert with `shouldThrow`; this pins the driver behavior
the whole design rests on. Finally, verify over HTTP with the EP-6 fixtures that metric
numbers did not change (the decode path changed; the numbers must not).

Acceptance: all tests green with services up; grep confirms no `splitOn`-over-wire-results
remains in `Kansoku/Query.hs` or `Kansoku/ClickHouse*.hs`; fixture curl output matches
pre-change output. Commit:

```text
fix(query): decode typed ClickHouse columns instead of tab-joined lines
```


## Concrete Steps

All commands run from the repository root
`/Users/shinzui/Keikaku/bokuno/kansoku-project/kansoku`, inside `nix develop`.

Before anything, confirm EP-10 landed and the tree is healthy:

```bash
git log --oneline -5   # expect EP-10's commits present
just build             # cabal build all — must be green before you start
```

Start services in a second terminal and leave them running for every integration step:

```bash
just up                # process-compose: postgres, clickhouse, create_schema
just ch-migrate        # apply db/clickhouse/migrations/*.sql
```

Test-support refactor (part of M1): the `withClickHouse`/`resetTable` helpers currently
private to `kansoku-core/test/Kansoku/ClickHouseSpec.hs` are needed by the new specs. Move
them verbatim into a new module `kansoku-core/test/Kansoku/ClickHouseTestSupport.hs`
(exporting `withClickHouse` and `resetTable`), import it from `ClickHouseSpec`, and register
the module under `other-modules` of the `kansoku-core-test` stanza in
`kansoku-core/kansoku-core.cabal`. Note the helper's behavior, which every integration test
here must keep: it loads `Config` from the environment, opens a bootstrap connection,
`ping`s, runs `ensureSchema`, and on any setup exception calls `pendingWith "ClickHouse not
reachable: ..."` — so `just test` stays green on a machine without services, and actually
exercises ClickHouse when `process-compose` is up.

M1 test, added to `ClickHouseSpec` (new `describe "connection ownership"`); it needs a tiny
throwaway typed select for `sleep` and the `async` dependency added in M2 — if you want to
land M1 first, add `async` to the test suite's `build-depends` already in M1:

```haskell
type SleepColumns = '[Column "s" UInt8]

newtype SleepRow = SleepRow {s :: Word8}
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ClickHaskell SleepColumns)

sleepSelect :: Select SleepColumns SleepRow
sleepSelect = unsafeMkSelect (const "SELECT toUInt8(sleep(2)) AS s")

it "does not block a writer insert behind a slow query on another connection" $
  withClickHouse $ \queryConn -> do
    resetTable queryConn
    writerConn <- openClickHouse . clickHouseConfigFromConfig =<< requireConfig
    withAsync (select sleepSelect queryConn pure) $ \slow -> do
      started <- getCurrentTime
      insertEvents writerConn [sampleEvent "evt_split_1" "page_view"]
      finished <- getCurrentTime
      _ <- wait slow
      diffUTCTime finished started `shouldSatisfy` (< 1)
```

(`requireConfig` is a small helper: `loadConfig` and fail the expectation on `Left`; ClickHouse
caps `sleep` at 3 seconds, hence 2.) Expected transcript with services up:

```text
Kansoku.ClickHouse
  connection ownership
    does not block a writer insert behind a slow query on another connection [✔]
```

Then:

```bash
just build && just test
git add -A
git commit   # message and trailers from Milestone 1
```

M2 pool test, in the new `kansoku-core/test/Kansoku/QueryIntegrationSpec.hs` (register in
`other-modules` and add `Kansoku.QueryIntegrationSpec.spec` to the `hspec` block in
`kansoku-core/test/Spec.hs` — the suite enumerates specs manually, it does not use
hspec-discover). Define `sleep1Select` exactly like M1's `sleepSelect` but with `sleep(1)`, and time both pool
sizes:

```haskell
timedSleeps :: Int -> ClickHouseConfig -> IO NominalDiffTime
timedSleeps poolSize cfg = do
  queryPool <- newQueryPool cfg poolSize
  started <- getCurrentTime
  _ <- mapConcurrently (\_ -> withQueryConnection queryPool (\conn -> select sleep1Select conn pure)) [1 :: Int .. 4]
  finished <- getCurrentTime
  pure (diffUTCTime finished started)

it "runs concurrent queries in parallel across the pool" $
  withClickHouse $ \_conn -> do
    cfg <- clickHouseConfigFromConfig <$> requireConfig
    pooled <- timedSleeps 4 cfg
    pooled `shouldSatisfy` (< 2.5)

it "serializes when the pool has a single connection (control)" $
  withClickHouse $ \_conn -> do
    cfg <- clickHouseConfigFromConfig <$> requireConfig
    serialized <- timedSleeps 1 cfg
    serialized `shouldSatisfy` (>= 4)
```

The second case is the control that proves the first number means something. To observe the
same thing over HTTP: with fixtures loaded and the server running (`just run` in another
terminal), `time` four parallel requests —

```bash
just ch-fixtures-ep6
seq 4 | xargs -P4 -I{} curl -s "http://localhost:8080/metrics/events?from=2026-06-01&to=2026-06-08" -o /dev/null
```

All four return promptly rather than queuing behind one another (exact latencies depend on
fixture size; the committed timing assertions are the authoritative check). Then build, test,
commit as in Milestone 2.

M3 tests. In `ClickHouseSpec`, extend the projection round-trip with a tab-bearing event and
add the loud-failure pin (a deliberately wrong column type must throw, not zero):

```haskell
it "round-trips an event name containing a tab through projections" $
  withClickHouse $ \conn -> do
    resetTable conn
    insertEvents conn [sampleEvent "evt_tab_1" "signup\tstep"]
    rows <- selectEventProjections conn
    rows `shouldContain` [expectedProjection "evt_tab_1" "signup\tstep"]

type MistypedColumns = '[Column "value" Float64]

newtype MistypedRow = MistypedRow {value :: Double}
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ClickHaskell MistypedColumns)

it "raises on a column type mismatch instead of fabricating values" $
  withClickHouse $ \conn ->
    select (unsafeMkSelect (const "SELECT 'oops' AS value") :: Select MistypedColumns MistypedRow) conn pure
      `shouldThrow` \case ClientError.UnmatchedResult _ -> True; _ -> False
```

(match the constructor names as imported; asserting `anyException` is acceptable if the
`ClientError` constructors prove awkward to import — record which you did). In
`QueryIntegrationSpec`, the end-to-end tab case through the real metric path:

```haskell
it "keeps a tab-bearing group key intact through a grouped metric query" $
  withClickHouse $ \conn -> do
    resetTable conn
    insertEvents conn [sampleEvent "evt_q_1" "signup\tstep", sampleEvent "evt_q_2" "page_view"]
    queryPool <- (`newQueryPool` 2) . clickHouseConfigFromConfig =<< requireConfig
    let Just metric = builtinMetric "events"
    result <- runEff (Query.run queryPool metric QueryRequest { from = fromGregorian 2026 7 1, to = fromGregorian 2026 7 2, groupBy = Just ["event_name"], timeGrain = Just Day })
    let keys = [value | point <- result ^. #points, Just value <- [Map.lookup "event_name" (point ^. #group)]]
    keys `shouldContain` ["signup\tstep"]
```

(the sample-event dates in the existing helpers are 2026-07-01; keep the query window
covering them). Before the fix, this exact input produced a fabricated
`bucket = "...\tsignup"`-style garbage row with `value = 0`; after it, the tab survives.
Fixture regression check over HTTP, run before and after the M3 code change — the outputs
must be identical:

```bash
just ch-fixtures-ep6
curl -s "http://localhost:8080/metrics/active_users?from=2026-06-01&to=2026-06-08" | jq -S . > /tmp/after.json
diff /tmp/before.json /tmp/after.json && echo IDENTICAL
```

Capture the `IDENTICAL` line (or the EP-6-documented fixture values) in Surprises &
Discoveries alongside the `SETTINGS` finding. Then build, test, commit as in Milestone 3,
update this plan's living sections, and set EP-11 to Complete in the MasterPlan registry
(`docs/masterplans/2-kansoku-production-hardening-review-fixes-and-portfolio-service-readiness.md`),
ticking its three Progress lines there.


## Validation and Acceptance

Compilation is never the bar; the behaviors below are.

Connection split (M1): with `process-compose up` running, `cabal test` shows the
"does not block a writer insert behind a slow query on another connection" case passing —
the insert completes in under 1 second while a 2-second query occupies the query connection.
Without services, the case reports as pending ("ClickHouse not reachable"), and the rest of
the suite is unaffected.

Pool (M2): the two timing cases pass — four concurrent 1-second queries complete in under
2.5 seconds through a pool of 4 and take at least 4 seconds through a pool of 1.
`KANSOKU_CH_QUERY_POOL_SIZE=0 cabal run kansoku-server` fails fast with a `ConfigError`
naming the variable; unset, the server starts and logs its usual startup line, and
`Kansoku.ConfigSpec` covers default and rejection. The HTTP demonstration in Concrete Steps
shows four parallel curls returning promptly.

Typed decoding (M3): the tab round-trip cases pass at both the projection layer and the full
metric path; the mismatch case proves a wrong wire shape throws `ClientError` instead of
yielding zeros; and because `Kansoku.Metrics.Handler.effToHandler` (unchanged) `try`s the
query action and maps any exception to HTTP 503 with a JSON error body, any such failure in
production surfaces as a 503, never a plausible-zero 200. The fixture diff before/after M3 is
byte-identical, proving decode-path changes did not alter metric values. `buildSQL` unit
tests in `kansoku-core/test/Kansoku/QuerySpec.hs` pass without modification, proving the
EP-13 boundary held (builders untouched). Finally:

```bash
grep -rn "splitOn" kansoku-core/src/Kansoku/Query.hs kansoku-core/src/Kansoku/ClickHouse.hs kansoku-core/src/Kansoku/ClickHouse/EventRow.hs
```

must return only the query-parameter CSV helper usages outside the wire-decode path (in
`Kansoku/Metrics/Handler.hs`, which is fine) — i.e., no hits in the three files above.


## Idempotence and Recovery

Every step is safe to repeat. `just ch-migrate` applies `CREATE ... IF NOT EXISTS`
migrations; `just ch-fixtures-ep6` reloads fixtures (it truncates/reinserts fixture rows —
rerun it whenever a test has truncated `analytics.events_raw`, and note the integration tests
call `resetTable`, so reload fixtures before HTTP checks that follow a test run). The
integration tests reset the table themselves and pend harmlessly without services. Each
milestone is an independent commit; if a milestone goes wrong midway, `git checkout -- .` (or
`git reset --hard HEAD`) returns to the last good commit and the milestone can be restarted
from its section here. No schema or data migration is involved anywhere in this plan — the
riskiest operation is a `TRUNCATE` of a local dev table. If a rebase over parallel Phase-2
work (EP-12 schema plan, plan 9 routing plan) conflicts, prefer their versions for files this
plan does not own (`db/clickhouse/migrations/`, `kansoku-api` route types) and re-apply this
plan's mechanical signature changes on top.


## Interfaces and Dependencies

New dependency: `resource-pool` (module `Data.Pool`) in the `library` stanza of
`kansoku-core/kansoku-core.cabal`; `async` (already a library dependency) added to the
`kansoku-core-test` stanza. Driver: `ClickHaskell` as pinned in `cabal.project`
(source-repository-package, tag `56efc18...`), source readable at
`/Users/shinzui/Keikaku/hub/haskell/clickhaskell-project/ClickHaskell/library/`.

At the end of M1 (module `Kansoku.Writer.Run`):

```haskell
runWriter ::
  Pool.Pool ->            -- hasql Postgres pool (pgmq)
  OTel.Tracer ->
  ClickHouseConfig ->     -- was: Connection; the writer now opens and owns its own
  QueueName ->
  Int32 -> Int32 -> Int -> Int ->
  IO () ->
  IO ()
```

At the end of M2 (module `Kansoku.ClickHouse` — the stable handle later plans consume):

```haskell
newtype QueryPool = QueryPool (Pool.Pool Connection)

newQueryPool :: ClickHouseConfig -> Int -> IO QueryPool
withQueryConnection :: QueryPool -> (Connection -> IO a) -> IO a
```

with `Kansoku.Config.Config` gaining `clickHouseQueryPoolSize :: !Int`
(env `KANSOKU_CH_QUERY_POOL_SIZE`, default 4, must be >= 1), and consumers:

```haskell
Kansoku.Server.kansokuApp          :: Pool.Pool -> QueueName -> QueryPool -> Application
Kansoku.Metrics.Handler.metricsApp :: QueryPool -> Application
Kansoku.Metrics.Handler.metricsServer :: QueryPool -> Server MetricsAPI
Kansoku.Query.run          :: (IOE :> es) => QueryPool -> BuiltinMetric -> QueryRequest -> Eff es MetricResult
Kansoku.Query.runSessions  :: (IOE :> es) => QueryPool -> QueryRequest -> Eff es MetricResult
Kansoku.Query.runRetention :: (IOE :> es) => QueryPool -> QueryRequest -> [Int] -> Eff es MetricResult
Kansoku.Query.runFunnel    :: (IOE :> es) => QueryPool -> QueryRequest -> [Text] -> Eff es MetricResult
```

At the end of M3: `Kansoku.Query` internally defines `AggColumns`
(`'[Column "bucket" ChString, Column "group_key" ChString, Column "value" Float64]`) and
`AggRow` (`ByteString`/`ByteString`/`Double`, `deriving anyclass (ClickHaskell AggColumns)`);
`Kansoku.ClickHouse.EventRow` exports `ProjectionColumns` and `EventProjection` carries
`deriving anyclass (ClickHaskell ProjectionColumns)`; `ProjectionLine`,
`ProjectionLineColumns`, `AggLine`, `parseAggLine`, and `parseProjectionLine` no longer
exist. SQL builders (`buildSQL`, `buildSessionsSQL`, `buildRetentionSQL`, `buildFunnelSQL`)
keep their current `-> Text` signatures for EP-13 to rewrite.

---

Revision note (2026-07-15): initial full authoring of this plan from the registered skeleton,
after reading the ClickHaskell driver source (connection `MVar` semantics, generic column
decode and its header validation, `Float64 = Double`, no public close), the current
`Main.hs`/`Writer/Run.hs`/`ClickHouse.hs`/`Query.hs`/`Server.hs`/`Metrics/Handler.hs`/
`Config.hs` and their tests, and EP-6's recorded rationale for the `SETTINGS` workaround.

---

Revision note (2026-07-15): heads-up added after authoring — EP-13
(`docs/plans/13-safe-and-correct-metric-sql-validated-inputs-ordered-funnels-honest-failures.md`)
will bump the `cabal.project` ClickHaskell pin to a version with protocol-level query
parameters (upstream commit `d372918`; the corpus was stale when this plan's driver findings
were recorded). This plan still implements against the current pin, but its embedded driver
findings (MVar semantics, `select` column validation, the no-public-close constraint behind
the never-destroy pool) must be re-verified by EP-13 after the bump; if the newer driver
gains a public connection close, the pool's no-op destroy decision should be revisited then.
