---
id: 19
slug: experiment-analytics-assignment-events-variant-rollups-and-per-variant-metrics
title: "Experiment analytics: assignment events, variant rollups, and per-variant metrics"
kind: exec-plan
created_at: 2026-07-15T21:43:59Z
intention: intention_01kxxscv06exbvqdtefzqnf9h5
master_plan: "docs/masterplans/3-kansoku-analytics-extensions-queryable-properties-multi-signal-identity-and-experiment-analytics.md"
---

# Experiment analytics: assignment events, variant rollups, and per-variant metrics

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

kikan products will run A/B experiments: a product shows some users a "control" experience
and other users a "treatment" experience, and the team wants to know which one converts
better. Today kansoku can *capture* an experiment event — any JSON payload lands in the
`properties` blob of `analytics.events_raw` — but it cannot *answer* the question every
experiment produces: "how many users saw each variant, and which variant converts better?"
There is no declared contract for what an experiment event looks like, no pre-aggregated
exposure data, and no metrics endpoint that breaks a number down by variant.

After this plan, three things are true and demonstrable with `curl`:

1. **Exposure events are a declared contract.** The event registry declares an
   `experiment_viewed` event schema with required, charset-validated string properties
   `experiment` and `variant`. An event missing them, or carrying values outside the safe
   charset, is rejected at ingest with a validation error naming the problem.
2. **Exposures roll up by experiment × variant × day.** A new ClickHouse rollup table
   `analytics.experiment_exposures` (fed by a materialized view over `analytics.events_raw`)
   holds unique-user sketches keyed on `(account_id, experiment, variant, day)`, so the
   highest-frequency dashboard question costs a rollup read, not a raw-table scan.
3. **The metrics API answers per-variant questions.** Three new authenticated,
   account-scoped endpoints serve exposure counts
   (`GET /metrics/experiments`), per-variant conversion — exposed users, users who converted
   *after* their first exposure, and the rate (`GET /metrics/experiments/conversion`) — and
   per-variant ordered funnels (`GET /metrics/experiments/funnel`). A user who performed the
   conversion event *before* being exposed does not count as converted, and the fixture
   story proves it.

To see it working: start dev services, apply migrations, ingest the fixture exposures and
purchases for experiment `checkout_v2` (variants `control`/`treatment`) for two accounts,
then `curl 'http://localhost:8080/metrics/experiments/conversion?experiment=checkout_v2&event=purchase_completed&from=2026-08-01&to=2026-08-08'`
with account A's token and read `control` converting at 0.2 and `treatment` at 0.6 — with
account B's token, the same request shows only account B's data. Exact transcripts are in
Validation and Acceptance.

**Scope honesty:** this plan ships counts and rates, **not** statistical significance. There
are no p-values, no confidence intervals, no "winner" determination. Two rates alone do not
tell you whether a difference is real or noise; significance testing is deliberately
deferred to a future dashboard/statistics layer (see Decision Log). The API returns the raw
material for a decision, not the decision.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-07-19 13:48 PDT) M1: EP-17's recorded property representation read and copied into this plan's
      Surprises & Discoveries (the exact ClickHouse expressions for `experiment`/`variant`)
- [x] (2026-07-19 13:59 PDT) M1: `PropertySpec` gains `propPattern`; `PropertyPattern`/`SqlNamePattern` defined;
      existing registry entries updated
- [x] (2026-07-19 13:59 PDT) M1: `experiment_viewed` schema registered in the in-code registry,
      because EP-20's versioned registry has not landed
- [x] (2026-07-19 13:59 PDT) M1: `Kansoku.Event.Validation` enforces `propPattern`; new `InvalidPropertyValue`
      error; validation specs cover missing/mistyped/bad-charset properties
- [x] (2026-07-19 13:59 PDT) M1: charset-agreement test (kansoku-api pattern predicate ≡ `mkSqlName` acceptance)
- [x] (2026-07-19 13:59 PDT) M1: migration `0014_experiment_exposures.sql` written (table + backfill + MV) and
      applied; fixture file `db/clickhouse/fixtures/ep19_fixtures.sql` + `just` recipe added
- [x] (2026-07-19 13:59 PDT) M1: clickhouse-client and HTTP rejection transcripts captured — fixture rows appear in
      `analytics.experiment_exposures` with expected unique-user counts
- [x] (2026-07-19 14:14 PDT) M2: `buildExperimentExposuresSQL` + `buildExperimentConversionSQL` builders and
      runners in the query module; point functions; QuerySpec shape tests
- [x] (2026-07-19 14:14 PDT) M2: `experiments` and `experimentConversion` route fields added to `MetricsRoutes`;
      handlers wired; 400 paths (bad names, bad grain, event == exposure event) tested
- [x] (2026-07-19 14:14 PDT) M2: kansoku-client and `docs/api/openapi.json` regenerated in the same commit as the
      route change
- [x] (2026-07-19 14:14 PDT) M2: transcripts captured — exposures per day, conversion with the before-exposure
      user excluded, two-account isolation
- [x] (2026-07-19 14:26 PDT) M3: `buildExperimentFunnelSQL` builder, runner, point function;
      QuerySpec shape tests
- [x] (2026-07-19 14:26 PDT) M3: `experimentFunnel` route field, handler, client + OpenAPI
      regenerated same commit
- [x] (2026-07-19 14:26 PDT) M3: per-variant funnel transcript captured; full `cabal test` +
      end-to-end pass
- [x] (2026-07-19 14:26 PDT) M3: MasterPlan 3 registry row and Progress bullets for EP-19
      updated; Outcomes written


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-07-19: Implementation-start reconciliation found the fully landed vertical-slice
  tree: the API is `Kansoku.Metrics.Api` with authenticated `MultiVerb` results, handlers
  receive `AuthenticatedPrincipal`, and `QueryRequest.accountId` becomes the native
  `{account_id:String}` query parameter. EP-17 stores raw `properties` as a JSON-encoded
  `String` and materializes `properties_json JSON`; reads use
  `toString(getSubcolumn(properties_json, 'experiment'))` and
  `toString(getSubcolumn(properties_json, 'variant'))`. Direct SQL fixtures must therefore
  provide valid JSON strings such as `'{"experiment":"checkout_v2","variant":"control"}'`
  plus `'{}'` for `context`. EP-18's `analytics.events_resolved` exposes the ordered
  seven-column contract including `account_id` and `properties_json`, verified by live
  `DESCRIBE`, so no compatibility view migration is needed. The ledger ends at `0013`;
  this plan claims `0014_experiment_exposures.sql`. EP-20 is not implemented, so the
  in-code `defaultRegistry` remains the schema source of truth.

- 2026-07-19: The clean baseline is `just build` plus `just test`: 109 core examples and
  10 client examples passed with zero failures; one opt-in live client example was pending.

- 2026-07-19: The authored migration sketch only guarded identities, while the Decision
  Log requires every stored experiment and variant read to exclude non-conforming legacy or
  direct-insert values. Migration `0014` therefore applies the same anchored
  `[a-z0-9_.:-]{1,128}` guards in both its backfill and materialized-view trigger.

- 2026-07-19: The acceptance fixture dates (2026-08-01) were still in the future at
  implementation time, and the ingest handler correctly adds a future-time rejection.
  The isolated HTTP validation transcript used 2026-07-19 timestamps so it pins only the
  intended bad-pattern and missing-property failures; the direct ClickHouse fixture retains
  the plan's August dates for stable analytics queries.

- 2026-07-19: The M2 live integration pass found an insert-block-specific ClickHouse 26
  behavior that the mixed direct fixture had hidden. When a Haskell insert block contains
  no experiment property paths, `toString(getSubcolumn(...))` can remain `Dynamic` while
  the materialized view analyzes its `GROUP BY`, causing error 44 before the event-name
  filter discards the rows. Migration `0015_experiment_exposure_string_casts.sql` preserves
  immutable, already-applied `0014` and recreates only the MV with an explicit outer
  `CAST(..., 'String')`. A fresh migration replay plus all ordinary insert tests then passed.

- 2026-07-19: Deriving a metrics client for the full `MetricsRoutes` record revealed that
  `TimeGrain` had server-side `FromHttpApiData` but no client-side `ToHttpApiData` instance.
  Adding the inverse instance made the shared query type bidirectional; the client test
  observed the derived `timeGrain=day` request over a real Warp listener.


## Decision Log

Record every decision made while working on the plan.

- Decision: Experiment analysis is **exposure-based**, not assignment-based. The declared
  event is `experiment_viewed`, emitted when a user is actually *shown* a variant; a
  server-side assignment that never renders is not an analytics event in this contract.
  Rationale: Including assigned-but-never-exposed users dilutes the measured effect toward
  zero — those users' outcomes cannot depend on a treatment they never saw, so they add
  noise to both arms and shrink the observed difference. Exposure-based denominators measure
  the effect on users who could have been affected. (The name follows the Segment
  "Experiment Viewed" convention, rendered `experiment_viewed` in kansoku's snake_case.)
  Date: 2026-07-15

- Decision: The rollup counts **raw identities** — `user_id` if present, else
  `anonymous_id` — not stitched canonical users; the exact stitched numbers stay available
  from the query-time endpoints (conversion, funnel) which read
  `analytics.events_resolved`.
  Rationale: A ClickHouse materialized view runs at insert time, per inserted block;
  identity resolution in this system is query-time by design (EP-12,
  `docs/plans/12-clickhouse-schema-v2-sort-key-final-free-resolution-join-free-rollups.md`,
  removed the insert-time identity join from dau/wau precisely because it froze stale
  resolutions and scaled insert cost with total identities). This rollup follows the same
  join-free idiom. The approximation is documented honestly in the endpoint description:
  a user exposed anonymously and later identified counts twice in the rollup, once per raw
  identity.
  Date: 2026-07-15

- Decision: A user counts as **converted** only if a conversion event exists at or after
  their **first exposure** to the experiment (`max(conversion_time) >= min(exposure_time)`;
  ties count as converted). Users who performed the conversion event only *before* exposure
  are exposed-but-not-converted.
  Rationale: "Variant X converts better" is a causal claim about what happened after the
  user saw X; pre-exposure conversions cannot have been influenced by it. Ties count because
  same-batch events legitimately share a timestamp (millisecond resolution), matching the
  leniency of `windowFunnel`'s default mode established in EP-13.
  Date: 2026-07-15

- Decision: **No significance testing** in this plan — no p-values, confidence intervals,
  sample-size checks, or winner calls; the API serves exposure counts, conversion counts,
  and rates only.
  Rationale: Doing statistics honestly requires decisions this service should not make
  unilaterally (test choice, multiple-comparison policy, peeking correction, minimum
  detectable effect), and doing it dishonestly — printing two rates next to a checkmark —
  invites bad ship decisions. Deferred to the future dashboard/statistics layer, which can
  compute intervals from the counts this API already returns.
  Date: 2026-07-15

- Decision: An unknown-but-well-formed experiment name returns **HTTP 200 with an empty
  `points` list**, not 404. HTTP 400 is reserved for malformed input: names or steps
  failing charset validation, missing required parameters (servant produces these),
  `timeGrain=hour` on the exposures endpoint, funnel `window` out of range, and a
  conversion `event` equal to `experiment_viewed`.
  Rationale: Experiments are not addressable resources in this API — they are values in
  event data, and "no data yet" is an ordinary analytics answer (a dashboard polling before
  the first exposure arrives should render zeros, not error). 400-vs-200 is decided purely
  by *syntax*, which keeps the contract predictable and cache-friendly.
  Date: 2026-07-15

- Decision: The per-variant funnel counts only events **at or after the user's first
  exposure**, mirroring the conversion endpoint's ordering rule.
  Rationale: Consistency — a funnel whose step 1 predates exposure would contradict the
  conversion endpoint on the same data. The plain (experiment-free) funnel from EP-13 stays
  available for non-experiment questions.
  Date: 2026-07-15

- Decision: Registry property validation is extended generically — `PropertySpec` gains an
  optional `propPattern :: Maybe PropertyPattern` with one pattern, `SqlNamePattern`
  (non-empty, ≤ 128 chars, all of `[a-z0-9_.:-]`) — instead of special-casing
  `experiment_viewed` inside `Kansoku.Event.Validation`.
  Rationale: EP-17 (property grouping) and EP-20 (versioned registry) both benefit from a
  declarative "this property is a safe name" marker; a special case would be repeated
  by the next plan that needs it. The pattern deliberately equals EP-13's `mkSqlName`
  charset so ingest-accepted values are query-safe by construction; a test pins the two
  predicates together.
  Date: 2026-07-15

- Decision: SQL that reads `experiment`/`variant` **values out of stored data** guards them
  with `match(x, '^[a-z0-9_.:-]{1,128}$')`, and the wire encoding of composite group keys
  places the only data-derived component (`variant`) last.
  Rationale: The contract charset is enforced at ingest from this plan onward, but rows
  ingested before the contract (or through a registry bug) could contain arbitrary strings,
  including the `|` separator the row decoder splits on. The `match` guard means the
  endpoints serve only contract-conforming names, so decoding is unambiguous and hostile
  historical data cannot corrupt group keys.
  Date: 2026-07-15

- Decision: A user observed with exposures to **multiple variants** of the same experiment
  counts in each variant they saw.
  Rationale: A correctly implemented experiment assigns one variant per user, so this is a
  data-quality signal, not a modeling choice; silently attributing the user to one variant
  would hide the bug. The endpoint description documents this behavior. Detecting and
  reporting cross-variant contamination is future dashboard scope.
  Date: 2026-07-15

- Decision: Implement against the landed `Kansoku.Metrics.*` modules, `MultiVerb` response
  family, `QueryRequest.accountId` parameter path, native-JSON `getSubcolumn` expressions,
  and in-code registry; use migration number `0014`.
  Rationale: EP-17 and EP-18 are complete, EP-20 is not, and the live schema and baseline
  tests verify these are the current contracts. Replacing the authored placeholders now
  keeps the plan restartable from the actual tree.
  Date: 2026-07-19

- Decision: Bind `experiment` and conversion `event` through native ClickHouse parameters,
  even after `mkSqlName` validation, and derive a small `Kansoku.Client.Metrics` module from
  the complete shared `MetricsRoutes` record.
  Rationale: Native parameters preserve the query/value boundary already established for
  accounts and built-in events. No metrics client existed, and Servant derives a record as
  a unit, so the module supplies one credential constructor plus typed exposure and
  conversion selectors now; M3 extends it with the funnel selector.
  Date: 2026-07-19

- Decision: Repair the exposure MV in additive migration `0015` rather than editing applied
  migration `0014`.
  Rationale: EP-12 makes applied migration files immutable. The correction is narrowly
  scoped to replacing the plan-owned MV with explicit String casts; the rollup table and
  its aggregate states remain intact, and fresh migration runs apply `0014` then `0015`
  before application traffic resumes.
  Date: 2026-07-19

- Decision: Adopt ADR 0006 as the durable owner of the experiment-analytics semantics:
  render-time exposure, raw-identity exposure rollups, exact query-time stitched conversion
  and funnel counts, post-exposure ordering, multi-variant counting, and no significance or
  winner calculation.
  Rationale: These rules span event producers, storage, three API endpoints, and future
  dashboard/statistics work. Keeping them in one accepted ADR prevents later consumers from
  inferring incompatible assignment or denominator semantics from an endpoint name alone.
  Date: 2026-07-19


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

Milestone 1 completed on 2026-07-19. The in-code event registry now declares
`experiment_viewed` as an exposure event with required, string-valued, SQL-safe
`experiment` and `variant` properties. Validation and `mkSqlName` agree over accepted and
rejected boundary samples. Migration `0014` creates an account-scoped daily
`uniqCombined` rollup, backfills it, and maintains it with a guarded materialized view.
The live fixture result was exactly `5/1/5/2`, migration replay skipped the recorded file,
and authenticated HTTP batches rejected both a bad variant and a missing variant while
returning the established partial-batch HTTP 202 envelope. `just build` and `just test`
passed (111 core examples, 10 client examples, one opt-in client example pending), and the
OpenAPI artifact remained unchanged as required for this non-wire milestone.

Milestone 2 completed on 2026-07-19. The authenticated API now serves daily/weekly/monthly
or whole-range exposure sketches and exact, identity-stitched per-variant conversion
counts/rates. All user-supplied names are validated and bound as native parameters; stored
group values remain guarded. The live HTTP result for account A was control/treatment
exposures `5/5`, conversions `1/3`, and rates `0.2/0.6`, proving the pre-exposure `c2`
purchase is excluded. Account B saw only two control exposures and zero conversions;
an unknown valid experiment returned 200/empty, bad name/hour/same-event requests returned
400, and missing credentials returned 401. The new typed client selectors made the same
route shapes, OpenAPI documented both operations, and the complete pass reached 118 core
examples plus 11 client examples with zero failures (one opt-in client example pending).

Milestone 3 completed on 2026-07-19. The authenticated API and typed client now expose an
ordered per-variant funnel whose steps are restricted to each canonical user's
post-exposure timeline. Native parameters carry the experiment and step names, stored
property values retain charset guards, and the generated SQL preserves EP-13's
second-based `windowFunnel` behavior without `UNION ALL` or raw-string `JSONExtract`.
Fresh migrations through `0015`, direct fixtures, and a real server returned account A's
control funnel `1/1` and treatment funnel `4/3`; account B returned no funnel points, a
well-formed unknown experiment returned 200/empty, and invalid step/window requests
returned 400. The final suite passed 120 core examples and 11 client examples with zero
failures (one opt-in live client example pending). ADR 0006 now records the cross-plan
exposure and attribution contract; all three milestones and both MasterPlan EP-19 progress
items are complete.


## Context and Orientation

Kansoku is a Haskell analytics service: GHC 9.12.4, a nix flake, four cabal packages —
`kansoku-api` (servant route types, event wire types, event registry and validation),
`kansoku-core` (domain logic, ClickHouse access, query compiler, handlers, server),
`kansoku-server` (the executable), `kansoku-client` (the Haskell SDK). Events arrive over
HTTP, are queued durably in Postgres (pgmq), and a batched writer inserts them into
ClickHouse table `analytics.events_raw`. Metrics are read back over HTTP from rollup tables
and views. Build with `just build` (= `cabal build all`), test with `just test`
(= `cabal test`), run dev services with `process-compose up` (= `just up`), all from the
repository root inside `nix develop`. The server runs with `cabal run kansoku-server` on
port 8080.

This plan is EP-19 of MasterPlan 3
(`docs/masterplans/3-kansoku-analytics-extensions-queryable-properties-multi-signal-identity-and-experiment-analytics.md`),
which itself starts only after MasterPlan 2
(`docs/masterplans/2-kansoku-production-hardening-review-fixes-and-portfolio-service-readiness.md`)
is complete. Both are checked in; read their Integration Points sections. The dependencies
that shape every design choice here:

**Hard dependency — EP-17 must be Complete**
(`docs/plans/17-queryable-event-properties-typed-storage-and-property-based-grouping.md`).
EP-17 made event `properties` queryable through
`properties_json JSON MATERIALIZED CAST(properties, 'JSON')`. **This plan's variant
grouping and its rollup materialized view use that representation and never call
`JSONExtract*` over the raw string** (the MasterPlan's "Properties storage representation"
integration point). The exact expressions are
`toString(getSubcolumn(properties_json, 'experiment'))` and
`toString(getSubcolumn(properties_json, 'variant'))`; `getSubcolumn` works through both
the base table and the `analytics.events_resolved` view expression. Direct SQL fixtures
still insert a valid JSON string into `properties`, because `properties_json` is computed
server-side. A QuerySpec test asserts no generated experiment SQL contains `JSONExtract`,
pinning the contract.

**External prerequisites from MasterPlan 2** (all Complete before this plan starts):

- *Versioned ClickHouse migrations* (EP-12,
  `docs/plans/12-clickhouse-schema-v2-sort-key-final-free-resolution-join-free-rollups.md`).
  All ClickHouse DDL lives in immutable files under `db/clickhouse/migrations/`, applied in
  filename order by `db/clickhouse/migrate.sh` (via `just ch-migrate`), which records each
  applied file in the ledger table `analytics.schema_migrations` and skips recorded files.
  `just ch-reset` drops the `analytics` database and replays everything. This plan adds
  the exposure migration plus the additive `0015` MV cast correction recorded during M2.
  EP-12 also established the v2 schema this plan reads:
  `analytics.events_raw` has sort key `(account_id, event_name, occurred_at, event_id)`,
  engine `ReplacingMergeTree(received_at)` (dedup on replayed inserts), string columns are
  non-Nullable with `''` meaning absent, `occurred_at` is `DateTime64(3, 'UTC')`; the v2
  rollups (`analytics.dau`/`analytics.wau`) count *raw identities*
  (`if(user_id != '', user_id, anonymous_id)`) with `uniqCombinedState` into
  `AggregateFunction(uniqCombined, String)` columns, read back with `uniqCombinedMerge`.
  This plan's rollup copies that idiom deliberately.
- *Validated query builders and ordered funnels* (EP-13,
  `docs/plans/13-safe-and-correct-metric-sql-validated-inputs-ordered-funnels-honest-failures.md`).
  Every user-derived string that reaches SQL passes through
  `Kansoku.Metrics.Query.Validate.mkSqlName :: Text -> Either Text SqlName` — an opaque newtype
  whose smart constructor accepts only non-empty strings of at most 128 characters drawn
  from `[a-z0-9_.:-]` — and handlers answer HTTP 400 naming the offending value otherwise.
  EP-13 also rewrote the funnel as a single-pass `windowFunnel` query (explained below) with
  an optional `window` seconds parameter (default: the full from/to range, capped at
  7,776,000 s = 90 days). **This plan reuses that machinery**: `SqlName` for experiment
  names, conversion event names, and funnel steps; the `windowFunnel` + `ARRAY JOIN` SQL
  shape for the per-variant funnel; the same `window` parameter semantics.
- *Authenticated, account-scoped queries* (EP-15,
  `docs/plans/15-api-keys-service-auth-and-account-scoped-queries.md`). Experiment data is
  tenant data. Every metrics endpoint requires a **ServiceToken** (EP-15's bearer credential
  for service callers) and every query is scoped to the authenticated principal's
  `account_id`. EP-15 landed `AuthenticatedPrincipal.accountId`; the handler copies it into
  `QueryRequest.accountId`, runners bind it as the native `{account_id:String}` parameter,
  and builders render `account_id = {account_id:String}` (or the alias-qualified equivalent).
  The umbrella `KansokuAPI` protects the complete `NamedRoutes MetricsRoutes` record with
  `MetricsAuth`, so all new route fields inherit the same service-token boundary.
- *NamedRoutes and same-commit contract discipline* (plan 9,
  `docs/plans/9-convert-kansoku-to-namedroutes-vertical-slices-and-multiverb.md`, and EP-14).
  The metrics API is a servant `NamedRoutes` record — `MetricsRoutes`, one named field per
  route — nested in the umbrella `KansokuAPI` record, and the served type is the same type
  the OpenAPI document is generated from (`cabal run kansoku-openapi` writes
  `docs/api/openapi.json`; CI fails if it is stale). Any commit that changes a wire type
  regenerates the OpenAPI artifact and updates `kansoku-client` **in the same commit**.
  Plan 9 moved the metric modules into vertical slices and wrapped responses in
  `MultiVerb`. This plan uses the landed modules `Kansoku.Metrics.Api`,
  `Kansoku.Metrics.Query`, and
  `Kansoku.Metrics.Handler`. New fields use the same `MultiVerb 'Servant.GET '[JSON]
  (OkResponses "Metric result" MetricResult) (KansokuResult MetricResult)` result family as
  sibling metrics.

**Soft dependencies.** EP-18 has replaced how `canonical_user` is computed underneath
`analytics.events_resolved` and verified the projection; this plan consumes that `String`
opaquely and encodes no resolution-policy assumption. EP-20 remains unimplemented and will
later migrate the `experiment_viewed` declaration from the in-code registry without
semantic change.

The files this plan owns or edits:

- `kansoku-api/src/Kansoku/Event/Registry.hs` — the in-code event schema registry:
  `EventRegistry` (a `Map EventName EventSchema`), `EventSchema` (event name + list of
  `PropertySpec`), `PropertySpec` (`propName`, `propType :: PropertyType`, `propRequired`),
  and `defaultRegistry` listing the known events. Gains the `experiment_viewed` schema and
  the `propPattern` field.
- `kansoku-api/src/Kansoku/Event/Validation.hs` — pure per-event validation
  (`validateEventWith :: EventRegistry -> AnalyticsEvent -> Either [ValidationError] AnalyticsEvent`).
  Unknown event names pass; known names get property checks (missing required, wrong JSON
  type). Gains pattern enforcement and the `InvalidPropertyValue` error.
- `kansoku-api/src/Kansoku/Metrics/Api.hs` — the
  `MetricsRoutes` record and DTOs `MetricResult { metric :: Text, points :: [MetricPoint] }`
  and `MetricPoint { bucket :: Maybe Text, group :: Map Text Text, value :: Double }`.
  These DTOs are **reused unchanged**; the new endpoints only add group-key vocabulary
  (`"experiment"`, `"variant"`, `"measure"`, and for funnels `"step"`/`"index"`). Gains
  three route fields.
- `kansoku-core/src/Kansoku/Metrics/Query.hs` — the query
  compiler: pure SQL builders returning `Text`, runners executing over the ClickHouse
  connection/pool, and point functions shaping rows into `MetricPoint`s. Every builder emits
  a relation with exactly the columns `bucket` (String), `group_key` (String), `value`
  (Float64), already `ORDER BY`-ed — that is the decode contract EP-11/EP-13 established.
  Gains three builders, three runners, three point functions.
- `kansoku-core/src/Kansoku/Metrics/Handler.hs` — metrics
  handlers; where query parameters are validated and 400s produced. Gains three handlers.
- `kansoku-core/test/Kansoku/QuerySpec.hs` and the validation specs under
  `kansoku-api`/`kansoku-core` test suites — gain shape tests.
- `db/clickhouse/migrations/0014_experiment_exposures.sql` — new; the landed ledger is
  occupied through EP-18's `0013_retire_identity_map.sql`.
- `db/clickhouse/migrations/0015_experiment_exposure_string_casts.sql` — additive MV-only
  correction for ClickHouse input blocks whose JSON paths remain `Dynamic`.
- `db/clickhouse/fixtures/ep19_fixtures.sql` and a `just ch-fixtures-ep19` recipe — new.
- `kansoku-client/src/Kansoku/Client.hs` (or a new module) and `docs/api/openapi.json` —
  regenerated/extended with each wire change.

Terms used below, defined once:

*Exposure event* — an analytics event recorded at the moment a user is actually shown an
experiment variant (the UI rendered the treatment, the email contained the variant copy).
Contrast with *assignment*: a server deciding which variant a user would get. Assignment
without exposure must not emit `experiment_viewed`.

*Materialized view (MV)* — in ClickHouse, an insert trigger: `CREATE MATERIALIZED VIEW mv
TO target AS SELECT ...` runs the SELECT over each block of rows inserted into the source
table and inserts the result into the target. It never sees query-time state (which is why
the rollup cannot use stitched identities) and never reprocesses old data by itself (which
is why the migration includes an explicit backfill INSERT).

*AggregatingMergeTree / aggregate state* — a table engine that merges rows with equal
sort-key values by combining their *aggregate function states*. A column typed
`AggregateFunction(uniqCombined, String)` stores a partial unique-count sketch produced by
`uniqCombinedState(x)`; reading requires `uniqCombinedMerge(col)`. `uniqCombined` is exact
for small sets and switches to a HyperLogLog-style sketch at scale (~0.8% relative error);
crucially, merging two sketches computes the *union* of their sets, so merging overlapping
or duplicate sketches never double-counts a user — re-exposures and re-backfills are
harmless by construction.

*`windowFunnel`* — a ClickHouse aggregate: `windowFunnel(w)(ts, cond1, cond2, ...)`
returns, per aggregation group (here: per user), the length of the longest *prefix* of
conditions matched in chronological order, with the whole chain inside `w` time units of
the chain's first event. `countIf(level >= n)` then counts users who reached step n in
order. The window unit is the tick of the timestamp column; `occurred_at` is
`DateTime64(3)` (millisecond ticks), so EP-13's SQL wraps it as `toDateTime(occurred_at)`
to make the window seconds — keep that wrapping.

*`canonical_user`* — the stitched identity exposed by the view
`analytics.events_resolved`: for each event, the explicit user id when present, otherwise
the strongest account-scoped signal binding ranked by EP-18's confidence/recency policy,
otherwise the anonymous cookie. Empty string means unresolvable. Query-time only.


## Plan of Work

Three milestones. Each leaves `cabal test` green, ends in a conventional commit carrying the
MasterPlan/ExecPlan trailers shown in Concrete Steps, and regenerates `docs/api/openapi.json`
and `kansoku-client` in the same commit whenever it touches a wire type.


### Milestone 1 — The assignment-event contract and the exposure rollup

Scope: the `experiment_viewed` contract exists and is enforced at ingest, and exposures
land in a queryable rollup. At the end, ingesting the fixture events produces visible rows
in `analytics.experiment_exposures`, a malformed exposure event is rejected with an error
naming the property, and no HTTP metrics surface has changed yet.

**Step 0 — reconcile (completed 2026-07-19).** EP-17's Decision Log, MasterPlan 3's
Integration Points, the live migration ledger, and `DESCRIBE analytics.events_resolved`
were checked before implementation. Property expressions, fixture encoding, the
seven-column resolved projection, the landed `Kansoku.Metrics.*` module names, `MultiVerb`
result family, and EP-15 account threading are recorded in Surprises & Discoveries. No
compatibility migration is required; the next migration is `0014`.

**The event contract.** In `kansoku-api/src/Kansoku/Event/Registry.hs`, extend the spec
types additively:

```haskell
-- | A syntactic constraint on a string property's value, checked at ingest.
-- SqlNamePattern deliberately equals the charset of
-- Kansoku.Metrics.Query.Validate.mkSqlName (EP-13), so an ingest-accepted value is
-- provably safe to compare against in generated SQL.
data PropertyPattern = SqlNamePattern
  deriving stock (Generic, Eq, Show)

data PropertySpec = PropertySpec
  { propName :: !Text,
    propType :: !PropertyType,
    propRequired :: !Bool,
    propPattern :: !(Maybe PropertyPattern)
  }
  deriving stock (Generic, Eq, Show)
```

Every existing `PropertySpec` literal in `defaultRegistry` gains a `Nothing` pattern (there
are five entries today — `page_view`, `session_start`, `identify`, `user_registered`,
`subscription_started`; a local helper `prop name ty req = PropertySpec name ty req Nothing`
keeps the diff small). Then register the new schema:

```haskell
EventSchema
  (EventName "experiment_viewed")
  [ PropertySpec "experiment" PTString True (Just SqlNamePattern),
    PropertySpec "variant" PTString True (Just SqlNamePattern)
  ]
```

Document the semantics as a comment on the entry, in these words or better: an
`experiment_viewed` event is emitted when a user is *shown* a variant, not when a variant
is merely assigned server-side — exposure-based analysis avoids diluting measured effects
with users who never saw the treatment (see this plan's Decision Log). Emitting it again on
every re-render is fine and expected: all consumers count *unique* users, so re-exposures
are idempotent. `experiment` identifies the experiment (e.g. `checkout_v2`), `variant` the
arm (e.g. `control`, `treatment`); both are lowercase names of at most 128 characters from
`[a-z0-9_.:-]`.

**Registration path.** EP-20
(`docs/plans/20-event-schema-governance-versioned-registry-and-portfolio-event-contracts.md`)
has not landed, so the in-code `defaultRegistry` is the source of truth. Add
`experiment_viewed` there. MasterPlan 3's "Event registry" integration point requires
EP-20 to migrate this entry later without semantic change.

**Validation.** In `kansoku-api/src/Kansoku/Event/Validation.hs`, add a constructor to
`ValidationError`:

```haskell
| InvalidPropertyValue EventName Text Text
  -- ^ event, property name, human-readable rule ("expected [a-z0-9_.:-]{1,128}")
```

and extend `validateProperty`: when the value is present, is a `String s` (the `PTString`
check already ran), and the spec carries `Just SqlNamePattern`, require
`isSqlSafeName s` where

```haskell
-- Mirrors Kansoku.Metrics.Query.Validate.mkSqlName's acceptance (kansoku-core); kept
-- in sync by a test in kansoku-core (kansoku-api cannot depend on kansoku-core).
isSqlSafeName :: Text -> Bool
isSqlSafeName s =
  not (Text.null s)
    && Text.length s <= 128
    && Text.all (\c -> isAsciiLower c || isDigit c || c `elem` ("_.:-" :: String)) s
```

The predicate is duplicated from EP-13's `mkSqlName` because the dependency direction is
`kansoku-core` → `kansoku-api`; add a test in the `kansoku-core` test suite (which can see
both) asserting the two agree on a representative sample: accepted — `checkout_v2`,
`control`, `a`, `x.y:z-1`, a 128-char name; rejected — `""`, a 129-char name, `Control`,
`checkout v2`, `variant'--`, a name containing `|`, a name containing a newline. Extend the
existing validation specs: an `experiment_viewed` event missing `variant` yields
`MissingRequiredProperty`, one with a numeric `variant` yields `WrongPropertyType`, one
with `variant = "B!"` yields `InvalidPropertyValue`, and a fully conforming one passes.
These errors surface through the ingest handler's existing rejection path (per-event
rejections under EP-14's partial-batch contract), so a bad exposure event is refused at the
door with a body naming the event id and error — capture one such transcript in Validation.

**Fixture payload examples** (these exact shapes are used by the curl story; the JSON field
names follow `Kansoku.Event.Types.AnalyticsEvent` — note `properties` and `context` are
required objects):

```json
{
  "eventId": "exp-c1-1",
  "eventName": "experiment_viewed",
  "source": "web",
  "occurredAt": "2026-08-01T10:00:00Z",
  "receivedAt": "2026-08-01T10:00:00Z",
  "userId": "c1",
  "accountId": "acct_a",
  "properties": { "experiment": "checkout_v2", "variant": "control" },
  "context": {}
}
```

and a rejected one (charset violation — uppercase and `!`):

```json
{
  "eventId": "exp-bad-1",
  "eventName": "experiment_viewed",
  "source": "web",
  "occurredAt": "2026-08-01T10:00:00Z",
  "receivedAt": "2026-08-01T10:00:00Z",
  "userId": "c9",
  "accountId": "acct_a",
  "properties": { "experiment": "checkout_v2", "variant": "Treatment!" },
  "context": {}
}
```

**The rollup migration.** Create
`db/clickhouse/migrations/0014_experiment_exposures.sql`. Use EP-17's native-JSON
expressions — never `JSONExtract*`:

```sql
-- Experiment exposure rollup: unique users per account x experiment x variant x day.
--
-- Identity is the RAW identity (user_id if present, else anonymous_id), the
-- same join-free idiom as dau/wau (0006): an insert-time MV cannot see
-- query-time identity resolution, and joining the identity map at insert time
-- freezes stale resolutions and scales insert cost with total identities.
-- Exact stitched per-variant numbers come from the query-time endpoints
-- (conversion, funnel), which read analytics.events_resolved.
--
-- IF NOT EXISTS + the union semantics of uniqCombined states make this file
-- safe to re-run after a mid-file failure: re-backfilling merges identical
-- sketches, which cannot change a unique count.

CREATE TABLE IF NOT EXISTS analytics.experiment_exposures
(
    account_id String,
    experiment LowCardinality(String),
    variant    LowCardinality(String),
    day        Date,
    users      AggregateFunction(uniqCombined, String)
)
ENGINE = AggregatingMergeTree
ORDER BY (account_id, experiment, variant, day);

INSERT INTO analytics.experiment_exposures (account_id, experiment, variant, day, users)
SELECT
    account_id,
    toString(getSubcolumn(properties_json, 'experiment')) AS experiment,
    toString(getSubcolumn(properties_json, 'variant')) AS variant,
    toDate(occurred_at) AS day,
    uniqCombinedState(if(user_id != '', user_id, anonymous_id)) AS users
FROM analytics.events_raw
WHERE event_name = 'experiment_viewed'
  AND (user_id != '' OR anonymous_id != '')
  AND match(toString(getSubcolumn(properties_json, 'experiment')), '^[a-z0-9_.:-]{1,128}$')
  AND match(toString(getSubcolumn(properties_json, 'variant')), '^[a-z0-9_.:-]{1,128}$')
GROUP BY account_id, experiment, variant, day;

CREATE MATERIALIZED VIEW IF NOT EXISTS analytics.mv_experiment_exposures
TO analytics.experiment_exposures
AS
SELECT
    account_id,
    toString(getSubcolumn(properties_json, 'experiment')) AS experiment,
    toString(getSubcolumn(properties_json, 'variant')) AS variant,
    toDate(occurred_at) AS day,
    uniqCombinedState(if(user_id != '', user_id, anonymous_id)) AS users
FROM analytics.events_raw
WHERE event_name = 'experiment_viewed'
  AND (user_id != '' OR anonymous_id != '')
  AND match(toString(getSubcolumn(properties_json, 'experiment')), '^[a-z0-9_.:-]{1,128}$')
  AND match(toString(getSubcolumn(properties_json, 'variant')), '^[a-z0-9_.:-]{1,128}$')
GROUP BY account_id, experiment, variant, day;
```

Design notes to keep as comments or carry into the Decision Log: `LowCardinality(String)`
fits `experiment`/`variant` (a portfolio runs tens of experiments with a handful of arms,
not millions); `account_id` leads the sort key because every read is account-scoped
(EP-15), mirroring the `events_raw` key decision; `day` is last so a whole-range read
merges a contiguous key range per variant. Events between the backfill INSERT and the MV
creation are missed — acceptable in dev (re-run `just ch-reset` or the backfill), and this
plan lands before any production experiment traffic exists; note it in the file.

Implementation note (2026-07-19): `0014` is immutable after its first application. The M2
ordinary-event insert battery exposed ClickHouse's input-block `Dynamic` behavior, so
`0015_experiment_exposure_string_casts.sql` drops and recreates only the MV with
`CAST(toString(getSubcolumn(...)), 'String')` around both path reads. The target table and
the backfilled aggregate states are preserved.

**Fixtures.** Create `db/clickhouse/fixtures/ep19_fixtures.sql` inserting directly into
`analytics.events_raw` the same logical data as the curl story (exact rows are listed in
Validation and Acceptance): experiment `checkout_v2` under account `acct_a` — users
`c1..c5` exposed to `control` and `t1..t5` exposed to `treatment` on 2026-08-01 10:00, a
re-exposure of `c1` on 2026-08-02 (proves idempotence), `checkout_started` events for
`c1, t1..t4` at 11:00, `purchase_completed` for `c1, t1..t3` at 12:00 (after exposure) and
for `c2` at 09:00 (**before** exposure — the ordering proof), plus account `acct_b` — users
`b1, b2` exposed to `control` (the isolation proof). Match the v2 `events_raw` column list
and write `properties` in EP-17's storage form (step 0). Add a justfile recipe following
the existing pattern:

```makefile
# Load the EP-19 experiment analytics verification fixtures.
ch-fixtures-ep19:
    clickhouse-client --port $CLICKHOUSE_TCP_PORT --multiquery < db/clickhouse/fixtures/ep19_fixtures.sql
```

The fixture path (direct INSERT) and the curl path (HTTP → pgmq → writer) are alternatives
covering the same data; the curl path additionally proves ingest validation and the MV
trigger end-to-end. Use the fixture file for fast deterministic iteration and the curl
transcript for acceptance.

Acceptance for M1: `cabal test` green including the new validation and charset-agreement
specs; `just ch-migrate` applies the new file once and skips it on re-run;
after loading fixtures, the clickhouse-client query in Validation returns the expected
rollup rows (5/5/1/2 unique users); an `experiment_viewed` event missing `variant` or
carrying `Treatment!` is rejected by `validateEvent` (spec) and at the ingest endpoint
(transcript). No metrics route changed, so no OpenAPI/client regeneration in this commit —
verify `git diff docs/api/openapi.json` is empty.


### Milestone 2 — Exposure and conversion endpoints

Scope: the two highest-value questions become HTTP endpoints — "how many users saw each
variant" and "which variant converts better" — authenticated, account-scoped, validated,
with client and OpenAPI regenerated in the same commit. At the end, the transcripts in
Validation (including the ordering proof and the two-account isolation proof) pass.

**Route fields.** In `kansoku-api/src/Kansoku/Metrics/Api.hs`, add two fields. Authentication
is inherited from the umbrella API and both fields use the landed sibling response family:

```haskell
experiments :: mode :- "metrics" :> "experiments"
  :> Description "Unique users exposed per experiment and variant, from the \
     \experiment_exposures rollup. Counts RAW identities (user_id, else anonymous_id) \
     \with a uniqCombined sketch (~0.8% error at scale; exact for small sets); \
     \identity-stitched exact numbers are served by the conversion and funnel \
     \endpoints. timeGrain: day, week, or month (hour is rejected; the rollup is daily); \
     \omitted = one bucket for the whole range. Re-exposures never double-count."
  :> QueryParam' '[Required] "from" Day
  :> QueryParam' '[Required] "to" Day
  :> QueryParam "experiment" Text
  :> QueryParam "timeGrain" TimeGrain
  :> MultiVerb 'Servant.GET '[JSON] (OkResponses "Metric result" MetricResult) (KansokuResult MetricResult)

experimentConversion :: mode :- "metrics" :> "experiments" :> "conversion"
  :> Description "Per-variant conversion for one experiment: exposed unique users, \
     \users with a conversion event AT OR AFTER their first exposure (earlier \
     \conversions do not count), and the rate. Users exposed to multiple variants \
     \count in each. Counts and rates only; no significance testing."
  :> QueryParam' '[Required] "experiment" Text
  :> QueryParam' '[Required] "event" Text
  :> QueryParam' '[Required] "from" Day
  :> QueryParam' '[Required] "to" Day
  :> MultiVerb 'Servant.GET '[JSON] (OkResponses "Metric result" MetricResult) (KansokuResult MetricResult)
```

Route-matching note: servant only matches `"experiments"` with its terminal GET at the *end* of the
path, so `/metrics/experiments/conversion` can never be swallowed by the bare
`experiments` field — no field-order hazard. Missing required parameters produce servant's
own 400s; nothing to hand-roll there.

**Builders.** In `kansoku-core/src/Kansoku/Metrics/Query.hs`, follow
the repo code standards (GHC2024, `Kansoku.Prelude`, postpositive qualified imports,
generic-lens `#labels`, strict fields, explicit deriving, MultilineStrings `"""` literals
for the SQL — see `/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/core/`). Machine-generated
date/index fragments may be rendered into SQL; every validated user-supplied name is bound
through a native ClickHouse parameter. Bind the authenticated account through
`QueryRequest.accountId` and render `account_id = {account_id:String}`.

*Exposures* — `buildExperimentExposuresSQL` reads the rollup. With `timeGrain=day`,
optional filter `experiment=checkout_v2`:

```sql
SELECT
    toString(day) AS bucket,
    concat(experiment, '|', variant) AS group_key,
    toFloat64(uniqCombinedMerge(users)) AS value
FROM analytics.experiment_exposures
WHERE account_id = {account_id:String}
  AND day >= '2026-08-01' AND day < '2026-08-08'
  AND match(experiment, '^[a-z0-9_.:-]{1,128}$')
  AND match(variant, '^[a-z0-9_.:-]{1,128}$')
  AND experiment = {experiment:String}
GROUP BY day, experiment, variant
ORDER BY bucket, group_key
```

Grain variants: omitted grain — `'' AS bucket`, `GROUP BY experiment, variant` (merging
day sketches unions them, so `c1`'s day-1 and day-2 exposures still count once — state
this in a comment); `week` — bucket `toString(toMonday(day))`; `month` —
`toString(toStartOfMonth(day))`; `hour` — never reaches the builder (handler 400s it,
because the rollup is daily). The `match` guards implement the Decision Log entry on
data-derived values: only contract-conforming names are served, so the `|` split below is
unambiguous. Point function `experimentExposuresPoint` splits `group_key` on the first `|`
into group keys `"experiment"` and `"variant"`.

*Conversion* — `buildExperimentConversionSQL` reads `analytics.events_resolved` at query
time (exact, identity-stitched). For experiment `checkout_v2`, conversion event
`purchase_completed`, range 2026-08-01 to 2026-08-08:

```sql
WITH exposures AS
(
    SELECT
        canonical_user,
        CAST(toString(getSubcolumn(properties_json, 'variant')), 'String') AS variant,
        min(occurred_at) AS first_exposure
    FROM analytics.events_resolved
    WHERE canonical_user != ''
      AND account_id = {account_id:String}
      AND event_name = 'experiment_viewed'
      AND CAST(toString(getSubcolumn(properties_json, 'experiment')), 'String') = {experiment:String}
      AND match(CAST(toString(getSubcolumn(properties_json, 'experiment')), 'String'), '^[a-z0-9_.:-]{1,128}$')
      AND match(CAST(toString(getSubcolumn(properties_json, 'variant')), 'String'), '^[a-z0-9_.:-]{1,128}$')
      AND occurred_at >= '2026-08-01 00:00:00' AND occurred_at < '2026-08-08 00:00:00'
    GROUP BY canonical_user, variant
),
conversions AS
(
    SELECT
        canonical_user,
        max(occurred_at) AS last_conversion
    FROM analytics.events_resolved
    WHERE canonical_user != ''
      AND account_id = {account_id:String}
      AND event_name = {conversion_event:String}
      AND occurred_at >= '2026-08-01 00:00:00' AND occurred_at < '2026-08-08 00:00:00'
    GROUP BY canonical_user
)
SELECT
    '' AS bucket,
    concat(m.1, '|', variant) AS group_key,
    m.2 AS value
FROM
(
    -- NOTE join_use_nulls = 0: a LEFT JOIN miss fills last_conversion with the
    -- zero DateTime64 (1970), and 1970 >= first_exposure is false, so
    -- never-converters are counted correctly without NULL handling.
    SELECT
        e.variant AS variant,
        toFloat64(uniqExact(e.canonical_user)) AS exposed,
        toFloat64(uniqExactIf(e.canonical_user, c.last_conversion >= e.first_exposure)) AS converted
    FROM exposures AS e
    LEFT JOIN conversions AS c ON c.canonical_user = e.canonical_user
    GROUP BY variant
)
ARRAY JOIN
    [('exposed', exposed),
     ('converted', converted),
     ('conversion_rate', if(exposed = 0, 0., converted / exposed))] AS m
ORDER BY group_key
```

Why this shape (a *min-exposure-time join*, chosen over `windowFunnel` for this endpoint):
the ordering requirement is "some conversion at or after the **first** exposure", which is
one comparison once you have each user's `min` exposure time and `max` conversion time —
`max(conversion) >= min(exposure)` holds exactly when a conversion happened at or after
first exposure, even for users who converted both before and after (their pre-exposure
purchase in the fixtures is exactly what `c2` fails to have followed up).
`windowFunnel(w)(ts, is_exposure, is_conversion)` would additionally impose a window `w`
between exposure and conversion and, with per-variant grouping, needs the same exposures
join anyway — more moving parts for the same answer. The two CTE scans are both pruned by
`event_name` and the time range. `uniqExactIf(x, cond)` counts distinct `x` among rows
where `cond` holds. The tuple `ARRAY JOIN` fans one row per variant into three
`(measure, value)` rows, keeping the universal `bucket`/`group_key`/`value` decode
contract; `measure` is first in the `group_key` because it is a fixed word and `variant`
(data-derived, but `match`-guarded upstream) is last per the Decision Log.

Point function `experimentConversionPoint :: SqlName -> AggRow -> MetricPoint` (the
`SqlName` is the requested experiment, injected by the handler since it is constant per
request): split `group_key` on the first `|` into `measure` and `variant`, emit
`MetricPoint { bucket = Nothing, group = fromList [("experiment", experiment), ("variant",
variant), ("measure", measure)], value }`. Metric names in `MetricResult`:
`"experiment_exposures"` and `"experiment_conversion"`.

**Handlers.** In the metrics handler module, add `experimentsHandler` and
`experimentConversionHandler`. Validation, all via EP-13's machinery and error shape
(`jsonError err400` with a details object naming the offending value): `experiment` and
`event` through `mkSqlName` (400 `"invalid experiment name"` / `"invalid event name"` on
`Left`); `timeGrain = hour` on the exposures endpoint → 400
`"timeGrain hour not supported for experiments (rollup is daily)"`; `event ==
"experiment_viewed"` → 400 `"conversion event must differ from the exposure event"`. An
unknown but well-formed experiment flows through and returns 200 with `points: []` (see
Decision Log — 404 is not used for data absence). The account scope comes from the
authenticated principal exactly as in the sibling handlers (EP-15).

**Client and OpenAPI, same commit.** Regenerate `docs/api/openapi.json` with
`cabal run kansoku-openapi` and commit it with the route change (CI enforces this). For
`kansoku-client`: if MasterPlan 2 left metrics client functions (check
`kansoku-client/src/` for a metrics record — at MP-2 authoring time only `ingestClient`
existed), extend them with the new fields; if not, add a minimal typed derivation so the
MasterPlan's "wire type → client → OpenAPI" slice is honored — e.g. an
`experimentsClient` value derived with `Servant.Client.client` from the new record fields
in a small `Kansoku.Client.Metrics` module — and record the choice in the Decision Log.
Either way `cabal build all` must cover the client in this commit.

**Tests.** Extend `kansoku-core/test/Kansoku/QuerySpec.hs` with shape assertions on both
builders (inputs built with `mkSqlName`, pattern-matching the `Right`): the exposures SQL
contains `uniqCombinedMerge(users)`, `FROM analytics.experiment_exposures`, both `match(`
guards, and `ORDER BY`; grain `Nothing` yields `'' AS bucket` and no `day` in `GROUP BY`;
the conversion SQL contains `min(occurred_at) AS first_exposure`,
`max(occurred_at) AS last_conversion`, `last_conversion >= e.first_exposure`,
`uniqExactIf`, `LEFT JOIN`, the three-tuple `ARRAY JOIN`, and `ORDER BY`; and — pinning
the EP-17 integration contract — **no builder output contains the string `JSONExtract`**
(assert over a list of representative outputs from all three experiment builders once M3
lands). Unit-test the two point functions (splitting, experiment injection) and the
handler 400 paths in the style EP-13 established (WAI test or extracted pure validators —
follow whichever EP-13's Decision Log recorded).

Acceptance for M2: `cabal test` green; OpenAPI document contains both operations with
their descriptions; the Validation transcripts for exposures (day grain and whole-range),
conversion (control 5/1/0.2, treatment 5/3/0.6, `c2` not counted), isolation (acct_b sees
only its 2 exposures), and the 400 set all match.


### Milestone 3 — Per-variant funnels, and the full pass

Scope: EP-13's ordered funnel machinery runs per variant — variant becomes a group key —
completing the API surface; then the whole plan's validation suite runs end-to-end and the
plans of record are updated. At the end, a three-step-per-variant dashboard question is one
HTTP call.

**Route field** (same auth/response combinators as siblings):

```haskell
experimentFunnel :: mode :- "metrics" :> "experiments" :> "funnel"
  :> Description "Ordered funnel per variant of one experiment. Users counted at \
     \step N performed steps 1..N in order, all at or after their first exposure \
     \to the experiment, within `window` seconds of the chain's first step \
     \(default: the full from/to range, capped at 90 days). Steps before first \
     \exposure do not count."
  :> QueryParam' '[Required] "experiment" Text
  :> QueryParam' '[Required] "steps" Text
  :> QueryParam' '[Required] "from" Day
  :> QueryParam' '[Required] "to" Day
  :> QueryParam "window" Int
  :> MultiVerb 'Servant.GET '[JSON] (OkResponses "Metric result" MetricResult) (KansokuResult MetricResult)
```

**Builder** — `buildExperimentFunnelSQL` composes the M2 `exposures` CTE with EP-13's
`windowFunnel` shape; the only structural additions are the join that (a) restricts step
events to each user's post-exposure timeline and (b) carries the variant into the group
key. For steps `checkout_started, purchase_completed`, window 604800:

```sql
WITH exposures AS
(
    SELECT
        canonical_user,
        CAST(toString(getSubcolumn(properties_json, 'variant')), 'String') AS variant,
        min(occurred_at) AS first_exposure
    FROM analytics.events_resolved
    WHERE canonical_user != ''
      AND account_id = {account_id:String}
      AND event_name = 'experiment_viewed'
      AND CAST(toString(getSubcolumn(properties_json, 'experiment')), 'String') = {experiment:String}
      AND match(CAST(toString(getSubcolumn(properties_json, 'experiment')), 'String'), '^[a-z0-9_.:-]{1,128}$')
      AND match(CAST(toString(getSubcolumn(properties_json, 'variant')), 'String'), '^[a-z0-9_.:-]{1,128}$')
      AND occurred_at >= '2026-08-01 00:00:00' AND occurred_at < '2026-08-08 00:00:00'
    GROUP BY canonical_user, variant
)
SELECT
    '' AS bucket,
    concat(toString(step.1), '|', step.2, '|', variant) AS group_key,
    toFloat64(countIf(level >= step.1)) AS value
FROM
(
    SELECT
        e.variant AS variant,
        r.canonical_user AS canonical_user,
        windowFunnel(604800)(toDateTime(r.occurred_at),
          r.event_name = {experiment_funnel_step_1:String},
          r.event_name = {experiment_funnel_step_2:String}) AS level
    FROM analytics.events_resolved AS r
    INNER JOIN exposures AS e ON e.canonical_user = r.canonical_user
    WHERE r.canonical_user != ''
      AND r.account_id = {account_id:String}
      AND r.event_name IN ({experiment_funnel_step_1:String}, {experiment_funnel_step_2:String})
      AND r.occurred_at >= e.first_exposure
      AND r.occurred_at >= '2026-08-01 00:00:00' AND r.occurred_at < '2026-08-08 00:00:00'
    GROUP BY e.variant, r.canonical_user
)
ARRAY JOIN [(1, {experiment_funnel_step_1:String}), (2, {experiment_funnel_step_2:String})] AS step
GROUP BY variant, step
ORDER BY variant, step.1
```

Semantics carried over from EP-13, restated so this section stands alone: `windowFunnel`
gives each user the length of the longest in-order prefix of step conditions;
`toDateTime(occurred_at)` is load-bearing (window unit = timestamp tick; `occurred_at` is
millisecond-tick `DateTime64(3)`, the wrap makes the window seconds); the `event_name IN`
prune bounds the scan; the `ARRAY JOIN` over `(index, name)` tuples fans per-user rows to
per-step rows and `countIf(level >= step.1)` counts users who reached step N in order.
New here: the `INNER JOIN exposures` (small — one row per exposed user per variant) plus
`r.occurred_at >= e.first_exposure` means only post-exposure chains count, consistent with
the conversion endpoint (Decision Log); grouping by `e.variant` makes variant a group key.
The `group_key` encoding is `index|step|variant` — index and step are validated `SqlName`s
that cannot contain `|`, and variant (data-derived, `match`-guarded) is last, so the point
function splits on the first two `|` and takes the remainder as the variant. Point
function `experimentFunnelPoint :: SqlName -> Text -> Double -> MetricPoint` decodes the
row's composite key and emits group keys `"experiment"` (injected), `"variant"`, `"index"`,
`"step"`. Metric name:
`"experiment_funnel"`.

**Handler** — `experimentFunnelHandler`: validate `experiment` and each CSV piece of
`steps` with `mkSqlName` (400 naming the offending value, exactly EP-13's funnel error
shape); reuse EP-13's `window` computation verbatim (default = full range in seconds,
explicit values outside `1..7776000` → 400); account scope from the principal.

**Client + OpenAPI same commit**, as in M2. Extend the QuerySpec shape tests: the funnel
SQL contains `windowFunnel(604800)(toDateTime(`, the ordered condition list, `INNER JOIN`,
`r.occurred_at >= e.first_exposure`, the tuple `ARRAY JOIN`, `countIf(level >= step.1)`,
no `UNION ALL`, no `JSONExtract`, and `ORDER BY`; a three-step case renders indices
`1,2,3` in order; the point function splits `2|purchase_completed|treatment` correctly and
survives a hypothetical variant containing `|` only by never receiving one (documented —
the `match` guard upstream).

Then the full pass: `just build`, `cabal test`, `just ch-reset` + migrate + fixtures +
server, and the complete transcript set in Validation and Acceptance re-run from scratch.
Update every living section of this plan; in the MasterPlan 3 file set the EP-19 registry
row to Complete and tick its two Progress bullets ("assignment event schemas registered;
variant rollups populated", "per-variant metrics endpoints (exposure, conversion, funnel)
serving"); write this plan's Outcomes & Retrospective.

Acceptance for M3: the per-variant funnel transcript matches (control 1/1, treatment 4/3);
all QuerySpec/validation/handler tests green; `cabal run kansoku-openapi && git diff
--exit-code docs/api/openapi.json` passes; all Progress boxes above are checked.


## Concrete Steps

All commands run from the repository root
(`/Users/shinzui/Keikaku/bokuno/kansoku-project/kansoku`) inside `nix develop`.

Orientation and reconciliation (Milestone 1, step 0):

```bash
ls db/clickhouse/migrations/                       # pick the next migration number
grep -rn "MetricsRoutes" --include='*.hs' kansoku-api kansoku-core | grep -v dist-newstyle
grep -rn "mkSqlName\|SqlName" --include='*.hs' kansoku-core | grep -v dist-newstyle | head
grep -n "Decision" docs/plans/17-queryable-event-properties-typed-storage-and-property-based-grouping.md
grep -n "Decision" docs/plans/15-api-keys-service-auth-and-account-scoped-queries.md
```

Environment bring-up (idempotent; reuse a running process-compose):

```bash
just up                # separate terminal: postgres, clickhouse, create_schema
just ch-migrate        # applies unapplied migrations, records them in the ledger
just ch-fixtures-ep19  # loads the experiment fixtures (after M1 creates them)
cabal run kansoku-server   # separate terminal; listens on :8080
```

Build and test loop:

```bash
cabal build all
cabal test
```

Expected test output ends with all specs passing:

```text
Finished in 0.0xx seconds
NN examples, 0 failures
Test suite kansoku-core-test: PASS
```

Migration idempotence check (M1):

```bash
just ch-migrate
```

```text
skipping 0001_events_raw.sql (already applied)
...
applying 0014_experiment_exposures.sql
applying 0015_experiment_exposure_string_casts.sql
```

and a second run prints both `0014` and `0015` as skipped/already applied.

Rollup inspection while developing (fastest feedback — also the M1 acceptance query):

```bash
clickhouse-client --port $CLICKHOUSE_TCP_PORT --query "
SELECT account_id, experiment, variant, day, uniqCombinedMerge(users) AS users
FROM analytics.experiment_exposures
GROUP BY account_id, experiment, variant, day
ORDER BY account_id, experiment, variant, day"
```

Expected with the ep19 fixtures loaded:

```text
acct_a	checkout_v2	control	2026-08-01	5
acct_a	checkout_v2	control	2026-08-02	1
acct_a	checkout_v2	treatment	2026-08-01	5
acct_b	checkout_v2	control	2026-08-01	2
```

(The 2026-08-02 row is `c1`'s re-exposure; the whole-range endpoint still reports 5
control users for acct_a because merging the two day sketches unions them.)

Regenerate the contract artifacts in every commit that touches a route:

```bash
cabal run kansoku-openapi
git diff --exit-code docs/api/openapi.json   # must FAIL before committing the regen, PASS after
```

Commit after each milestone with conventional commits carrying both trailers. Suggested
subjects — M1:

```text
feat(events): declare the experiment_viewed exposure contract and exposure rollup

Registers experiment_viewed (required charset-validated string properties
experiment/variant) in the event registry, enforces property patterns at
ingest, and adds the analytics.experiment_exposures rollup + MV (account x
experiment x variant x day, uniqCombined over raw identity) via a versioned
migration, with backfill and ep19 fixtures.

MasterPlan: docs/masterplans/3-kansoku-analytics-extensions-queryable-properties-multi-signal-identity-and-experiment-analytics.md
ExecPlan: docs/plans/19-experiment-analytics-assignment-events-variant-rollups-and-per-variant-metrics.md
```

M2: `feat(metrics): per-variant exposure and conversion endpoints` — body noting
exposure-ordering semantics, account scoping, and the same-commit OpenAPI/client regen;
M3: `feat(metrics): per-variant ordered funnels for experiments` — body noting the
post-exposure restriction and variant group key. All three carry the same two trailers.


## Validation and Acceptance

With the environment up, migrations applied, and the server running. Two accounts exist
with EP-15 credentials; the transcripts write the write keys as `$WRITE_KEY_A`/`$WRITE_KEY_B`
and the metrics-read service tokens as `$TOKEN_A`/`$TOKEN_B` — substitute the header shape
EP-15 established (shown here as `Authorization: Bearer ...`; reconcile in step 0).

**1. Ingest the fixture story via curl** (end-to-end: HTTP → pgmq → batched writer →
`events_raw` → MV → rollup). The batch endpoint is `POST /v1/batch` (plan 9's
`IngestRoutes`); post-EP-14 it answers with per-event acceptance. Account A, all events in
one batch — 5 control exposures (`c1..c5`), 5 treatment exposures (`t1..t5`) at
2026-08-01T10:00Z; `c1` re-exposed 2026-08-02T10:00Z; `checkout_started` at 11:00 for
`c1, t1, t2, t3, t4`; `purchase_completed` at 12:00 for `c1, t1, t2, t3`; and the ordering
witness — `c2`'s `purchase_completed` at **09:00**, an hour *before* exposure:

```bash
curl -s -X POST http://localhost:8080/v1/batch \
  -H "Authorization: Bearer $WRITE_KEY_A" -H 'Content-Type: application/json' \
  --data-binary @- <<'JSON'
[
  {"eventId":"exp-c1-1","eventName":"experiment_viewed","source":"web","occurredAt":"2026-08-01T10:00:00Z","receivedAt":"2026-08-01T10:00:00Z","userId":"c1","accountId":"acct_a","properties":{"experiment":"checkout_v2","variant":"control"},"context":{}},
  {"eventId":"exp-c2-1","eventName":"experiment_viewed","source":"web","occurredAt":"2026-08-01T10:00:00Z","receivedAt":"2026-08-01T10:00:00Z","userId":"c2","accountId":"acct_a","properties":{"experiment":"checkout_v2","variant":"control"},"context":{}},
  {"eventId":"exp-c3-1","eventName":"experiment_viewed","source":"web","occurredAt":"2026-08-01T10:00:00Z","receivedAt":"2026-08-01T10:00:00Z","userId":"c3","accountId":"acct_a","properties":{"experiment":"checkout_v2","variant":"control"},"context":{}},
  {"eventId":"exp-c4-1","eventName":"experiment_viewed","source":"web","occurredAt":"2026-08-01T10:00:00Z","receivedAt":"2026-08-01T10:00:00Z","userId":"c4","accountId":"acct_a","properties":{"experiment":"checkout_v2","variant":"control"},"context":{}},
  {"eventId":"exp-c5-1","eventName":"experiment_viewed","source":"web","occurredAt":"2026-08-01T10:00:00Z","receivedAt":"2026-08-01T10:00:00Z","userId":"c5","accountId":"acct_a","properties":{"experiment":"checkout_v2","variant":"control"},"context":{}},
  {"eventId":"exp-t1-1","eventName":"experiment_viewed","source":"web","occurredAt":"2026-08-01T10:00:00Z","receivedAt":"2026-08-01T10:00:00Z","userId":"t1","accountId":"acct_a","properties":{"experiment":"checkout_v2","variant":"treatment"},"context":{}},
  {"eventId":"exp-t2-1","eventName":"experiment_viewed","source":"web","occurredAt":"2026-08-01T10:00:00Z","receivedAt":"2026-08-01T10:00:00Z","userId":"t2","accountId":"acct_a","properties":{"experiment":"checkout_v2","variant":"treatment"},"context":{}},
  {"eventId":"exp-t3-1","eventName":"experiment_viewed","source":"web","occurredAt":"2026-08-01T10:00:00Z","receivedAt":"2026-08-01T10:00:00Z","userId":"t3","accountId":"acct_a","properties":{"experiment":"checkout_v2","variant":"treatment"},"context":{}},
  {"eventId":"exp-t4-1","eventName":"experiment_viewed","source":"web","occurredAt":"2026-08-01T10:00:00Z","receivedAt":"2026-08-01T10:00:00Z","userId":"t4","accountId":"acct_a","properties":{"experiment":"checkout_v2","variant":"treatment"},"context":{}},
  {"eventId":"exp-t5-1","eventName":"experiment_viewed","source":"web","occurredAt":"2026-08-01T10:00:00Z","receivedAt":"2026-08-01T10:00:00Z","userId":"t5","accountId":"acct_a","properties":{"experiment":"checkout_v2","variant":"treatment"},"context":{}},
  {"eventId":"exp-c1-2","eventName":"experiment_viewed","source":"web","occurredAt":"2026-08-02T10:00:00Z","receivedAt":"2026-08-02T10:00:00Z","userId":"c1","accountId":"acct_a","properties":{"experiment":"checkout_v2","variant":"control"},"context":{}},
  {"eventId":"co-c1","eventName":"checkout_started","source":"web","occurredAt":"2026-08-01T11:00:00Z","receivedAt":"2026-08-01T11:00:00Z","userId":"c1","accountId":"acct_a","properties":{},"context":{}},
  {"eventId":"co-t1","eventName":"checkout_started","source":"web","occurredAt":"2026-08-01T11:00:00Z","receivedAt":"2026-08-01T11:00:00Z","userId":"t1","accountId":"acct_a","properties":{},"context":{}},
  {"eventId":"co-t2","eventName":"checkout_started","source":"web","occurredAt":"2026-08-01T11:00:00Z","receivedAt":"2026-08-01T11:00:00Z","userId":"t2","accountId":"acct_a","properties":{},"context":{}},
  {"eventId":"co-t3","eventName":"checkout_started","source":"web","occurredAt":"2026-08-01T11:00:00Z","receivedAt":"2026-08-01T11:00:00Z","userId":"t3","accountId":"acct_a","properties":{},"context":{}},
  {"eventId":"co-t4","eventName":"checkout_started","source":"web","occurredAt":"2026-08-01T11:00:00Z","receivedAt":"2026-08-01T11:00:00Z","userId":"t4","accountId":"acct_a","properties":{},"context":{}},
  {"eventId":"pc-c2-early","eventName":"purchase_completed","source":"web","occurredAt":"2026-08-01T09:00:00Z","receivedAt":"2026-08-01T09:00:00Z","userId":"c2","accountId":"acct_a","properties":{},"context":{}},
  {"eventId":"pc-c1","eventName":"purchase_completed","source":"web","occurredAt":"2026-08-01T12:00:00Z","receivedAt":"2026-08-01T12:00:00Z","userId":"c1","accountId":"acct_a","properties":{},"context":{}},
  {"eventId":"pc-t1","eventName":"purchase_completed","source":"web","occurredAt":"2026-08-01T12:00:00Z","receivedAt":"2026-08-01T12:00:00Z","userId":"t1","accountId":"acct_a","properties":{},"context":{}},
  {"eventId":"pc-t2","eventName":"purchase_completed","source":"web","occurredAt":"2026-08-01T12:00:00Z","receivedAt":"2026-08-01T12:00:00Z","userId":"t2","accountId":"acct_a","properties":{},"context":{}},
  {"eventId":"pc-t3","eventName":"purchase_completed","source":"web","occurredAt":"2026-08-01T12:00:00Z","receivedAt":"2026-08-01T12:00:00Z","userId":"t3","accountId":"acct_a","properties":{},"context":{}}
]
JSON
```

Account B (isolation), two control exposures, no conversions:

```bash
curl -s -X POST http://localhost:8080/v1/batch \
  -H "Authorization: Bearer $WRITE_KEY_B" -H 'Content-Type: application/json' \
  --data-binary @- <<'JSON'
[
  {"eventId":"exp-b1-1","eventName":"experiment_viewed","source":"web","occurredAt":"2026-08-01T10:00:00Z","receivedAt":"2026-08-01T10:00:00Z","userId":"b1","accountId":"acct_b","properties":{"experiment":"checkout_v2","variant":"control"},"context":{}},
  {"eventId":"exp-b2-1","eventName":"experiment_viewed","source":"web","occurredAt":"2026-08-01T10:00:00Z","receivedAt":"2026-08-01T10:00:00Z","userId":"b2","accountId":"acct_b","properties":{"experiment":"checkout_v2","variant":"control"},"context":{}}
]
JSON
```

Both return the EP-14 acceptance shape with every event accepted. The writer flushes in
batches; wait for the pipeline (a second or two, or watch the writer log), then confirm
arrival before querying metrics:

```bash
clickhouse-client --port $CLICKHOUSE_TCP_PORT --query \
  "SELECT count() FROM analytics.events_raw WHERE event_name = 'experiment_viewed'"
```

```text
13
```

(If EP-15's ingest enforces the account from the write key rather than trusting the
payload's `accountId`, the payload field is redundant but harmless — reconcile per its
plan. `just ch-fixtures-ep19` inserts the same logical rows directly and is the fast path
when iterating on queries only.)

**2. Contract enforcement** — the malformed exposure from Milestone 1 (variant
`Treatment!`) is rejected per-event:

```bash
curl -s -X POST http://localhost:8080/v1/batch \
  -H "Authorization: Bearer $WRITE_KEY_A" -H 'Content-Type: application/json' \
  --data-binary '[{"eventId":"exp-bad-1","eventName":"experiment_viewed","source":"web","occurredAt":"2026-08-01T10:00:00Z","receivedAt":"2026-08-01T10:00:00Z","userId":"c9","accountId":"acct_a","properties":{"experiment":"checkout_v2","variant":"Treatment!"},"context":{}}]'
```

Observed on 2026-07-19 against an isolated, fully migrated `kansoku_ep19` PostgreSQL
database and port 18080 (the event timestamp was moved to 2026-07-19 so this check did not
also trigger future-time validation):

```text
{"accepted":0,"rejected":[{"errors":["event 'experiment_viewed': property 'variant' has an invalid value; expected [a-z0-9_.:-]{1,128}"],"eventId":"exp-bad-2","index":0}]}
HTTP 202
{"accepted":0,"rejected":[{"errors":["event 'experiment_viewed': missing required property 'variant'"],"eventId":"exp-missing-2","index":0}]}
HTTP 202
```

This is EP-14's partial-batch contract: the HTTP request itself succeeds with 202 while
each invalid event is named in `rejected`. The temporary database was dropped after the
transcript; it contained acceptance-only credentials and queue data.

**3. Exposures** (M2) — per day, then whole-range, as account A:

```bash
curl -s -H "Authorization: Bearer $TOKEN_A" \
  "http://localhost:8080/metrics/experiments?from=2026-08-01&to=2026-08-08&timeGrain=day" | jq .
```

```json
{
  "metric": "experiment_exposures",
  "points": [
    { "bucket": "2026-08-01", "group": { "experiment": "checkout_v2", "variant": "control" }, "value": 5 },
    { "bucket": "2026-08-01", "group": { "experiment": "checkout_v2", "variant": "treatment" }, "value": 5 },
    { "bucket": "2026-08-02", "group": { "experiment": "checkout_v2", "variant": "control" }, "value": 1 }
  ]
}
```

```bash
curl -s -H "Authorization: Bearer $TOKEN_A" \
  "http://localhost:8080/metrics/experiments?from=2026-08-01&to=2026-08-08" \
  | jq '[.points[] | {variant: .group.variant, value}]'
```

```json
[
  { "variant": "control", "value": 5 },
  { "variant": "treatment", "value": 5 }
]
```

(`c1` was exposed on two days yet counts once — sketch merging is a union; re-exposures
are idempotent as the contract promises.)

**4. Conversion with the ordering proof** (M2) — `c2` purchased *before* exposure and must
not count; control converts 1/5, treatment 3/5:

```bash
curl -s -H "Authorization: Bearer $TOKEN_A" \
  "http://localhost:8080/metrics/experiments/conversion?experiment=checkout_v2&event=purchase_completed&from=2026-08-01&to=2026-08-08" | jq .
```

```json
{
  "metric": "experiment_conversion",
  "points": [
    { "bucket": null, "group": { "experiment": "checkout_v2", "variant": "control",   "measure": "conversion_rate" }, "value": 0.2 },
    { "bucket": null, "group": { "experiment": "checkout_v2", "variant": "treatment", "measure": "conversion_rate" }, "value": 0.6 },
    { "bucket": null, "group": { "experiment": "checkout_v2", "variant": "control",   "measure": "converted" }, "value": 1 },
    { "bucket": null, "group": { "experiment": "checkout_v2", "variant": "treatment", "measure": "converted" }, "value": 3 },
    { "bucket": null, "group": { "experiment": "checkout_v2", "variant": "control",   "measure": "exposed" }, "value": 5 },
    { "bucket": null, "group": { "experiment": "checkout_v2", "variant": "treatment", "measure": "exposed" }, "value": 5 }
  ]
}
```

(Point order follows `ORDER BY group_key` on `measure|variant`. If control's `converted`
reads 2, the ordering predicate is broken — that is the failing baseline an unordered
implementation would produce, because `c2` did purchase, just too early.)

**5. Isolation** (M2) — the same two requests as account B see only account B:

```bash
curl -s -H "Authorization: Bearer $TOKEN_B" \
  "http://localhost:8080/metrics/experiments?from=2026-08-01&to=2026-08-08" \
  | jq '[.points[] | {variant: .group.variant, value}]'
curl -s -H "Authorization: Bearer $TOKEN_B" \
  "http://localhost:8080/metrics/experiments/conversion?experiment=checkout_v2&event=purchase_completed&from=2026-08-01&to=2026-08-08" \
  | jq '[.points[] | select(.group.measure != "conversion_rate") | {variant: .group.variant, measure: .group.measure, value}]'
```

```json
[
  { "variant": "control", "value": 2 }
]
```

```json
[
  { "variant": "control", "measure": "converted", "value": 0 },
  { "variant": "control", "measure": "exposed", "value": 2 }
]
```

None of acct_a's users or counts appear. An unauthenticated request returns EP-15's
401/403.

Implementation transcript (2026-07-19, isolated `kansoku_ep19_m2` PostgreSQL database,
real server on port 18080, direct EP-19 ClickHouse fixtures): the exact JSON documents
above were observed with HTTP 200. Account A returned daily exposure rows `5,5,1`,
whole-range control/treatment `5,5`, and conversion `0.2/0.6`, `1/3`, `5/5`. Account B
returned control exposure `2`, conversion rate `0`, converted `0`, exposed `2`. A valid
unknown experiment returned `{"metric":"experiment_exposures","points":[]}` with HTTP
200; hour grain, `bad'name`, and conversion event `experiment_viewed` returned the named
400 envelopes; a missing credential returned
`{"code":"unauthorized","message":"missing or unknown credential","retryable":false}`
with HTTP 401. The temporary database contained only acceptance credentials/queue state
and was dropped afterward.

**6. Per-variant funnel** (M3) — `t4` started checkout but never purchased; `c2` appears
at no step (her only purchase predates exposure and she never started checkout):

```bash
curl -s -H "Authorization: Bearer $TOKEN_A" \
  "http://localhost:8080/metrics/experiments/funnel?experiment=checkout_v2&steps=checkout_started,purchase_completed&from=2026-08-01&to=2026-08-08" | jq .
```

```json
{
  "metric": "experiment_funnel",
  "points": [
    { "bucket": null, "group": { "experiment": "checkout_v2", "variant": "control",   "index": "1", "step": "checkout_started" },   "value": 1 },
    { "bucket": null, "group": { "experiment": "checkout_v2", "variant": "control",   "index": "2", "step": "purchase_completed" }, "value": 1 },
    { "bucket": null, "group": { "experiment": "checkout_v2", "variant": "treatment", "index": "1", "step": "checkout_started" },   "value": 4 },
    { "bucket": null, "group": { "experiment": "checkout_v2", "variant": "treatment", "index": "2", "step": "purchase_completed" }, "value": 3 }
  ]
}
```

Observed on 2026-07-19 against an isolated, fully migrated `kansoku_ep19_m3`
PostgreSQL database and a real server on port 18080: account A returned the exact four
points above (`control` 1/1, `treatment` 4/3). Account B returned an empty funnel, proving
account isolation. An invalid step (`bad'step`) and `window=0` returned named HTTP 400
responses, while a valid unknown experiment returned
`{"metric":"experiment_funnel","points":[]}` with HTTP 200. The temporary database
contained only acceptance credentials/queue state and was dropped afterward.

**7. Error contract** (M2/M3):

```bash
curl -si -H "Authorization: Bearer $TOKEN_A" \
  "http://localhost:8080/metrics/experiments/conversion?experiment=checkout%27--&event=purchase_completed&from=2026-08-01&to=2026-08-08" | head -1
curl -si -H "Authorization: Bearer $TOKEN_A" \
  "http://localhost:8080/metrics/experiments?from=2026-08-01&to=2026-08-08&timeGrain=hour" | head -1
curl -si -H "Authorization: Bearer $TOKEN_A" \
  "http://localhost:8080/metrics/experiments/conversion?experiment=checkout_v2&event=experiment_viewed&from=2026-08-01&to=2026-08-08" | head -1
curl -si -H "Authorization: Bearer $TOKEN_A" \
  "http://localhost:8080/metrics/experiments/funnel?experiment=checkout_v2&steps=checkout_started,purchase_completed&from=2026-08-01&to=2026-08-08&window=0" | head -1
```

All four print `HTTP/1.1 400 Bad Request`, each with a JSON body naming the offense. And
the documented empty-result semantics — well-formed but unknown experiment:

```bash
curl -s -H "Authorization: Bearer $TOKEN_A" \
  "http://localhost:8080/metrics/experiments/conversion?experiment=no_such_experiment&event=purchase_completed&from=2026-08-01&to=2026-08-08" | jq .
```

```json
{ "metric": "experiment_conversion", "points": [] }
```

**Test-level acceptance:** `just build` and `just test` are green: 120 core examples and
11 client examples passed with zero failures, with one opt-in live client example pending.
QuerySpec asserts the three new
SQL shapes (including no `JSONExtract` and no `UNION ALL` anywhere, `ORDER BY` everywhere,
the ordering predicate, the `match` guards); validation specs cover the
`experiment_viewed` schema (missing, mistyped, bad-charset, conforming) and the
charset-agreement pin against `mkSqlName`; point-function unit tests cover the group-key
splits; `docs/api/openapi.json` contains the three operations and is regeneration-clean.


## Idempotence and Recovery

Everything here is safe to repeat. Re-running `just ch-migrate` skips the applied
migrations (ledger). Re-running migration `0014` itself after a mid-file failure is safe:
`CREATE ... IF NOT EXISTS` no-ops, and re-running the backfill INSERT merges duplicate
`uniqCombined` sketches, which is a set union and cannot change any unique count. Re-posting
the curl batches is safe: `analytics.events_raw` is a `ReplacingMergeTree` keyed on the v2
sort key ending in `event_id`, so replayed events collapse at merge time — but note the MV
fires per *insert*, before dedup, so a replayed exposure adds its user to the day's sketch
again, which (union, again) changes nothing. This replay-immunity is a designed property of
choosing a unique-count state; a `count` state would not have it. Loading
`ep19_fixtures.sql` after the curl batches double-inserts the same logical events; for
clean numbers use one path per database state, or `just ch-reset` and start over (dev-only;
destroys all analytics data, then replays all migrations).

If the writer pipeline is not flushing (step 1's count query stays at 0), check the
process-compose writer logs and the `/ready` endpoint (queue depth, writer liveness) from
MP-2's EP-10/EP-16 before suspecting this plan's code.

All Haskell changes revert with git. The one risky class of step is the migrations: they
are additive overall (`0015` replaces only the plan-owned MV), so the rollback is
`DROP TABLE analytics.mv_experiment_exposures` then
`DROP TABLE analytics.experiment_exposures` issued manually — but prefer roll-forward with
a new migration file, since the applied file is immutable under EP-12's rule. Step 0
verified that `analytics.events_resolved` already has `account_id` and `properties_json`,
so recovery does not need to recreate the shared view.

If EP-17's landed representation differs from both candidate shapes sketched here, do not
force these SQL sketches onto it: substitute its real expressions, update the QuerySpec
assertions to match, and record the delta. The one non-negotiable is the integration
contract itself — no `JSONExtract` over the raw string, pinned by test.


## Interfaces and Dependencies

No new library dependencies: servant/servant-server/servant-client, aeson, ClickHaskell
(pinned checkout; confirm with `mori registry show`), and the existing test stack cover
everything. ClickHouse features used: `AggregatingMergeTree`, `AggregateFunction(uniqCombined,
String)` with `uniqCombinedState`/`uniqCombinedMerge`, materialized views, `windowFunnel`,
tuple `ARRAY JOIN`, `uniqExactIf`, `countIf`, `match` — all present in any ClickHouse
recent enough to run the v2 schema.

Module contracts at end of plan. The landed modules are `Kansoku.Metrics.Api` and
`Kansoku.Metrics.Query`; all builders receive the account through `QueryRequest` and all
runners receive the existing `QueryPool`.

```haskell
module Kansoku.Event.Registry
  ( EventRegistry (..), EventSchema (..),
    PropertySpec (..),        -- now with propPattern :: Maybe PropertyPattern
    PropertyPattern (..),     -- SqlNamePattern
    PropertyType (..),
    defaultRegistry,          -- now includes experiment_viewed
    emptyRegistry, lookupSchema, registerSchema,
  )

module Kansoku.Event.Validation
  ( ValidationError (..),     -- now with InvalidPropertyValue EventName Text Text
    validateEvent, validateEventWith,
  )

module Kansoku.Metrics.Query
  ( -- existing exports unchanged, plus:
    buildExperimentExposuresSQL,   -- :: QueryRequest -> Maybe SqlName -> Text
    buildExperimentConversionSQL,  -- :: QueryRequest -> SqlName -> SqlName -> Text
                                   --    (experiment, conversion event)
    buildExperimentFunnelSQL,      -- :: QueryRequest -> SqlName -> Int -> [SqlName] -> Text
                                   --    (experiment, window seconds, steps)
    runExperimentExposures, runExperimentConversion, runExperimentFunnel,
    experimentExposuresPoint, experimentConversionPoint, experimentFunnelPoint,
  )
```

The three `MetricsRoutes` fields (`experiments`, `experimentConversion`,
`experimentFunnel`) exist with the parameter lists shown in Milestones 2 and 3, wrapped in
the same auth and response combinators as their sibling fields. `MetricResult` and
`MetricPoint` are unchanged; the new group-key vocabulary is `"experiment"`, `"variant"`,
`"measure"` (`exposed` | `converted` | `conversion_rate`), and for funnels `"step"` and
`"index"` (the same two keys EP-13's plain funnel uses). `kansoku-client` exposes typed
access to the three routes (extending MP-2's metrics client if one exists, else the
minimal `Kansoku.Client.Metrics` derivation), and `docs/api/openapi.json` documents them —
both regenerated in the same commit as each route change.

ClickHouse objects: this plan owns `analytics.experiment_exposures` and
`analytics.mv_experiment_exposures` (migration `0014_experiment_exposures.sql`, corrected
additively by `0015_experiment_exposure_string_casts.sql`). It reads
`analytics.events_resolved` (owned by EP-12/EP-18) and, through EP-17's representation,
the property columns of `analytics.events_raw` — it owns neither and must not alter them
because step 0 verified the shared projection already satisfies the contract.

---

Revision note (2026-07-19, implementation start): reconciled every authored placeholder
with the landed EP-17/EP-18 schema, current `Kansoku.Metrics.*`/`MultiVerb` API, EP-15
account-parameter path, in-code registry source, and migration ledger through `0013`;
linked the active intention and recorded the green baseline.

Revision note (2026-07-19, completion): marked all three milestones complete, replaced the
funnel sketch's illustrative literals with the landed native ClickHouse parameters and
Dynamic-to-String guards, recorded the fresh end-to-end transcripts and final test counts,
and linked the durable exposure-based contract in ADR 0006.
