---
id: 13
slug: safe-and-correct-metric-sql-validated-inputs-ordered-funnels-honest-failures
title: "Safe and correct metric SQL: validated inputs, ordered funnels, honest failures"
kind: exec-plan
created_at: 2026-07-15T21:30:34Z
master_plan: "docs/masterplans/2-kansoku-production-hardening-review-fixes-and-portfolio-service-readiness.md"
intention: intention_01kxr5jt2heyvt0n768ym9dwqd
---

# Safe and correct metric SQL: validated inputs, ordered funnels, honest failures

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Kansoku's metrics API compiles HTTP query parameters into ClickHouse SQL by concatenating
`Text`. A 2026-07-15 architecture review found four defects in that layer, and this plan fixes
all of them:

1. **SQL injection.** Funnel step names arrive in the `steps` query parameter of
   `GET /metrics/funnel` and are spliced into SQL guarded only by a hand-rolled escaper that
   handles `'` and `\`. The service has no authentication yet (EP-15 adds it), so this is
   remotely injectable today. After this plan, every user-derived string that can reach SQL is
   validated against a conservative character whitelist at the HTTP boundary; anything else is
   rejected with HTTP 400 and a JSON body naming the offending value.
2. **Order-blind, quadratic funnels.** The funnel query emits one `UNION ALL` branch per step,
   where step N carries N-1 correlated `IN (SELECT ...)` subqueries — a full extra scan per
   prior step — and never checks that a user performed the steps *in order*. After this plan
   the funnel is one pass over `analytics.events_resolved` using ClickHouse's `windowFunnel`
   aggregate, which respects event order: a user who completed step 2 before step 1 no longer
   counts as reaching step 2. A demonstration against fixtures proves it.
3. **Dishonest failures.** The result decoder turns unparsable numbers into `0` and malformed
   rows into a plausible-looking row, so a broken query produces believable zeros instead of an
   error. After this plan, decode failures throw, the caller sees HTTP 503 with an error body,
   and a redundant Haskell-side re-sort of already-`ORDER BY`-ed results is deleted.
4. **Undocumented retention semantics.** Retention computes cohorts from first activity
   *within the requested window*, so a long-standing user re-appears as a fresh cohort. That is
   an intentional MVP decision; this plan keeps the behavior but names it ("new-in-window
   cohorts") in the API documentation so nobody mistakes it for lifetime cohorts.

Observable outcome: with dev services running (`process-compose up`), migrations and fixtures
loaded, and `cabal run kansoku-server` listening on port 8080,
`curl 'http://localhost:8080/metrics/funnel?from=2026-06-01&to=2026-06-08&steps=signup_started,signup%20--%20DROP'`
returns HTTP 400 naming the bad step, and the same request with valid steps returns per-step
counts that exclude out-of-order users. `cabal test` passes with new specs covering the
validator, the `windowFunnel` SQL shape, and the updated golden SQL.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] 2026-07-18: implementation started after EP-12, EP-11, and EP-9 completed; reconciled
      target state is schema v2 + typed ClickHaskell decoding + QueryPool + NamedRoutes/MultiVerb

- [ ] M1: `Kansoku.Query.Validate` module with `SqlName` smart constructor and charset rules
- [ ] M1: funnel handler rejects invalid steps with HTTP 400 JSON naming the value
- [ ] M1: registry-conformance test (every built-in metric event name passes the validator)
- [ ] M1: ClickHaskell pin bumped to ≥ upstream `d372918` (query-parameter support);
      EP-11 decode/pool behavior re-verified against the new driver
- [ ] M1: user-derived strings routed through native parameters (`passParameters`/
      `addParameter`); charset validation retained as defense-in-depth; outcome recorded in
      Decision Log and Surprises & Discoveries (fallback: validation-only, per Plan of Work
      step 4)
- [ ] M2: optional `window` query parameter added to the funnel route (API type + OpenAPI)
- [ ] M2: `buildFunnelSQL` rewritten to single-pass `windowFunnel` with MultilineStrings
- [ ] M2: QuerySpec shape tests for the new funnel SQL
- [ ] M2: out-of-order fixture user added; curl transcript proves ordered semantics
- [ ] M3: decode fallbacks throw instead of yielding zeros (state which EP-11 branch applied)
- [ ] M3: Haskell-side re-sort removed from `runSQLWith`
- [ ] M3: `buildSessionsSQL` predicate updated for v2 non-Nullable `session_id`
- [ ] M3: rollup readers reconciled with EP-12 merge functions; goldens updated
- [ ] M4: retention route documented as "new-in-window cohorts" via servant `Description`
- [ ] M4: `normalizeOffsets` offset-0 injection documented as intended
- [ ] M4: full `cabal test` + end-to-end curl pass recorded in Validation section

## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Authoring-time (2026-07-15): ClickHaskell's native query-parameter support is a protocol
  stub. In `ClickHaskell/Protocol/Client.hs` (source at
  `/Users/shinzui/Keikaku/hub/haskell/clickhaskell-project/ClickHaskell/library/`), the
  `QueryPacket` field `parameters` is always `MkQueryParameters`, and:

  ```haskell
  data QueryParameters = MkQueryParameters
  instance Serializable QueryParameters where
    serialize rev _ = serialize @ChString rev ""
    deserialize _rev = fail "QueryParameters reading unimplemented"
  ```

  There is no API to attach `{name:String}` placeholder values to a query, so server-side
  parameterization is not available through this client. See Milestone 1 for the
  re-verification steps and the fallback decision. (Implementer: confirm against the version
  actually in scope and update this entry.)

  **SUPERSEDED same day (2026-07-15, later):** the local corpus checkout was stale. After
  the user updated it, upstream ClickHaskell carries real protocol-level query-parameter
  support (commit `d372918` "Feature: query parameters support (#471)"): `QueryParameters`
  is now `MkQueryParameters DbSettings` with a working `addParameter :: IsParameterType
  param => String -> param -> QueryParameters -> QueryParameters`, `Statements.hs` exposes
  `passParameters` on `Select`/`Insert`/`Command`, and the query packet carries `params`
  revision-gated on `DBMS_MIN_PROTOCOL_VERSION_WITH_PARAMETERS`. HOWEVER, kansoku's
  `cabal.project` pins ClickHaskell at git tag `56efc1840d79c89c2a6ade3794932588b65febab`,
  which PREDATES this feature — adopting native parameters requires bumping that pin (and
  re-running EP-11's driver-behavior checks against the new version, since EP-11's decode
  and pooling designs were verified against the older code). Milestone 1's investigation is
  now expected to conclude "supported after pin bump" rather than "unavailable".
- Authoring-time (2026-07-15): `windowFunnel`'s window argument is expressed in the *tick
  unit of the timestamp column*. `analytics.events_raw.occurred_at` is
  `DateTime64(3, 'UTC')` (millisecond ticks), so a bare `windowFunnel(604800)(occurred_at, ...)`
  would mean a 604.8-second window, not 7 days. The plan's SQL therefore wraps the timestamp
  as `toDateTime(occurred_at)` so the window is in seconds. Verify this against the fixture
  data in Milestone 2 and record the observed behavior here.


## Decision Log

Record every decision made while working on the plan.

- Decision: Charset-first validation is the primary injection defense; ClickHouse native
  query parameters are an *investigated enhancement*, adopted only if the pinned ClickHaskell
  actually supports them on the SELECT path.
  Rationale: Authoring-time reading of ClickHaskell source shows `Parameters`/`parameter`
  exist only for parameterized *views* (`fromView` renders `view(name='val')` call syntax in
  `Statements.hs`), while the wire-protocol `QueryParameters` is an unimplemented stub that
  always serializes empty. A strict whitelist (`^[a-z0-9_.:-]{1,128}$`) makes escaping moot
  for names regardless, so validation must exist either way (belt and braces).
  Date: 2026-07-15

- Decision (updating the previous entry): upstream ClickHaskell now supports protocol-level
  query parameters (commit `d372918`, see Surprises & Discoveries); Milestone 1 therefore
  bumps kansoku's `cabal.project` ClickHaskell pin to a commit/tag at or after that feature
  and routes all user-derived strings (funnel steps, and event names where they reach SQL)
  through `passParameters`/`addParameter` with `{name:String}` placeholders. Charset
  validation is RETAINED unchanged as defense-in-depth and as the 400-with-offending-value
  UX (parameters make injection impossible; validation still rejects garbage early with a
  useful error). If the pin bump destabilizes anything EP-11 built (decode paths, pooling —
  EP-11 verified driver behavior against the older pin), the pin bump is still taken and
  EP-11's affected checks are re-run; coordinate via the MasterPlan's Surprises section.
  Rationale: user updated the stale corpus (2026-07-15); server-side parameters are
  categorically stronger than escaping/validation and the plan's original decision
  explicitly promised adoption once supported.
  Date: 2026-07-15
- Decision: The funnel window is an optional `window` query parameter (seconds), defaulting
  to the full requested `[from, to)` range, and both the default and any explicit value are
  capped at 90 days (7,776,000 seconds); explicit values outside `1..7776000` are rejected
  with HTTP 400.
  Rationale: An explicit parameter makes the semantics visible in the API and OpenAPI doc
  instead of hiding a magic constant; deriving the default from the range means the MVP
  behavior ("any order of steps inside the queried range" tightened to "in order inside the
  queried range") changes minimally for existing callers. The 90-day cap bounds `windowFunnel`
  per-user state and matches the longest built-in retention offset (30 days) with headroom;
  a "funnel" spanning more than a quarter is not a meaningful conversion measurement.
  Date: 2026-07-15
- Decision: Retention keeps its "new-in-window cohorts" semantics (cohort day = first
  activity inside the requested window); this plan labels the behavior in the OpenAPI
  description and code comments but does not change it.
  Rationale: Changing to lifetime cohorts is a semantic change with storage implications
  (a first-seen rollup) that belongs to a future metrics plan; the review's complaint was
  that the behavior is *undocumented*, not that it is wrong for an MVP.
  Date: 2026-07-15
- Decision: Delete the Haskell-side `List.sortOn` re-sort in `runSQLWith` and rely on each
  builder's `ORDER BY`, asserted by tests.
  Rationale: Every builder already emits `ORDER BY`; sorting again in Haskell hides a missing
  `ORDER BY` bug (dishonest, like the zero-defaulting decode) and costs O(n log n) per query
  for nothing.
  Date: 2026-07-15


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

Kansoku is a Haskell analytics service (GHC 9.12.4, nix flake, four cabal packages). Events
are ingested over HTTP, queued in Postgres (pgmq), and batch-inserted into ClickHouse.
Dashboards query metrics back out over HTTP. This plan touches only the *query* side: the
code that turns a metrics HTTP request into ClickHouse SQL and turns rows back into JSON.

Build and test with `just build` (= `cabal build all`) and `just test` (= `cabal test`) from
the repository root, inside `nix develop`. Dev services (Postgres, ClickHouse) start with
`process-compose up` (= `just up`). ClickHouse migrations apply with `just ch-migrate`;
metric verification fixtures load with `just ch-fixtures-ep6`. The server runs with
`cabal run kansoku-server` and listens on port 8080 (`KANSOKU_SERVER_PORT` overrides).

The files this plan owns or edits:

- `kansoku-core/src/Kansoku/Query.hs` — the query compiler. Exposes `QueryRequest` (from/to
  days, optional groupBy list, optional time grain), pure SQL builders (`buildSQL`,
  `buildFunnelSQL`, `buildRetentionSQL`, `buildSessionsSQL`), and runners (`run`,
  `runFunnel`, `runRetention`, `runSessions`) that execute SQL over a ClickHaskell
  `Connection` and shape rows into `MetricResult`.
- `kansoku-core/src/Kansoku/Metrics/Handler.hs` — servant handlers for the metrics API
  (`metricsApp`, `metricsServer`). This is where HTTP query parameters become a
  `QueryRequest` and where 400/404/501/503 errors are produced. (If EP-9,
  `docs/plans/9-convert-kansoku-to-namedroutes-vertical-slices-and-multiverb.md`, has landed,
  these handlers live in its vertical-slice layout instead; see "Two possible repo states"
  below.)
- `kansoku-api/src/Kansoku/Api/Metrics.hs` — the servant API type `MetricsAPI` and DTOs
  (`MetricPoint`, `MetricResult`, `TimeGrain`). The funnel route gains an optional `window`
  parameter in Milestone 2.
- `kansoku-core/src/Kansoku/Metrics/Registry.hs` and `Kansoku/Metrics/Definition.hs` — the
  built-in metric catalog. Metric event names (like `page_view`, `signup_completed`) come
  from here, not from users, but they flow through the same SQL builders and are validated
  by the same rules for defense in depth.
- `kansoku-core/src/Kansoku/OpenApi.hs` — builds the OpenAPI document with
  `Servant.OpenApi.toOpenApi` from the API type. Route descriptions attach via servant's
  `Description` combinator *in the API type*, not in this file; this file only needs new
  schema instances if new DTO types appear (none are planned).
- `kansoku-core/test/Kansoku/QuerySpec.hs` — golden-ish assertions on generated SQL text.
- `db/clickhouse/fixtures/ep6_fixtures.sql` — verification fixture events (users u1..u3,
  events e1..e9 plus a deliberate duplicate). EP-12 rewrites this file for the v2 schema;
  Milestone 2 appends an out-of-order funnel user after EP-12 is Complete.
- `db/clickhouse/migrations/` — this plan adds **no** migrations. Any ClickHouse object it
  needs is EP-12's responsibility; if a discrepancy is found, record it in Surprises &
  Discoveries and coordinate, do not add DDL here.

### Dependencies on other plans

**Hard dependency — EP-12 must be Complete**
(`docs/plans/12-clickhouse-schema-v2-sort-key-final-free-resolution-join-free-rollups.md`).
Every SQL builder this plan rewrites targets EP-12's v2 schema; writing them against v1 would
mean migrating the same SQL twice. At the time of authoring, EP-12's plan file was still a
skeleton, so *this plan is written against the contract stated in the MasterPlan's
Integration Points section* (`docs/masterplans/2-kansoku-production-hardening-review-fixes-and-portfolio-service-readiness.md`),
namely: `analytics.events_resolved` is FINAL-free (no `FINAL` keyword needed at read time);
the DAU/WAU/page-view rollups are join-free with `countState`/`uniqCombined`-family aggregate
states (v1 used `uniqExactState` everywhere — see `db/clickhouse/migrations/0003_rollups.sql`
for the v1 shapes); the `events_raw` sort key is `(account_id, event_name, occurred_at,
event_id)`; and v1 `Nullable(String)` columns (notably `session_id` and `url`) become plain
`String DEFAULT ''`. **Before starting, read EP-12's finished plan and its migration files
and reconcile every assumption in this plan against what actually landed** (exact rollup
table names, exact state function names — `uniqCombinedMerge` vs `uniqCombined64Merge`,
`countMerge`); record deviations in this plan's Surprises & Discoveries.

**Soft dependency — EP-11**
(`docs/plans/11-split-clickhouse-connections-and-adopt-typed-row-decoding.md`). EP-11 owns the
ClickHouse client layer: a query-side connection pool and *typed row decoding* replacing the
current wire hack in `Query.hs`, where every query is wrapped in
`SELECT concat(toString(bucket), '\t', toString(group_key), '\t', toString(value))` and split
on tabs in Haskell (`parseAggLine`). If EP-11 has landed, this plan's builders return proper
three-column rows (`bucket`, `group_key`, `value`) through EP-11's decode shape and the
tab-concat wrapper is already gone; if it has not landed, the tab-joined path still works and
this plan only hardens its failure behavior (Milestone 3 states both branches explicitly).
Either way, the stable contract *this plan* maintains is: every builder emits a relation with
exactly the columns `bucket` (String), `group_key` (String), `value` (Float64-coercible),
already ordered.

**Soft dependency — EP-9**
(`docs/plans/9-convert-kansoku-to-namedroutes-vertical-slices-and-multiverb.md`). EP-9
converts the positional `:<|>` API chain to a NamedRoutes record and moves handlers into
vertical slices, and it makes servant the single router. This plan's handler and API edits
are described for both repo states (see below). If EP-9 lands first, follow its layout; note
which state you found in this plan's Decision Log.

### Two possible repo states for the API and handlers

Pre-EP-9 (state at authoring): `MetricsAPI` in `kansoku-api/src/Kansoku/Api/Metrics.hs` is a
positional chain; the funnel route reads:

```haskell
:<|> "metrics"
  :> "funnel"
  :> QueryParam' '[Required] "from" Day
  :> QueryParam' '[Required] "to" Day
  :> QueryParam' '[Required] "steps" Text
  :> Get '[JSON] MetricResult
```

and handlers live in `kansoku-core/src/Kansoku/Metrics/Handler.hs`, wired positionally in
`metricsServer`, served by the hand-rolled WAI dispatcher in
`kansoku-core/src/Kansoku/Server.hs` (which forwards `/metrics/...` to `metricsApp`).

Post-EP-9: the funnel route is a *field* of a NamedRoutes record (EP-9's plan names the
record and slice modules); the same combinator chain appears as the field's type, so the
edits in this plan (adding `QueryParam "window" Int` and `Description`) are textually the
same, just located in the record field. The handler edit likewise moves to whichever module
EP-9 placed `funnelHandler` in. Nothing in this plan depends on which state holds.

**Wire-type coordination (from the MasterPlan's Integration Points):** the metrics route
types are also touched by EP-14 (ingest contract, different routes) and EP-15 (auth on all
routes), in the order EP-9 → EP-14 → EP-15. This plan's `window` parameter is an additive
change to one route; regenerate the OpenAPI document in the same commit. `kansoku-client`
(`kansoku-client/src/Kansoku/Client.hs`) generates client functions only for `IngestAPI`,
not metrics, so no client code changes — verify that is still true at implementation time
and note it.

### How a metrics request flows today (pre-EP-11 wire detail)

`funnelHandler` in `Metrics/Handler.hs` splits the required `steps` query parameter on commas
(`nonEmptyCsv`), rejects only the *empty* list, and passes the raw step texts to
`Query.runFunnel`. `buildFunnelSQL` splices each step into SQL via `sqlString`, which wraps
in single quotes and escapes only `'` and `\`. The runner `runSQLWith` executes via
`unsafeSelect` (the tab-concat wrapper over ClickHaskell's `unsafeMkSelect`), parses each
line with `parseAggLine` — whose failure modes are `fromMaybe 0` for an unreadable value and
a fabricated `AggRow` for a wrong column count — then re-sorts rows in Haskell and shapes
them with a per-endpoint point function. For funnels that is `funnelPoint`, which splits the
`group_key` on `|` into group keys `"index"` and `"step"`. **The output shape
`MetricResult { metric, points = [MetricPoint { bucket, group = {"step": ..., "index": ...},
value }] }` is the public contract and must not change in this plan.**

### Which metric reads which source (write this understanding into the code comments too)

After EP-12, the metric families read from three kinds of sources with three different
accuracy characters, and a novice reading `Query.hs` should be able to tell which is which:

*Approximate, pre-aggregated:* `active_users` at day grain reads `analytics.dau`, at week
grain `analytics.wau`. Under EP-12 these store `uniqCombined`-family states (v1 used
`uniqExactState`), so the builders merge with `uniqCombinedMerge(users)` (v1:
`uniqExactMerge`) and the counts are *approximate* — `uniqCombined`'s relative error is
about 0.8 percent at large cardinalities. This is an accepted, documented property of
`active_users`: the number is a sketch, labeled as such in the metric description, in
exchange for join-free insert-time rollups.

*Exact but replay-sensitive, pre-aggregated:* `page_views` at day grain reads
`analytics.page_views_by_route` merging `countMerge(views)` under EP-12 (v1 stored
`uniqExact(event_id)` states, which deduplicated replayed inserts; a plain count no longer
does). Whether replay-dedup is preserved some other way is EP-12's decision — read its plan
and record the answer here; the builder simply uses whatever merge function EP-12's state
type requires.

*Exact, identity-stitched, row-level:* `uniqueUsersSQL` (unique-count metrics like
`new_users`), `buildRetentionSQL`, `buildFunnelSQL`, and both sides of every ratio metric
(`buildRatioSQL`) read `analytics.events_resolved` — after EP-12 a FINAL-free source that
maps every event to its `canonical_user` (the stitched identity: user id if present, else
the identity-map resolution of the anonymous id, else the anonymous id). These are exact.

*Raw identity, row-level:* `countEventsSQL` (the `events` metric), `propertyAggregateSQL`
(`revenue`), and `buildSessionsSQL` read `analytics.events_raw` directly; `events` stays
exact under replay because it counts `DISTINCT event_id`.

### Terms used below

*Charset validation* — accepting a string only if every character is in a fixed safe set and
the length is bounded; here `^[a-z0-9_.:-]{1,128}$` (anchored regex notation; implemented as
a total Haskell predicate, no regex library). This set covers every real event name in the
codebase — the fixtures and registry use `page_view`, `signup_started`, `signup_completed`,
`feature_used`, `user_registered`, `account_created`, `payment_completed`,
`onboarding_completed`, `search_performed`, `session_start`, `subscription_started`,
`identify`, `alias` (see `kansoku-api/src/Kansoku/Event/Registry.hs` and
`kansoku-core/src/Kansoku/Metrics/Registry.hs`) — while excluding quotes, backslashes,
whitespace, and every SQL metacharacter, so a validated name cannot terminate a string
literal or smuggle syntax regardless of any escaping bug.

*`windowFunnel`* — a ClickHouse aggregate function:
`windowFunnel(window)(timestamp, cond1, cond2, ...)` returns, per aggregation group, the
length of the longest prefix of conditions matched *in order* by that group's events, with
the whole chain fitting inside `window` time units of the chain's first event. Grouping by
user and asking `countIf(level >= n)` gives "users who reached step n in order" in a single
pass. The window unit follows the timestamp column's tick — hence `toDateTime(occurred_at)`
(seconds) in our SQL, because `occurred_at` is `DateTime64(3)` (milliseconds).

*MultilineStrings* — a GHC 9.12 extension (already in `kansoku-core.cabal`
`default-extensions`) allowing `"""..."""` literals with indentation stripping. The repo
standard (`/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/core/multiline-strings.md`) prefers
it over `Text.unlines` lists for embedded SQL. Builders rewritten by this plan adopt it;
builders this plan does not otherwise touch keep their current style. Note a difference that
matters for golden tests: `Text.unlines` appends a trailing newline, a `"""` literal does
not — update the affected `QuerySpec` goldens accordingly.


## Plan of Work

The work is four milestones. Each is independently verifiable, keeps `cabal test` green, and
ends in a conventional commit carrying the two trailers shown in Concrete Steps.


### Milestone 1 — Input validation at the HTTP boundary, plus the parameterization investigation

Scope: no user-derived string reaches a SQL builder unvalidated, and the question "can we use
ClickHouse native query parameters instead of/in addition to validation?" is answered with
evidence. At the end of this milestone, a funnel request with a hostile step returns HTTP 400
naming the value, and a new test module proves the validator's accept/reject behavior.

Create `kansoku-core/src/Kansoku/Query/Validate.hs` (add to `exposed-modules` in
`kansoku-core/kansoku-core.cabal`). It defines an opaque newtype and a smart constructor —
the *only* way to obtain the type — so the type system, not discipline, guarantees builders
receive validated names:

```haskell
-- | A name (event name, funnel step) proven safe to splice into SQL:
-- non-empty, at most 128 chars, every char in [a-z0-9_.:-].
newtype SqlName = SqlName Text
  deriving stock (Generic, Eq, Ord, Show)

mkSqlName :: Text -> Either Text SqlName
renderSqlName :: SqlName -> Text
```

`mkSqlName` returns `Left value` (the offending input, for the error body) unless
`Text.length value >= 1 && Text.length value <= 128` and
`Text.all (\c -> isAsciiLower c || isDigit c || c `elem` ("_.:-" :: String)) value`. Use
`Data.Char` predicates; do not add a regex dependency. Follow the repo code standards
(GHC2024, `Kansoku.Prelude`, postpositive qualified imports, strict fields where fields
exist, explicit deriving).

Change `Kansoku.Query` so `runFunnel` and `buildFunnelSQL` take `[SqlName]` instead of
`[Text]`, and so `eventNamePredicate`/`eventNameClause` render registry names through
`mkSqlName` as a belt-and-braces guard: registry names are trusted (they are literals in
`Kansoku/Metrics/Registry.hs`), so a registry name failing validation is a programmer error —
`error` with a message naming the metric is acceptable there, and a new registry test makes
it unreachable: in `kansoku-core/test/Kansoku/QuerySpec.hs` (or a new `ValidateSpec`),
assert that every `eventNames` entry of every metric in `builtinMetrics` (including ratio
numerators and denominators) satisfies `mkSqlName`.

In the funnel handler (`funnelHandler` in `kansoku-core/src/Kansoku/Metrics/Handler.hs`, or
its EP-9 slice location), validate each CSV piece with `mkSqlName` before calling
`Query.runFunnel`. On failure, throw the existing `jsonError err400` shape with message
`"invalid funnel step"` and details `{"step": <offending value>}`. Keep the existing empty-
list 400. Also audit the other user inputs and leave a comment trail: `groupBy` is already
safe because `groupExpr` is a closed whitelist (`event_name`/`source`/`route` map to fixed
SQL, everything else to `''`); `timeGrain` is a parsed enum; `from`/`to` are `Day` values
rendered by `formatTime` (digits and dashes only); retention `days` are parsed `Int`s. State
in a module comment on `Validate.hs` that funnel `steps` was the only raw-Text-to-SQL path.

Add tests: `kansoku-core/test/Kansoku/Query/ValidateSpec.hs` (register in the cabal
`other-modules` and in `test/Spec.hs` if discovery is manual — check how `Spec.hs`
enumerates; it may use hspec-discover) asserting acceptance of `page_view`,
`signup_completed`, `a`, `x.y:z-1`, and a 128-char name; rejection of the empty string, a
129-char name, `Robert'); DROP TABLE analytics.events_raw;--`, `page view`, `PageView`,
`page_view\`, and a name containing a newline. For the HTTP 400 path, add
`kansoku-core/test/Kansoku/Metrics/HandlerSpec.hs` using `Network.Wai.Test` (add `wai-extra`
and `http-types` to the test suite's `build-depends`): build the app as
`metricsApp (error "Connection must not be forced by a 400 request")` — the `Connection` is
only demanded on the query path, so a request rejected at validation never forces it — and
assert that `GET /metrics/funnel?from=2026-06-01&to=2026-06-08&steps=ok_step,bad'step`
yields status 400 and a body containing `bad'step`. If the placeholder trick proves fragile
(e.g. a strictness annotation appears later), fall back to unit-testing a pure
`validateSteps :: Text -> Either Text [SqlName]` helper extracted from the handler and cover
the 400 wiring with the Milestone 2 curl transcript instead; record the choice in the
Decision Log.

**Prototyping step — ClickHouse native query parameters through ClickHaskell.** This is an
investigation with a recorded verdict, not necessarily shipped code. ClickHouse supports
server-side parameters: `SELECT ... WHERE event_name = {step1:String}` with values shipped
out-of-band, immune to injection by construction. The question is whether the ClickHaskell
client (the library behind `Kansoku.ClickHouse`; source at
`/Users/shinzui/Keikaku/hub/haskell/clickhaskell-project/ClickHaskell/library/` — use
`mori registry show` to confirm the pinned checkout) can send them on the SELECT path used by
`Kansoku.Query` (`select` + `unsafeMkSelect`). Steps:

1. Read `ClickHaskell/Statements.hs`: find `Parameters`, `parameter`, `viewParameters`.
   Observe they exist to render *parameterized view calls* — `fromView` produces
   `SELECT ... FROM viewName(a3='a3Val', ...)` by splicing `toQueryPart` renderings (which
   quote-and-escape `'` and `\`, i.e. the same class of hand escaping we are eliminating)
   into the query text. This is not protocol-level parameter passing.
2. Read `ClickHaskell/Protocol/Client.hs`: find `QueryPacket.parameters` and the
   `QueryParameters` type. At authoring time it is a zero-field stub hardcoded to serialize
   an empty string (see Surprises & Discoveries) — there is no way to attach values.
3. Grep the pinned version for any newer API (`git log`/`grep -rn "Parameter"` in the
   checkout). If genuinely supported for SELECT by the pinned version, promote the prototype:
   route all user-derived strings (funnel steps) through native parameters *and keep the
   charset validation* as belt and braces, and record the promotion in the Decision Log.
   **Expected outcome as of the 2026-07-15 corpus update (see Surprises & Discoveries):
   upstream commit `d372918` ships real support (`addParameter`, `passParameters`,
   revision-gated `params` in the query packet), but kansoku's `cabal.project` pin
   (`56efc1840d79c89c2a6ade3794932588b65febab`) predates it. The promotion path is
   therefore: bump the pin to a commit/tag ≥ `d372918`, rebuild, verify EP-11's decode and
   pooling behavior still holds against the new driver, prototype one parameterized SELECT
   (`SELECT ... WHERE event_name = {step1:String}` via `passParameters (addParameter
   "step1" ...)` on the `Select`), confirm the ClickHouse server accepts it over the native
   protocol (the `params` field is revision-gated — check the negotiated protocol revision
   against `DBMS_MIN_PROTOCOL_VERSION_WITH_PARAMETERS`), then convert the funnel-step and
   event-name sites.**
4. Only if the pin bump proves impractical (e.g. the newer driver breaks EP-11's landed
   decode paths in ways not quickly fixable), record the fallback verdict: charset
   validation is the sole defense for this plan, `sqlString` remains as a second layer for
   validated names and machine-generated date literals, and a follow-up issue tracks the
   pin bump.

Acceptance for M1: `cabal test` green including the new specs; the registry-conformance test
passes; the investigation verdict is written into Decision Log and Surprises & Discoveries.
(The live-server 400 transcript is part of Milestone 2's validation, once fixtures exist.)


### Milestone 2 — Ordered, single-pass funnel with `windowFunnel`, and the `window` parameter

Scope: replace the quadratic, order-blind funnel SQL with a single-pass ordered computation,
add the optional `window` query parameter, and prove ordered semantics against fixtures. At
the end, the funnel endpoint returns the same JSON shape as before, computed correctly.

First the API type. In `kansoku-api/src/Kansoku/Api/Metrics.hs` (or the NamedRoutes field
post-EP-9), extend the funnel route with `QueryParam "window" Int` (seconds) and a servant
`Description` combinator (import `Description` from `Servant.API`) explaining: "Users
counted at step N performed steps 1..N in order, all within `window` seconds of the chain's
first step. Defaults to the full from/to range, capped at 90 days." `Description` flows into
the OpenAPI document automatically via `Servant.OpenApi.toOpenApi` (check
`kansoku-core/test/Kansoku/OpenApiSpec.hs` for whether a golden document needs updating).
`kansoku-client` generates no metrics functions, so only the API package and OpenAPI change;
this is the additive wire-type change the MasterPlan's Integration Points expects to be
coordinated with EP-14/EP-15 — it touches only the funnel route, which neither of those
plans edits, but note the addition in whichever of their plans is In Progress.

In the funnel handler: compute the effective window. Let `rangeSeconds` = seconds from
`from 00:00:00` to `to 00:00:00` (`diffDays to from * 86400`). Effective window =
`min rangeSeconds 7776000` when the parameter is absent; when present and within
`1..7776000`, the given value; otherwise throw `jsonError err400 "invalid funnel window"`
with details naming the value and the accepted range. Pass the window to `Query.runFunnel`
(its signature gains an `Int`).

Rewrite `buildFunnelSQL :: QueryRequest -> Int -> [SqlName] -> Text` as a MultilineStrings
literal with spliced fragments. Target SQL, shown for steps
`signup_started, signup_completed`, window 604800, range 2026-06-01 to 2026-06-08:

```sql
SELECT
    '' AS bucket,
    concat(toString(step.1), '|', step.2) AS group_key,
    toFloat64(countIf(level >= step.1)) AS value
FROM
(
    SELECT
        canonical_user,
        windowFunnel(604800)(toDateTime(occurred_at), event_name = 'signup_started', event_name = 'signup_completed') AS level
    FROM analytics.events_resolved
    WHERE canonical_user != ''
      AND event_name IN ('signup_started', 'signup_completed')
      AND occurred_at >= '2026-06-01 00:00:00' AND occurred_at < '2026-06-08 00:00:00'
    GROUP BY canonical_user
)
ARRAY JOIN [(1, 'signup_started'), (2, 'signup_completed')] AS step
GROUP BY step
ORDER BY step.1
```

How it works, so the implementer can adapt it: the inner query makes one pass over
`events_resolved` (restricted to the requested range and to the step event names — the
`IN` prune matters for scan size), grouping by user; `windowFunnel` yields each user's
reached level (0 = never did step 1 inside a chain). The `ARRAY JOIN` fans each user row out
to one row per step tuple `(index, name)`, and `countIf(level >= step.1)` counts users whose
ordered progress reached at least that step. The output columns are exactly the
`bucket`/`group_key`/`value` contract, with `group_key` in the `index|step` format that
`funnelPoint` already splits — so `MetricResult` JSON is unchanged: points carry group keys
`"step"` and `"index"`, `bucket` null. Do not change `funnelPoint`. Every fragment spliced
into the literal is either machine-generated (`toString` of an `Int`, `renderDay` of a
`Day`) or a `renderSqlName`-rendered `SqlName` wrapped in `sqlString` — with the M1 charset,
`sqlString` on a `SqlName` is provably the identity plus quotes.

Semantics notes to preserve in a comment: `toDateTime(occurred_at)` is load-bearing (window
unit = timestamp tick; see Surprises & Discoveries); default-mode `windowFunnel` allows
equal-timestamp events to satisfy consecutive conditions in either order — acceptable for
analytics, do not add `'strict_increase'` in this plan; a repeated step name is legal SQL
(two identical conditions) and needs no special casing, but note that levels then mean
"did it twice in order".

Tests in `kansoku-core/test/Kansoku/QuerySpec.hs`: a golden (or `shouldContainText` set)
assertion on the two-step SQL above — at minimum assert the `windowFunnel(604800)(` prefix
with `toDateTime(occurred_at)`, the ordered condition list, the `ARRAY JOIN` tuple list, the
`countIf(level >= step.1)` expression, absence of `UNION ALL`, and presence of `ORDER BY`;
plus a three-step case checking indices `1,2,3` render in order. Build test inputs with
`mkSqlName` (pattern-match the `Right`).

Fixtures and end-to-end proof. `db/clickhouse/fixtures/ep6_fixtures.sql` (post-EP-12: match
whatever column list EP-12's rewrite of this file uses — it owns the file's v2 form; adding
rows here after it is Complete is coordinated and safe) gains an out-of-order user `u4` on
2026-06-03: `signup_completed` at 09:00:00 (event id `e10`), then `signup_started` at
10:00:00 (event id `e11`). With the v1 UNION-ALL funnel, u4 counts at step 2 (it only checks
set membership); with `windowFunnel`, u4's level is 1 (the chain starting at 10:00 finds no
later completion). Expected counts over 2026-06-01..2026-06-08 with steps
`signup_started,signup_completed`: step 1 = 3 (u1, u3, u4), step 2 = 1 (u1 only). The curl
transcript is in Validation and Acceptance.

Acceptance for M2: `cabal test` green; against a running server with fixtures loaded, the
funnel transcript matches (step 2 excludes u4), a hostile step returns the M1 400, and
`window=0` returns the new 400.


### Milestone 3 — Honest failures, dead-code cleanup, and rollup-source reconciliation

Scope: the query path can no longer manufacture plausible zeros, the redundant re-sort is
gone, and every builder agrees with EP-12's actual schema. Purely internal, demonstrated by
tests that fail before and pass after, plus unchanged end-to-end numbers.

(a) *Loud decoding.* This is conditional on EP-11's state — check
`kansoku-core/src/Kansoku/Query.hs` for `parseAggLine`. If EP-11 has landed, the tab-concat
wrapper, `AggLine`, and `parseAggLine` are already gone and decoding is typed and loud;
your job is only a guard: grep the query path (`Query.hs` and the handler module) for
`readMaybe`, `fromMaybe 0`, and catch-all fallbacks, and convert any survivor into a thrown
error. If EP-11 has *not* landed, `parseAggLine` still has two dishonest arms — `fromMaybe 0
(readMaybe ...)` for an unreadable value and a fabricated `AggRow` for a wrong field count.
Define in `Query.hs`:

```haskell
newtype QueryDecodeError = QueryDecodeError Text
  deriving stock (Show)

instance Exception QueryDecodeError
```

and make both arms `throwIO (QueryDecodeError <detail including the raw line>)` (thread `IO`
through by parsing inside `runSQLWith`'s `IO`, e.g. `traverse parseAggLine` with
`parseAggLine :: AggLine -> IO AggRow`). The existing `effToHandler` catches `SomeException`
and returns HTTP 503 with an error body — a loud failure the client can see, versus a silent
zero on a dashboard. State in the Decision Log which branch applied. (The MasterPlan forbids
reintroducing string-splitting decode paths; this plan must not add any.)

(b) *Delete the re-sort.* In `runSQLWith`, remove `List.sortOn sortKey` (and the now-unused
`sortKey`, and the `Data.List` import if nothing else uses it), keeping ClickHouse's `ORDER
BY` as the single ordering authority. Add/keep a `QuerySpec` assertion that every builder's
output contains `ORDER BY` (a simple property over a list of representative builder outputs).

(c) *Sessions predicate for v2.* Post-EP-12, `session_id` is `String DEFAULT ''`, not
`Nullable(String)`. EP-12's minimal edit already dropped `isNotNull(session_id)`; this plan
takes ownership of `buildSessionsSQL` wholesale — confirm the predicate is exactly
`session_id != ''`, convert the builder to a MultilineStrings literal, and update the
`QuerySpec` golden (which at authoring time still asserts the `isNotNull` line and a
`Text.unlines` trailing newline).

(d) *Rollup readers.* Reconcile `activeUsersDaySQL`, `activeUsersWeekSQL`, and
`pageViewsDaySQL` (both branches) with EP-12's landed state types: expected
`uniqCombinedMerge(users)` for dau/wau and `countMerge(views)` for page views — but read
EP-12's migration files for the authoritative names and record any difference. Update the
`QuerySpec` goldens (the `uniqExactMerge` assertions become the new merge functions). Then
write the metric→source mapping as a documentation comment block in `Query.hs` mirroring the
prose in this plan's Context section — exact vs approximate (~0.8% for `uniqCombined`) vs
raw — and update the `active_users` metric `description` in
`kansoku-core/src/Kansoku/Metrics/Registry.hs` to end with "(approximate; uniqCombined
sketch, ~0.8% relative error)" so the label reaches API consumers via the metric catalog.

Acceptance for M3: `cabal test` green with updated goldens; a deliberate local mutation test
— temporarily point `unsafeSelect` at a wrapper emitting a non-numeric `value` (or, post-
EP-11, feed a mistyped row in a unit test) — yields an exception/503, not zeros (revert the
mutation; it is evidence, not shipped code); end-to-end `active_users` and `page_views`
curls return plausible non-zero numbers against fixtures.


### Milestone 4 — Retention labeling, documentation, and the full pass

Scope: retention behavior is unchanged but honestly named everywhere a consumer might look,
and the whole plan's validation suite runs clean.

In the API type (`kansoku-api/src/Kansoku/Api/Metrics.hs` or the NamedRoutes field), add a
`Description` to the retention route: "Retention over new-in-window cohorts: a user's cohort
day is their first activity within the requested from/to window (users active before the
window re-appear as new). Offset 0 (the cohort day itself) is always included." Confirm via
the OpenAPI document (see Concrete Steps) that the description appears; `Kansoku/OpenApi.hs`
itself needs no change (descriptions attach in the API type; that file only holds schema
instances and document metadata).

In `Query.hs`, document `buildRetentionSQL` with a comment naming the semantics
("new-in-window cohorts — `first_seen` is `min(day)` *within the requested window* by
design; changing to lifetime cohorts requires a first-seen rollup and is out of scope") and
document `normalizeOffsets` — it always injects offset 0 so the cohort-size denominator
row exists for every cohort, and deduplicates/drops negatives — as intended behavior, with
the existing `QuerySpec` assertion (`IN (0,1,7,14,30)`) kept as the pin.

Then the full pass: `just build`, `cabal test`, and the complete curl transcript set in
Validation and Acceptance against freshly loaded v2 fixtures. Update every living section of
this plan, mark the MasterPlan registry row for EP-13 Complete, and tick the three EP-13
progress bullets in the MasterPlan's Progress section.

Acceptance for M4: transcripts recorded; OpenAPI document contains both new descriptions and
the `window` parameter; all Progress boxes above are checked.


## Concrete Steps

All commands run from the repository root
(`/Users/shinzui/Keikaku/bokuno/kansoku-project/kansoku`) inside `nix develop`.

Environment bring-up (idempotent; reuse a running process-compose):

```bash
just up                # in its own terminal: postgres, clickhouse, create_schema
just ch-migrate        # applies db/clickhouse/migrations/*.sql via EP-12's mechanism
just ch-fixtures-ep6   # loads the v2 fixtures (EP-12's rewrite + this plan's u4 rows)
cabal run kansoku-server   # in its own terminal; listens on :8080
```

Note: EP-12 replaces the "apply every file in filename order" `ch-migrate` recipe with a
versioned mechanism — use whatever `just` recipe EP-12's plan documents if `ch-migrate` has
changed.

Build and test loop:

```bash
cabal build all
cabal test
```

Expected test output ends with all specs passing, e.g.:

```text
Finished in 0.0xx seconds
NN examples, 0 failures
Test suite kansoku-core-test: PASS
```

Inspect generated funnel SQL by hand while developing (fastest feedback — paste the output
of `buildFunnelSQL` from a `cabal repl kansoku-core` session into `clickhouse-client`):

```bash
clickhouse-client --port $CLICKHOUSE_TCP_PORT --query "
SELECT '' AS bucket, concat(toString(step.1), '|', step.2) AS group_key,
       toFloat64(countIf(level >= step.1)) AS value
FROM (
  SELECT canonical_user,
         windowFunnel(604800)(toDateTime(occurred_at),
           event_name = 'signup_started', event_name = 'signup_completed') AS level
  FROM analytics.events_resolved
  WHERE canonical_user != ''
    AND event_name IN ('signup_started', 'signup_completed')
    AND occurred_at >= '2026-06-01 00:00:00' AND occurred_at < '2026-06-08 00:00:00'
  GROUP BY canonical_user
)
ARRAY JOIN [(1, 'signup_started'), (2, 'signup_completed')] AS step
GROUP BY step ORDER BY step.1"
```

Expected (with the u4 fixture rows loaded):

```text
	1|signup_started	3
	2|signup_completed	1
```

Commit after each milestone with conventional-commit messages carrying both trailers, for
example after M2:

```text
feat(query): compute funnels with ordered single-pass windowFunnel

Adds an optional `window` seconds parameter to /metrics/funnel (default:
request range, capped at 90 days) and rewrites buildFunnelSQL from N
UNION ALL branches with correlated subqueries to one windowFunnel pass.

MasterPlan: docs/masterplans/2-kansoku-production-hardening-review-fixes-and-portfolio-service-readiness.md
ExecPlan: docs/plans/13-safe-and-correct-metric-sql-validated-inputs-ordered-funnels-honest-failures.md
```

Suggested commit subjects: M1 `feat(query): validate metric names and funnel steps against a
strict charset`; M3 `fix(query): fail loudly on decode errors and read v2 rollup states`;
M4 `docs(api): label retention as new-in-window cohorts`.


## Validation and Acceptance

With the environment up (previous section) and fixtures loaded, the following transcripts
define acceptance. Dates match the fixture data (June 2026).

Injection rejected (M1) — note the URL-encoded quote in the second step:

```bash
curl -si "http://localhost:8080/metrics/funnel?from=2026-06-01&to=2026-06-08&steps=signup_started,signup%27--"
```

```text
HTTP/1.1 400 Bad Request
content-type: application/json

{"details":{"step":"signup'--"},"error":"invalid funnel step"}
```

Ordered funnel (M2) — u4 performed `signup_completed` *before* `signup_started`, so step 2
counts only u1:

```bash
curl -s "http://localhost:8080/metrics/funnel?from=2026-06-01&to=2026-06-08&steps=signup_started,signup_completed" | jq .
```

```json
{
  "metric": "funnel",
  "points": [
    { "bucket": null, "group": { "index": "1", "step": "signup_started" }, "value": 3 },
    { "bucket": null, "group": { "index": "2", "step": "signup_completed" }, "value": 1 }
  ]
}
```

(Before this plan, the same request reported `"value": 2` for step 2 — u4 counted despite
the wrong order. If you run the old code against the new fixtures first, capture that output
here as the failing baseline.)

Window parameter validated (M2):

```bash
curl -si "http://localhost:8080/metrics/funnel?from=2026-06-01&to=2026-06-08&steps=signup_started,signup_completed&window=0" | head -1
```

```text
HTTP/1.1 400 Bad Request
```

A tight explicit window changes the count honestly (u1's steps are 5 minutes apart, so
`window=60` drops step 2 to 0 — adjust expectation if fixture timings differ):

```bash
curl -s "http://localhost:8080/metrics/funnel?from=2026-06-01&to=2026-06-08&steps=signup_started,signup_completed&window=60" | jq '.points[1].value'
```

```text
0
```

Sessions, active users, page views against v2 sources (M3) — values must be non-zero and
stable across repeated runs (the duplicate `e2` fixture row must not inflate `events`):

```bash
curl -s "http://localhost:8080/metrics/sessions?from=2026-06-01&to=2026-06-08" | jq '[.points[].value] | add'
curl -s "http://localhost:8080/metrics/users?from=2026-06-01&to=2026-06-08" | jq .
curl -s "http://localhost:8080/metrics/page-views?from=2026-06-01&to=2026-06-08" | jq .
```

Retention labeled, behavior unchanged (M4):

```bash
curl -s "http://localhost:8080/metrics/retention?from=2026-06-01&to=2026-06-08&days=1" | jq '.points[0].group'
```

```json
{ "cohort": "2026-06-01", "offset": "0" }
```

and the OpenAPI document (generate it however `kansoku-core/test/Kansoku/OpenApiSpec.hs` or
the server exposes it — e.g. `cabal repl kansoku-core` then
`Data.Aeson.encode Kansoku.OpenApi.openApiDoc`) contains the string
"new-in-window cohorts" on the retention operation and a `window` parameter on the funnel
operation.

Test-level acceptance: `cabal test` green; `ValidateSpec` covers accept/reject cases
including the injection payloads; `QuerySpec` asserts the `windowFunnel` shape, absence of
`UNION ALL` in funnel SQL, the `session_id != ''` predicate, the v2 merge functions, and
`ORDER BY` in every builder output; the registry-conformance test passes; `HandlerSpec` (if
the WAI approach was kept) proves the 400 path without a ClickHouse connection.


## Idempotence and Recovery

Everything here is safe to repeat. `just ch-fixtures-ep6` re-inserts fixture rows, but
`analytics.events_raw` is a ReplacingMergeTree keyed on `event_id` (last in the v2 sort
key), so re-loading fixtures does not change query results (the file's `OPTIMIZE ... FINAL`
collapses duplicates eagerly; `events_resolved` reads are duplicate-safe by design). Reset
ClickHouse entirely by stopping process-compose, deleting its ClickHouse data directory (see
`process-compose.yaml`'s `$CLICKHOUSE_HOME`), and re-running bring-up.

This plan adds no migrations and changes no storage, so there is nothing to roll back in the
database; every change is Haskell source and one fixture append, reverted with git. If a
milestone is interrupted, `cabal test` tells you which goldens disagree with the code; the
Progress section must be updated to say exactly which sub-steps are done. The M3 mutation
test (forcing a decode failure) must never be committed — it is a local observation only.

If EP-12's landed schema differs from this plan's assumptions (merge function names, view
shape, fixture column list), do not force this plan's SQL onto it: update the builders to
match reality, record the delta in Surprises & Discoveries, and if the delta is a contract
break (e.g. `events_resolved` lost `canonical_user`), stop and escalate to the MasterPlan
level before proceeding.


## Interfaces and Dependencies

Libraries: no new library dependencies for `kansoku-core`'s library component; the test
suite adds `wai-extra` and `http-types` (both in nixpkgs' Haskell set and the cabal index —
if the freeze/flake refuses them, use the documented fallback of pure-function 400 tests).
ClickHaskell remains the client (pinned checkout at
`/Users/shinzui/Keikaku/hub/haskell/clickhaskell-project/`; confirm with `mori registry
show`). ClickHouse features used: `windowFunnel`, `ARRAY JOIN` over an array of tuples,
`countIf`, and the EP-12 merge functions (`uniqCombinedMerge`, `countMerge`) — all present
in any ClickHouse recent enough to run the v2 schema.

Module contracts at end of plan (post-EP-11 signatures may replace `Connection` with EP-11's
pool/handle type — accept whatever exists and note it in the Decision Log):

```haskell
module Kansoku.Query.Validate
  ( SqlName,            -- opaque; constructor NOT exported
    mkSqlName,          -- :: Text -> Either Text SqlName
    renderSqlName,      -- :: SqlName -> Text
  )

module Kansoku.Query
  ( QueryRequest (..),
    QueryDecodeError (..),  -- only if the pre-EP-11 decode path still exists
    buildSQL,               -- :: BuiltinMetric -> QueryRequest -> Text
    buildFunnelSQL,         -- :: QueryRequest -> Int -> [SqlName] -> Text
    buildRetentionSQL,      -- :: QueryRequest -> [Int] -> Text
    buildSessionsSQL,       -- :: QueryRequest -> Text
    run, runSessions, runRetention,
    runFunnel,              -- :: (IOE :> es) => Connection -> QueryRequest -> Int -> [SqlName] -> Eff es MetricResult
  )
```

The funnel route type (in `kansoku-api/src/Kansoku/Api/Metrics.hs`, flat chain or NamedRoutes
field) ends the plan as:

```haskell
"metrics" :> "funnel"
  :> Description "Users counted at step N performed steps 1..N in order within `window` seconds of the chain's first step. Default window: the full from/to range, capped at 90 days (7776000 s)."
  :> QueryParam' '[Required] "from" Day
  :> QueryParam' '[Required] "to" Day
  :> QueryParam' '[Required] "steps" Text
  :> QueryParam "window" Int
  :> Get '[JSON] MetricResult
```

Services: ClickHouse and Postgres via `process-compose up`; the schema and rollups are
EP-12's objects (`analytics.events_raw`, `analytics.events_resolved`, `analytics.dau`,
`analytics.wau`, `analytics.page_views_by_route`); this plan reads them and owns none.
The JSON contract consumed by future dashboards — `MetricResult` with funnel group keys
`"step"`/`"index"` and retention group keys `"cohort"`/`"offset"` — is unchanged.

---

Revision note (2026-07-15, same day as authoring): the authoring-time finding "ClickHaskell
query parameters are a protocol stub" was superseded — the local corpus checkout was stale,
and the updated upstream ships real protocol-level parameter support (commit `d372918`,
"Feature: query parameters support (#471)"). Milestone 1's investigation step now expects to
promote the prototype via a `cabal.project` pin bump (kansoku's pinned tag predates the
feature), native parameters become the primary injection defense with charset validation
retained as defense-in-depth, and the Progress checklist, Decision Log, and Surprises &
Discoveries were updated accordingly. The validation-only outcome remains documented as the
fallback if the pin bump proves impractical.
