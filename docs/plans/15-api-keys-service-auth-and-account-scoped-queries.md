---
id: 15
slug: api-keys-service-auth-and-account-scoped-queries
title: "API keys, service auth, and account-scoped queries"
kind: exec-plan
created_at: 2026-07-15T21:30:34Z
master_plan: "docs/masterplans/2-kansoku-production-hardening-review-fixes-and-portfolio-service-readiness.md"
---

# API keys, service auth, and account-scoped queries

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Kansoku today has no authentication anywhere. Any network peer that can reach the server can
POST events into the pipeline, and — worse — can GET every account's metrics: event counts,
active users, funnels, retention, all of it, for every tenant at once. Kansoku is the
first-party analytics service for the kikan portfolio, which means browsers running untrusted
JavaScript and a fleet of backend microservices will both talk to it, on behalf of *different
accounts whose data must not leak into each other*. A sibling plan
(`docs/plans/13-safe-and-correct-metric-sql-validated-inputs-ordered-funnels-honest-failures.md`)
fixes *how* metric SQL is constructed; this plan fixes *who may call at all* and *whose data a
call may see*.

After this plan is implemented, three things are true and demonstrable with `curl`:

First, every analytics endpoint requires a credential. There are two kinds. A **write key**
(token prefix `ksk_w_`) is *public* — it is designed to be embedded in a browser bundle — and
grants exactly the two ingest endpoints, `POST /v1/events` and `POST /v1/batch`, nothing else.
A **service token** (token prefix `ksk_s_`) is *secret* — it lives in a microservice's
environment, never in a browser — and grants ingest *and* the read-side `GET /metrics/*`
endpoints. A request with no credential gets HTTP 401 with a JSON error body; a request with a
write key against a metrics endpoint gets HTTP 403. The operational endpoints `/health`,
`/ready`, and `/openapi.json` stay public.

Second, every credential belongs to exactly one account, and the server — never the caller —
decides which account data belongs to. On ingest, the authenticated key's account overwrites
whatever `accountId` the client put in the event body, so a compromised or buggy client cannot
write into another tenant's data. On metrics, every generated ClickHouse query carries an
`account_id = '<the caller's account>'` predicate taken from the service token, never from a
query parameter, so two accounts querying the same endpoint over the same date range see
disjoint results.

Third, credentials are operable: they are issued by a `kansoku-server issue-key` subcommand
that prints the token exactly once and stores only a SHA-256 hash; the prefix (`ksk_w_` /
`ksk_s_`) lets logs and support identify a token's kind without possessing the secret; and a
key can be revoked by setting one timestamp column, taking effect on the next request.

You can see the whole thing working by running the two-account isolation demo in Validation
and Acceptance: issue keys for `acct_alpha` and `acct_beta`, ingest two events under one and
three under the other, then query `GET /metrics/events` with each account's service token and
observe `2.0` and `3.0` respectively — with neither account able to see, or even count, the
other's rows.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] M1: `Kansoku.Postgres.Migration` module (hasql-migration runner, `kansoku` schema, embedded DDL) exists and runs at startup
- [ ] M1: `kansoku.api_keys` table created by migration; re-running startup is a no-op
- [ ] M1: `Kansoku.Auth.Types`, `Kansoku.Auth.Token`, `Kansoku.Auth.Store`, `Kansoku.Auth.Issue` modules compile with unit tests green
- [ ] M1: `kansoku-server issue-key` subcommand issues both kinds; transcript captured; `psql` shows a hash, not the token
- [ ] M1: `just issue-key` and `just dev-keys` recipes added
- [ ] M2: `AuthProtect` combinators + `HasOpenApi` instances in `kansoku-api`; OpenAPI document regenerated with securitySchemes and 401/403 responses
- [ ] M2: ingest route family authenticated (write key or service token, both headers); 401 and 202 transcripts captured
- [ ] M2: ingested events are server-stamped with the key's account; stamped `account_id` observed in ClickHouse
- [ ] M2: `kansoku-client` sends credentials; client tests green; plan 9 routing test updated for the auth context
- [ ] M3: metrics route family requires a service token; 403-for-write-key transcript captured
- [ ] M3: `QueryRequest.accountId` threaded through every SQL builder; `QuerySpec` asserts the predicate in all of them
- [ ] M3: `events_resolved` exposes `account_id` (migration through EP-12's mechanism)
- [ ] M3: rollups (`dau`, `wau`, `daily_event_counts`, `page_views_by_route`) rebuilt with an `account_id` dimension and backfilled
- [ ] M3: two-account isolation demo executed and transcript captured


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Discovery (plan authoring, 2026-07-15): the pinned local OpenAPI generator,
  `servant-openapi-hs` at `/Users/shinzui/Keikaku/bokuno/openapi-hs-project/servant-openapi-hs`,
  has **no `HasOpenApi` instance for servant's `AuthProtect` combinator** (verified by grepping
  `src/Servant/OpenApi/Internal.hs`: instances exist for `Header'`, `QueryParam'`, `NamedRoutes`,
  `MultiVerb`, etc., none for `AuthProtect` or `BasicAuth`). The underlying data model,
  `openapi-hs`, *does* carry full security-scheme types (`SecurityScheme`,
  `SecuritySchemeHttp (HttpSchemeBearer …)`, `SecuritySchemeApiKey`, `SecurityRequirement` in
  `src/Data/OpenApi/Internal.hs`). This plan therefore writes the two needed `HasOpenApi`
  instances inside `kansoku-api` (Milestone 2) so the generated document declares the schemes
  and per-operation 401/403 responses. Upstreaming a generic instance into `servant-openapi-hs`
  is desirable but out of scope; record the outcome here when the instances land.

- (Placeholder) Record here whether EP-12's landed `events_resolved` v2 already carries
  `account_id` (making this plan's view migration a no-op) and what EP-12's final rollup /
  canonical-user expressions were, since Milestone 3's SQL must be rebased onto them.


## Decision Log

Record every decision made while working on the plan.

- Decision: Store only a SHA-256 hash of each token at rest, and give tokens identifying
  prefixes (`ksk_w_` for write keys, `ksk_s_` for service tokens) over 32 bytes of
  base64url-encoded entropy.
  Rationale: A database read (backup leak, SQL access, log of a query) must never yield usable
  credentials; lookups hash the presented token and compare hashes, so plaintext never needs to
  exist server-side after issuance. The prefix costs nothing cryptographically (the 32 random
  bytes carry all the entropy) and buys operability: a token seen in a log or a support ticket
  is identifiable by kind and by service ("this is a kansoku write key") without revealing
  whether it is live. This mirrors the widely used Stripe/GitHub token-prefix convention.
  Date: 2026-07-15

- Decision: On ingest, the authenticated key's account **overwrites** any client-supplied
  `accountId` on every event (the field is effectively server-stamped).
  Rationale: The alternative — trusting the body and rejecting mismatches — leaves a
  correctness hole (events with `accountId = Nothing` would need a default anyway) and a
  security hole (a leaked write key for account A plus a spoofed body writes into account B if
  enforcement has any gap). Overwriting makes the credential the single source of tenancy
  truth: the write key *is* the account. The tradeoff is that a single process legitimately
  emitting events for multiple accounts must hold one write key per account; that is the
  intended model for kikan (accounts are portfolio products, each shipping its own key).
  `AnalyticsEvent.accountId` stays `Maybe AccountId` on the wire for compatibility, but its
  client-supplied value is ignored.
  Date: 2026-07-15

- Decision: Authentication is always on. There is no `KANSOKU_AUTH_REQUIRED` toggle, no
  auth-off mode, and consequently **no new `Config` fields** — the key store rides the existing
  `pgConnectionString` pool.
  Rationale: An auth-off mode is a production incident waiting for a misconfigured environment
  variable; every deployment that ever ran with it off has unattributable rows forever. Local
  development instead gets a one-command bootstrap (`just dev-keys`) that issues a dev write
  key and dev service token against the local Postgres, which is cheap because issuance is a
  subcommand of the server binary itself. The MasterPlan's integration-point note that EP-15
  "adds key-storage settings" to `Kansoku.Config` collapses to zero fields; recorded here so
  the deviation is deliberate, not an omission.
  Date: 2026-07-15

- Decision: Every request performs a Postgres lookup (one indexed point query on
  `token_hash`) through the existing hasql pool; an in-memory TTL cache is deliberately
  deferred.
  Rationale: The pool (`kansoku-core/src/Kansoku/Postgres.hs`, size 20) already serves every
  ingest request for pgmq enqueue, so auth adds one more sub-millisecond unique-index probe on
  a table with tens of rows. A cache adds an invalidation problem (revocation must take effect
  promptly) for no measured need. If profiling under portfolio load ever shows the probe
  matters, add a small TTL (≤60 s) cache keyed by hash *then*, accepting that revocation lags
  by the TTL. Recording the deferral here is the contract that the optimization path was
  considered, not missed.
  Date: 2026-07-15

- Decision: Enforce auth with servant generalized authentication (`AuthProtect` +
  `AuthHandler`) declared on the NamedRoutes records from
  `docs/plans/9-convert-kansoku-to-namedroutes-vertical-slices-and-multiverb.md`, not with WAI
  middleware.
  Rationale: `AuthProtect` puts the requirement *in the route type*, which is the same type the
  server serves and the OpenAPI generator documents (plan 9's whole point), so the published
  contract shows which operations need which credential and cannot drift from enforcement. A
  WAI middleware per subtree is simpler to bolt on but is a second hand-maintained router — the
  exact defect class plan 9 eliminates — and is invisible to the generated document. The
  middleware alternative remains acceptable *only* if plan 9's landed structure somehow makes
  the type-level attachment impractical; if taken, it must be recorded here with the reason.
  Date: 2026-07-15

- Decision: Use two *distinct principal newtypes* (`IngestPrincipal`, `MetricsPrincipal`) as
  the `AuthServerData` results of the two `AuthProtect` tags, rather than one shared type.
  Rationale: servant resolves the `AuthHandler` for a tag from the `Context` *by result type*.
  If both tags mapped to the same `AuthenticatedPrincipal` type, the context would hold two
  `AuthHandler Request AuthenticatedPrincipal` entries and type-directed lookup would silently
  hand *both* route families the first one — the metrics family would accept write keys. The
  newtypes make the two handlers different types, so a mix-up is a compile error. This is a
  known servant generalized-auth gotcha; it is load-bearing here.
  Date: 2026-07-15

- Decision: The rollup tables gain an `account_id` dimension (leading the `ORDER BY`, added to
  each materialized view's `SELECT`/`GROUP BY`), rather than restricting the rollup-backed
  fast paths to whole-instance metrics.
  Rationale: kikan is multi-account by design; a DAU number aggregated across all accounts
  answers nobody's real question, so account-blind rollups would force `active_users` and
  day-grain `page_views` back onto raw-table scans for every real caller — exactly the cost
  the rollups exist to avoid. Rebuilding is cheap now (data is small, and rollups are fully
  derivable from `events_raw`), and EP-12's versioned migration mechanism is the vehicle. The
  alternative (whole-instance-only fast paths) was rejected as a dead end that would need
  undoing the first time a dashboard ships.
  Date: 2026-07-15

- Decision: kansoku's own Postgres DDL (the `kansoku.api_keys` table) is applied at startup by
  a new `Kansoku.Postgres.Migration` module built on the **pinned `shinzui/hasql-migration`
  fork** (`cabal.project` already carries the source-repository-package pin), with the ledger
  table placed in a dedicated `kansoku` schema via `SET LOCAL search_path`.
  Rationale: kansoku needs a first-party Postgres migration path for the first time (pgmq
  migrates *its own* schema via its own tooling inside `bootstrapQueue`; nothing migrates
  kansoku-owned tables). hasql-migration is the right size: it is already pinned in
  `cabal.project`, it runs as a composable `Hasql.Transaction` over the *existing* pool with a
  simple filename+checksum ledger, and this plan needs exactly one table. The heavier
  alternative, `pg-migrate` (the component/history framework the local pgmq-migration package
  has moved to), is designed for redistributable components with evidence-based history
  imports — machinery kansoku does not need for one first-party table. Two cautions shaped the
  design: (a) pgmq's tooling treats `public.schema_migrations` as a *predecessor pgmq ledger*
  it may verify exclusively (see `Pgmq.Migration.History.HasqlMigration.RequireExclusiveSourceLedger`
  in the pinned pgmq-hs repo), so kansoku's ledger must not live at `public.schema_migrations`
  — hence the `kansoku` schema; (b) if a later plan (likely EP-10's build restoration, see
  Context) moves kansoku's pgmq bootstrap onto pg-migrate wholesale, folding `api_keys` into a
  pg-migrate component then is a fine follow-up — record it here if done.
  Date: 2026-07-15

- Decision: Accept credentials on **both** headers for **both** kinds — `Authorization: Bearer
  <token>` and `X-Api-Key: <token>` — with `Authorization` taking precedence when both are
  present.
  Rationale: Services conventionally send `Authorization: Bearer`; browser SDKs often prefer a
  custom header (`X-Api-Key`) because some fetch wrappers and proxies fight over
  `Authorization`. The token itself is self-describing (`ksk_w_`/`ksk_s_` prefix, and the
  database row records the kind), so the header carries no authority — only transport. Fixed
  precedence (Authorization first, X-Api-Key ignored when both present) keeps behavior
  deterministic and documentable. `docs/plans/14-…` pre-allows both headers in CORS, so the
  browser path works the moment EP-14 is live.
  Date: 2026-07-15

- Decision: Issue keys with a typed `kansoku-server issue-key` subcommand rather than a raw
  SQL `just` recipe.
  Rationale: The subcommand reuses `loadConfig`, the hasql pool, the token generator, and the
  hash function — the *same code paths* the server authenticates with, so an issued key is
  correct by construction (a hand-rolled psql recipe would duplicate the hashing and prefix
  logic in shell, and skew is silent). `kansoku-server/app/Main.hs` currently ignores argv, so
  adding dispatch is additive. A thin `just issue-key` recipe wraps the subcommand for
  ergonomics. No admin HTTP API in this plan — issuance is an operator action.
  Date: 2026-07-15


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

### What kansoku is and how the pieces fit

Kansoku is a Haskell analytics service (GHC 9.12.4, built with `cabal` inside a nix dev shell;
enter with `nix develop`, or use the `just` recipes) living at repository root
`/Users/shinzui/Keikaku/bokuno/kansoku-project/kansoku`. Applications POST analytics events to
it; the HTTP handler validates them and enqueues them into **pgmq** (a PostgreSQL-backed
message queue); a background *writer* drains the queue and batch-inserts into **ClickHouse**
(a column-oriented analytics database, database name `analytics`); the metrics endpoints
compile SQL against ClickHouse and return JSON. Four cabal packages:

- `kansoku-api` — route types and wire DTOs only (servant types, `AnalyticsEvent`, metric
  DTOs, `Kansoku.Prelude`). After plan 9's Milestone 5 it also owns the OpenAPI generator and
  the checked-in `docs/api/openapi.json`.
- `kansoku-core` — the runtime: config, Postgres pool, pgmq producer, ClickHouse adapter,
  writer, metric query compiler, handlers, HTTP assembly.
- `kansoku-client` — the Haskell SDK (servant-generated client over `kansoku-api`).
- `kansoku-server` — the executable (`kansoku-server/app/Main.hs`).

Local services start with `just up` (process-compose: postgres, clickhouse, create_schema).
`just build` wraps `cabal build all`; `just test` wraps `cabal test`; prefer `cabal test all`
to also run the client suite. ClickHouse DDL lives in `db/clickhouse/migrations/` and is
applied by `just ch-migrate` (today: every file in filename order; EP-12 — see below —
replaces this with a versioned, recorded mechanism).

### The plans this one builds on

This plan is EP-15, the last child of the MasterPlan at
`docs/masterplans/2-kansoku-production-hardening-review-fixes-and-portfolio-service-readiness.md`
(Phase 4, "Portfolio readiness"). Its **hard dependency** is plan 9
(`docs/plans/9-convert-kansoku-to-namedroutes-vertical-slices-and-multiverb.md`): plan 9
converts the route declarations to `NamedRoutes` records served as one servant application,
and this plan's auth declarations attach to those records — there is no sane way to attach
typed auth to the pre-plan-9 hand-rolled WAI dispatch. After plan 9, expect the route records
`IngestRoutes` and `MetricsRoutes` mounted in an umbrella `KansokuAPI` record, the modules
relocated concept-first (`Kansoku/Ingest/Api.hs`, `Kansoku/Metrics/Api.hs`,
`Kansoku/Metrics/Query.hs` — this plan names files by their *post-plan-9* paths and notes the
pre-move names where helpful), routes terminated with `MultiVerb`, and the OpenAPI document
generated from the served proxy by a `kansoku-openapi` executable into `docs/api/openapi.json`
with a regeneration diff-check.

Soft dependencies, and what this plan honestly needs from each:

- **EP-12** (`docs/plans/12-clickhouse-schema-v2-…`): defines the v2 `events_raw` sort key —
  which *keeps `account_id` leading* precisely because this plan makes queries account-scoped
  (MasterPlan Decision Log, 2026-07-15) — and introduces the versioned ClickHouse migration
  mechanism plus the FINAL-free `events_resolved` and join-free rollups. **Milestone 3 of this
  plan creates new ClickHouse objects and must do so through EP-12's mechanism; if EP-12 has
  somehow not landed, Milestone 3 blocks.** In the MasterPlan's phase ordering EP-12 (Phase 2)
  always precedes EP-15 (Phase 4), so this is a consistency check, not an expected state.
  Milestones 1 and 2 do not touch ClickHouse DDL and are not blocked.
- **EP-13** (`docs/plans/13-safe-and-correct-metric-sql-…`): rewrites the SQL builders with
  validated/parameterized inputs. If landed, thread the account value through its safe-input
  path; if not, use the existing `sqlString` escaping (the value comes from kansoku's own
  database, not from the caller, so the residual risk is low either way).
- **EP-14** (`docs/plans/14-sdk-grade-ingest-contract-…`): finalizes the ingest contract and
  pre-allows `Authorization` and `X-Api-Key` in CORS. Without it, browsers cannot make
  cross-origin authenticated calls (preflight fails); server-to-server traffic and all of this
  plan's acceptance are unaffected.

One cross-plan compile note discovered while authoring this plan: `kansoku-core/src/Kansoku/Ingest/Queue.hs`
calls `Pgmq.Migration.migrate` (a hasql `Session`), but the pinned local `pgmq-migration`
package (path in `cabal.project`:
`/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs/pgmq-migration`) has since
moved to the `pg-migrate` framework and now exports only `pgmqMigrations` (a
`MigrationComponent`) — no `migrate`. Restoring that call site is EP-10's business (the "repo
does not compile" plan), not this plan's; it is noted here because this plan's Milestone 1
adds a *second*, kansoku-owned migration call next to `bootstrapQueue`, and the reader should
not confuse the two mechanisms: pgmq migrates pgmq's schema with pgmq's tooling; kansoku
migrates kansoku's schema with hasql-migration.

### Terms used in this plan

**servant generalized authentication** — servant's hook for custom credentials. A route (or a
whole mounted record) is prefixed with the combinator `AuthProtect "some-tag"` (from
`Servant.API.Experimental.Auth`). On the server, the open type family `AuthServerData
(AuthProtect "some-tag")` names the *principal type* the authentication produces, and you
supply an `AuthHandler Request principal` (from `Servant.Server.Experimental.Auth`, built with
`mkAuthHandler`) in the server's `Context` (a heterogeneous list passed to
`serveWithContext`). servant runs the handler before the route's own handler; the principal
value is prepended as an ordinary argument. On the client
(`servant-client-core`), the same combinator makes the generated function take an
`AuthenticatedRequest` built with `mkAuthenticatedRequest`, which is just "a function that
edits the outgoing request", e.g. adds a header.

**AuthHandler** — the `Request -> Handler principal` function above, wrapped. Throwing a
`ServerError` from it (e.g. `err401`) rejects the request before any route handler runs.

**principal** — the authenticated identity a request acts as. Here it is a record carrying the
key's id, kind, and account.

**write key / service token** — the two credential kinds this plan introduces; defined in
Purpose. Both are rows in one Postgres table, distinguished by a `kind` column.

**hasql-migration** — a small migration library for hasql (pinned fork
`shinzui/hasql-migration` in `cabal.project`, source at
`/Users/shinzui/Keikaku/hub/haskell/hasql-migration`). Its API: `runMigration ::
MigrationCommand -> Transaction (Maybe MigrationError)` where `MigrationCommand` is
`MigrationInitialization` (create the ledger table `schema_migrations(filename, checksum,
executed_at)`) or `MigrationScript name sqlBytes` (execute the SQL once, recording an MD5
checksum; a re-run with matching checksum is a no-op; a re-run with a *different* checksum is
an error — migrations are immutable once applied). The ledger table name is unqualified, so it
lands in whatever schema leads `search_path`; this plan pins it into the `kansoku` schema.

**materialized view / rollup** — in ClickHouse, a materialized view (MV) is an insert trigger:
each block inserted into `events_raw` is transformed by the MV's `SELECT` and appended to a
target *rollup* table holding pre-aggregated state (engine `AggregatingMergeTree`, storing
`AggregateFunction(uniqExact, String)` states merged at query time with `uniqExactMerge`). MVs
fire only on *new* inserts, so changing an MV requires backfilling its target from the raw
table.

### The current state, file by file

**Routes.** `kansoku-api/src/Kansoku/Api/Ingest.hs` (post-plan-9:
`kansoku-api/src/Kansoku/Ingest/Api.hs`) declares `POST /v1/events` (→ `IngestAck`) and
`POST /v1/batch` (→ `BatchAck`, reshaped by EP-14 into a partial-acceptance response).
`kansoku-api/src/Kansoku/Api/Metrics.hs` (post-plan-9:
`kansoku-api/src/Kansoku/Metrics/Api.hs`) declares eleven `GET /metrics/*` endpoints, nine of
them the shared `MetricQuery` shape (`from`/`to` required `Day`s, optional `groupBy`,
`timeGrain`). Plan 9 turns both into records (`IngestRoutes`, `MetricsRoutes`) mounted in a
`KansokuAPI` umbrella record whose two fields this plan will wrap with `AuthProtect`.
`/health` and `/openapi.json` (and EP-10's `/ready`) are served at the WAI level *outside* the
servant record — plan 9's Decision Log keeps them there — which is exactly why they remain
public with no exemption logic in this plan.

**Event model.** `kansoku-api/src/Kansoku/Event/Types.hs` defines `AnalyticsEvent` with
`accountId :: !(Maybe AccountId)` where `newtype AccountId = AccountId {unAccountId :: Text}`.
The ClickHouse row mapper `kansoku-core/src/Kansoku/ClickHouse/EventRow.hs`
(`eventRowFromEvent`) maps `Nothing` to the empty string: `account_id = maybe ""
(textBytes . unAccountId) (event ^. #accountId)`. So today, events ingested without an
`accountId` produce rows with `account_id = ''`. After this plan, the ingest handler stamps
every event with the key's account before enqueueing, so *new* rows always carry a real
account; pre-existing `''` rows simply never match any account-scoped predicate (they become
invisible to account-scoped metrics — acceptable for pre-production data; see Idempotence).

**Ingest handler.** `kansoku-core/src/Kansoku/Ingest/Handler.hs`: `postEvent` and `postBatch`
set `#receivedAt` to now, validate, and enqueue via `enqueueOne`/`enqueueMany` using the hasql
`Pool.Pool` and pgmq `QueueName`. The account stamp slots in right next to the `receivedAt`
stamp.

**Metrics handlers and query compiler.** `kansoku-core/src/Kansoku/Metrics/Handler.hs` builds
a `Query.QueryRequest {from, to, groupBy, timeGrain}` and dispatches to
`kansoku-core/src/Kansoku/Query.hs` (post-plan-9: `kansoku-core/src/Kansoku/Metrics/Query.hs`).
The builders and the tables they read, because *every one of them* must gain the account
predicate:

- `countEventsSQL`, `propertyAggregateSQL`, `buildSessionsSQL` — read `analytics.events_raw`
  (has `account_id`).
- `uniqueUsersSQL`, `buildRatioSQL` (two subselects), `buildRetentionSQL` (two CTEs:
  `first_seen`, `activity`), `buildFunnelSQL` (one subquery per step *plus* one
  `canonical_user IN (…)` subquery per previous step) — read `analytics.events_resolved`,
  a view whose `SELECT` list today (`db/clickhouse/migrations/0002_identity.sql`) is
  `event_id, event_name, occurred_at, url, canonical_user` — **no `account_id`**. The view
  must be recreated with the column (Milestone 3).
- `activeUsersDaySQL` / `activeUsersWeekSQL` — read rollups `analytics.dau` / `analytics.wau`.
- `pageViewsDaySQL` — reads rollup `analytics.page_views_by_route`.
- (`analytics.daily_event_counts` exists but no builder reads it today; it still gains the
  dimension so it answers per-account questions when something does.)

The rollups (`db/clickhouse/migrations/0003_rollups.sql`) have **no account column at all**:
`dau` is `ORDER BY day`, `wau` is `ORDER BY week`, `daily_event_counts` is `ORDER BY (day,
event_name)`, `page_views_by_route` is `ORDER BY (day, route)`. They aggregate across all
accounts — which, per the Decision Log, answers nobody's real question in a multi-account
service.

**events_raw sort key.** `db/clickhouse/migrations/0001_events_raw.sql` (and EP-12's v2
successor) orders by `(account_id, user_id, event_name, occurred_at, event_id)`. The
MasterPlan's Decision Log records that EP-12 keeps `account_id` leading *because this plan*
makes every metric query filter on it: after Milestone 3, every raw-table scan starts with an
`account_id =` prefix match on the primary key.

**Storage for keys.** There is none. Postgres (database `kansoku`, connection string from
`PG_CONNECTION_STRING`, default `postgresql:///kansoku`) currently hosts only pgmq's objects,
created by `bootstrapQueue` (`kansoku-core/src/Kansoku/Ingest/Queue.hs`) with pgmq's own
tooling. kansoku has never owned a Postgres table, so this plan introduces kansoku's own
migration path (Decision Log: hasql-migration, `kansoku` schema).

**Config.** `kansoku-core/src/Kansoku/Config.hs` `loadConfig` is total with defaults. Per the
Decision Log this plan adds **no fields**.

**Server entry.** `kansoku-server/app/Main.hs` ignores argv entirely (`main` goes straight to
`loadConfig`). Milestone 1 adds argument dispatch: no args → run the server exactly as today;
`issue-key …` → issue a credential and exit.

### Code standards

Follow the repository's Haskell standards (canonically
`/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/core/`): GHC2024 with the cabal `common`
stanza's default extensions; import `Kansoku.Prelude`; postpositive qualified imports
(`import Data.Text qualified as Text`); generic-lens optics via `OverloadedLabels`
(`event ^. #accountId`, `raw & #receivedAt .~ now`); strict record fields (`!`); explicit
deriving strategies (`deriving stock`, `deriving newtype`, `deriving anyclass`); and
`MultilineStrings` for embedded SQL (already in `default-extensions` — embed the migration DDL
as multiline string literals, not external files, so the binary is self-contained and the
checksum ledger hashes exactly what ships).


## Plan of Work

### Milestone 1 — Key model, Postgres migration path, and issuance

Scope: everything needed to *have* credentials, with the HTTP surface untouched. At the end,
`kansoku-server` (a) applies kansoku's own Postgres migrations at startup, creating
`kansoku.api_keys`, and (b) gains an `issue-key` subcommand that mints a token, stores its
hash, and prints the token once. Commands: `cabal build all && cabal test all`, then the
issuance transcript below. Acceptance: the transcript matches; `psql -d kansoku -c "select
kind, account_id, token_hash from kansoku.api_keys"` shows a 64-hex-character hash and never
the token; restarting the server re-runs migrations as a no-op.

**1a. The migration runner.** New module `kansoku-core/src/Kansoku/Postgres/Migration.hs`
exporting `migrateKansoku :: Pool.Pool -> IO ()` and (for tests) `kansokuMigrations ::
[(String, ByteString)]`. Add `hasql-migration` and `hasql-transaction` to `kansoku-core`'s
`build-depends` (both resolve — `cabal.project` already pins `shinzui/hasql-migration`, and
`hasql-transaction` is in its closure). The runner composes ONE `Hasql.Transaction`:

1. `sql "create schema if not exists kansoku"`,
2. `sql "set local search_path to kansoku, public"` — this pins hasql-migration's unqualified
   `schema_migrations` ledger (and any unqualified DDL) into the `kansoku` schema for the
   duration of the transaction, keeping `public.schema_migrations` free for pgmq's tooling
   (Decision Log),
3. `runMigration MigrationInitialization`,
4. for each `(name, sqlBytes)` in `kansokuMigrations` in order: `runMigration (MigrationScript
   name sqlBytes)`, aborting with `error` (startup must fail loudly) on `Just migrationError`.

Run it via `Hasql.Transaction.Sessions.transaction Serializable Write` and `Pool.use pool`,
`error`-ing on session failure exactly as `bootstrapQueue` does. The first (and in this plan
only) migration entry is `("0001_api_keys", encodeUtf8 apiKeysDdl)` where `apiKeysDdl` is a
`MultilineStrings` literal containing exactly:

```sql
create table if not exists kansoku.api_keys
  ( id          uuid primary key default gen_random_uuid()
  , kind        text not null check (kind in ('write_key', 'service_token'))
  , token_hash  text not null unique
  , account_id  text not null
  , description text not null default ''
  , created_at  timestamptz not null default now()
  , revoked_at  timestamptz
  );

create index if not exists api_keys_account_idx
  on kansoku.api_keys (account_id);
```

Notes a novice needs: `gen_random_uuid()` is built into PostgreSQL 13+ (no extension);
`token_hash` is the lowercase hex SHA-256 of the *full* token string (prefix included) and its
`unique` constraint is what makes lookup a point query; `revoked_at is null` is the liveness
condition — revocation is `update kansoku.api_keys set revoked_at = now() where id = …`, no
delete, so audit history survives. The DDL is schema-qualified (`kansoku.api_keys`) so it is
correct regardless of `search_path`; the `set local` in step 2 exists for the *ledger*, which
hasql-migration writes unqualified. Never edit `apiKeysDdl` after it has been applied anywhere
that matters — hasql-migration will (correctly) refuse with a checksum error; add a new
`0002_…` entry instead.

Call `migrateKansoku pool` in `kansoku-server/app/Main.hs` immediately before
`bootstrapQueue pool queueName`, inside the existing `bracket`. Both are idempotent, so
ordering between them is by ownership clarity only.

**1b. Domain types.** New module `kansoku-core/src/Kansoku/Auth/Types.hs`:

```haskell
data CredentialKind = WriteKey | ServiceToken
  deriving stock (Generic, Eq, Show)

newtype ApiKeyId = ApiKeyId {unApiKeyId :: UUID}
  deriving stock (Generic, Show)
  deriving newtype (Eq)

data AuthenticatedPrincipal = AuthenticatedPrincipal
  { keyId :: !ApiKeyId,
    kind :: !CredentialKind,
    accountId :: !Text
  }
  deriving stock (Generic, Eq, Show)

newtype IngestPrincipal = IngestPrincipal {principal :: AuthenticatedPrincipal}
  deriving stock (Generic, Eq, Show)

newtype MetricsPrincipal = MetricsPrincipal {principal :: AuthenticatedPrincipal}
  deriving stock (Generic, Eq, Show)
```

plus `credentialKindText :: CredentialKind -> Text` (`"write_key"` / `"service_token"`) and
its inverse, matching the `check` constraint exactly. The two newtypes exist for `Context`
disambiguation (Decision Log). `UUID` comes from the `uuid` package (add to `build-depends`;
it is already in the dependency closure via other pins — if not, it is a standard Hackage
package).

**1c. Token generation and hashing.** New module `kansoku-core/src/Kansoku/Auth/Token.hs`:

```haskell
newtype Token = Token {unToken :: Text}

generateToken :: CredentialKind -> IO Token
hashToken :: Token -> Text
tokenKind :: Text -> Maybe CredentialKind
```

`generateToken` draws 32 bytes from `Crypto.Random.getRandomBytes` (package `crypton`; add to
`build-depends` — it is already in the closure via hasql-migration's `Crypto.Hash` use),
encodes them base64url *without padding* (package `base64-bytestring`, module
`Data.ByteString.Base64.URL`, `encodeUnpadded` — 43 characters), and prepends `ksk_w_` for
`WriteKey` or `ksk_s_` for `ServiceToken`. `hashToken` is the lowercase hex SHA-256 of the
full token text: `Crypto.Hash.hashWith SHA256` on the UTF-8 bytes, rendered with `show` (a
`Digest SHA256`'s `Show` is lowercase hex) and packed to `Text`. `tokenKind` inspects only the
prefix — it is the operability affordance (logs can classify a leaked string) and a cheap
pre-check, but the database `kind` column is always the authority.

**1d. The store.** New module `kansoku-core/src/Kansoku/Auth/Store.hs` with two hasql
`Statement`s and pool-running wrappers:

- `insertApiKey :: Pool.Pool -> CredentialKind -> Text -> Text -> Text -> IO ApiKeyId` —
  `insert into kansoku.api_keys (kind, token_hash, account_id, description) values ($1, $2,
  $3, $4) returning id`.
- `lookupApiKey :: Pool.Pool -> Text -> IO (Maybe AuthenticatedPrincipal)` — `select id, kind,
  account_id from kansoku.api_keys where token_hash = $1 and revoked_at is null`, decoding
  `kind` through the `credentialKindText` inverse (failing the row loudly on an unknown value,
  which the `check` constraint makes unreachable).

Both use prepared statements and `Pool.use`, surfacing `UsageError` as a 503-shaped failure at
the call site (the auth handler in Milestone 2 maps it to 503, not 401 — an unreachable key
store must not read as "bad credentials").

**1e. Issuance.** New module `kansoku-core/src/Kansoku/Auth/Issue.hs` exporting
`issueKey :: Pool.Pool -> CredentialKind -> Text -> Text -> IO (ApiKeyId, Token)`
(generate → hash → `insertApiKey` → return both), and argv dispatch in
`kansoku-server/app/Main.hs`: `getArgs`; `[]` → the current server path unchanged;
`"issue-key" : rest` → parse `--kind write|service`, `--account <text>` (both required),
`--description <text>` (optional, default `""`) by simple pattern matching on the argument
list (two required flags do not justify an option-parser dependency; print a usage line and
`exitFailure` on anything unrecognized, empty `--account`, or a kind other than
`write`/`service`); then `loadConfig`, `createPool`, `migrateKansoku` (so issuance works on a
fresh database before the server has ever run), `issueKey`, print, `exitSuccess`. Exact output
contract (the token appears exactly once, on its own line, so shell capture is trivial):

```text
issued write_key 6f3e9d0a-4c1b-4b7e-9a52-1de1c2a4b970 for account acct_alpha
ksk_w_Uv38ByGCZU8WP18PmmIdcpVmx00QA3xNe7sEB9Hixkk
store this token now; it cannot be shown again
```

Add `just` recipes to the repository `justfile`:

```makefile
# Issue an API key. kind is write|service.
issue-key kind account description="":
    cabal run kansoku-server -- issue-key --kind {{kind}} --account {{account}} --description "{{description}}"

# Bootstrap local dev credentials (one write key + one service token for account "dev").
dev-keys:
    cabal run kansoku-server -- issue-key --kind write --account dev --description "local dev write key"
    cabal run kansoku-server -- issue-key --kind service --account dev --description "local dev service token"
```

(`just dev-keys` mints *new* keys each run; old ones stay valid until revoked — fine for dev.)

**1f. Tests.** New spec `kansoku-core/test/Kansoku/Auth/TokenSpec.hs` (wire into
`test/Spec.hs` and the cabal `other-modules`): generated write-key tokens start with `ksk_w_`
and are 49 characters (6 prefix + 43 body); service tokens start with `ksk_s_`; two generated
tokens differ; `hashToken` output is 64 lowercase hex chars and differs from the token;
`tokenKind` round-trips both prefixes and is `Nothing` for garbage. Also assert
`kansokuMigrations` names are strictly ascending and unique (protects the ledger).

Commit (conventional commits; both trailers mandatory on every commit in this plan):

```text
feat(auth): api_keys storage, kansoku postgres migrations, and issue-key subcommand

MasterPlan: docs/masterplans/2-kansoku-production-hardening-review-fixes-and-portfolio-service-readiness.md
ExecPlan: docs/plans/15-api-keys-service-auth-and-account-scoped-queries.md
```

### Milestone 2 — Ingest authentication and server-stamped tenancy

Scope: the ingest route family requires a credential (either kind); the authenticated
account overwrites the event body's `accountId`; the OpenAPI document declares the security
schemes; the SDK sends credentials. Commands: `cabal build all && cabal test all`, regenerate
the OpenAPI artifact, then the curl transcripts. Acceptance: `POST /v1/events` with no
credential → 401 JSON; with a valid write key → 202; the resulting ClickHouse row's
`account_id` equals the *key's* account even when the request body claimed another.

**2a. The combinators, in `kansoku-api`.** New module `kansoku-api/src/Kansoku/Auth/Api.hs`
(concept-first per plan 9's layout):

```haskell
type IngestAuth = AuthProtect "kansoku-ingest"

type MetricsAuth = AuthProtect "kansoku-metrics"
```

(`AuthProtect` is from `Servant.API.Experimental.Auth`; `kansoku-api` already depends on
`servant`.) Attach them **once per route family** in the umbrella record (plan 9's
`kansoku-api/src/Kansoku/Api.hs`):

```haskell
data KansokuAPI mode = KansokuAPI
  { ingest :: mode :- IngestAuth :> NamedRoutes IngestRoutes,
    metrics :: mode :- MetricsAuth :> NamedRoutes MetricsRoutes
  }
  deriving stock (Generic)
```

Attaching at the family level (rather than per route) means one declaration covers the two
ingest routes and all eleven metric routes, and a route added to a family later is protected
by construction. On the server side the field's handler type becomes a *function taking the
principal*: `ingest :: IngestPrincipal -> IngestRoutes (AsServerT Handler)`.

**2b. OpenAPI instances, in `kansoku-api`.** In plan 9's generator module
(`kansoku-api/src/Kansoku/Api/OpenApi.hs`), add — alongside the existing DTO orphans — the two
`HasOpenApi` instances that `servant-openapi-hs` lacks (Surprises & Discoveries). Each
delegates to the sub-API, tags every operation with a named `SecurityRequirement`, and adds
401 (both) / 403 (metrics only) response stubs:

```haskell
instance (HasOpenApi sub) => HasOpenApi (AuthProtect "kansoku-ingest" :> sub) where
  toOpenApi _ =
    toOpenApi (Proxy @sub)
      & addSecurity "writeKey" ["missing or unknown credential -> 401"]

instance (HasOpenApi sub) => HasOpenApi (AuthProtect "kansoku-metrics" :> sub) where
  toOpenApi _ =
    toOpenApi (Proxy @sub)
      & addSecurity "serviceToken" ["missing or unknown credential -> 401", "write key -> 403"]
```

with a local helper `addSecurity` that (a) sets `security` on every operation (the
`allOperations` traversal from `Data.OpenApi.Operation`) to the named requirement, and (b)
inserts the corresponding 401/403 `Response` entries. In the top-level `kansokuOpenApi` value,
register both schemes under `components.securitySchemes` using `openapi-hs`'s types:
`"serviceToken"` as `SecurityScheme (SecuritySchemeHttp (HttpSchemeBearer Nothing))` described
as "kansoku service token (`ksk_s_…`); also accepted on X-Api-Key", and `"writeKey"` as
`SecurityScheme (SecuritySchemeApiKey (ApiKeyParams "X-Api-Key" ApiKeyHeader))` described as
"kansoku write key (`ksk_w_…`); also accepted as Bearer". This is deliberately *documentation
of both headers with one canonical scheme each* — OpenAPI cannot express "either header" more
precisely without doubling every requirement. These instances must land in the same commit
that adds `IngestAuth`/`MetricsAuth` to the record, or `cabal run kansoku-openapi` stops
compiling. Regenerate and check in `docs/api/openapi.json`.

**2c. The auth handlers, in `kansoku-core`.** New module
`kansoku-core/src/Kansoku/Auth/Handler.hs`:

```haskell
type instance AuthServerData (AuthProtect "kansoku-ingest") = IngestPrincipal

type instance AuthServerData (AuthProtect "kansoku-metrics") = MetricsPrincipal

ingestAuthHandler :: Pool.Pool -> AuthHandler Request IngestPrincipal
metricsAuthHandler :: Pool.Pool -> AuthHandler Request MetricsPrincipal
authContext :: Pool.Pool -> Context '[AuthHandler Request IngestPrincipal, AuthHandler Request MetricsPrincipal]
```

Shared logic `authenticate :: Pool.Pool -> Request -> Handler AuthenticatedPrincipal`:

1. Extract the presented token: look up the `Authorization` header; if present it must be
   `Bearer <token>` (case-insensitive scheme, one space) — a malformed value is 401, not a
   fallthrough. Otherwise look up `X-Api-Key` and take its value verbatim. Neither header →
   401. `Authorization` wins when both are present (Decision Log).
2. `lookupApiKey pool (hashToken (Token token))`. `Nothing` → 401 ("unknown or revoked
   credential" — deliberately the *same* message as missing, so responses do not oracle which
   tokens exist). A pool/`UsageError` failure → 503 ("credential store unavailable").
3. Return the principal.

`ingestAuthHandler` wraps the result in `IngestPrincipal` — both kinds may ingest.
`metricsAuthHandler` additionally rejects `kind == WriteKey` with **403** ("write keys cannot
read metrics") — the credential is real, the permission is absent, which is exactly the
401-versus-403 distinction. Error bodies use the service's JSON error envelope: before plan
9's Milestone 4 lands that is the `jsonError` shape already in the handlers
(`{"error": <message>, "details": …}` with `content-type: application/json`); after it lands,
match the plan 9 envelope (which adds a machine-readable `code`; use `"unauthorized"`,
`"forbidden"`, `"auth_store_unavailable"`). Add `WWW-Authenticate: Bearer` to 401 responses.
Note for the implementer: these 401/403s are thrown from the `AuthHandler`, *outside* plan 9's
`MultiVerb` result sums — that is correct and expected (pre-handler rejections), and it is why
2b writes them into the document by hand.

To make this testable without Postgres, factor the core as
`authenticateWith :: (Text -> IO (Maybe AuthenticatedPrincipal)) -> Request -> Handler
AuthenticatedPrincipal` (taking the *lookup-by-hash* function) and let the pool variants
partially apply it with the real store.

**2d. Wiring.** In the server assembly (plan 9's `kansoku-core/src/Kansoku/Server.hs`), switch
`serve kansokuApi …` to `serveWithContext kansokuApi (authContext pool) …` (if plan 9's
`ErrorFormatters` context is already present, append the two auth handlers to it — `Context`
is a heterogeneous cons-list, order irrelevant here because the three entry types differ).
The umbrella server record becomes:

```haskell
kansokuServer pool queueName conn =
  KansokuAPI
    { ingest = \authed -> ingestServer pool queueName (authed ^. #principal),
      metrics = \authed -> metricsServer conn (authed ^. #principal)
    }
```

**2e. Stamping.** `kansoku-core/src/Kansoku/Ingest/Handler.hs`: `ingestServer` gains the
`AuthenticatedPrincipal` parameter; both handlers stamp each event right where `receivedAt` is
already stamped:

```haskell
stamp event =
  event
    & #receivedAt .~ now
    & #accountId ?~ AccountId (authed ^. #accountId)
```

(`?~` sets a `Maybe` field to `Just`.) Validation runs *after* stamping, so validation rules
see the final event. Nothing else in the pipeline changes: the writer already maps
`accountId` into the `account_id` column that leads the `events_raw` sort key
(`kansoku-core/src/Kansoku/ClickHouse/EventRow.hs`, `eventRowFromEvent`).

**2f. Client.** `kansoku-client/src/Kansoku/Client.hs`: with `AuthProtect` in the route type,
the generated client functions take an `AuthenticatedRequest (AuthProtect "kansoku-ingest")`.
Add to the client module:

```haskell
type instance AuthClientData (AuthProtect "kansoku-ingest") = Text

kansokuCredential :: Text -> AuthenticatedRequest (AuthProtect "kansoku-ingest")
kansokuCredential token =
  mkAuthenticatedRequest token (\t -> addHeader "Authorization" ("Bearer " <> t))
```

(from `Servant.Client.Core`; the SDK's public helpers take the token `Text` once and thread
the authenticated request). Do the analogous instance for `"kansoku-metrics"` if/when the SDK
exposes metrics calls. Update the client test suite: its warp-backed fake server must now be
served with a permissive auth context.

**2g. Tests.** New spec `kansoku-core/test/Kansoku/Auth/HandlerSpec.hs`: build a tiny wai
`Application` with `serveWithContext` over the real `KansokuAPI` record, sentinel route
handlers, and auth handlers built from `authenticateWith` over an in-memory
`Map Text AuthenticatedPrincipal` (keyed by token hash) containing one write key and one
service token. Assert: no header → 401 with JSON body and `WWW-Authenticate`; unknown token →
401; `X-Api-Key` with the write key on `POST /v1/events` → the sentinel 202; `Authorization:
Bearer` with the same write key → 202 (both headers work); write key on `GET
/metrics/events?...` → 403; service token on the same → sentinel 200; both headers present
with a bad `X-Api-Key` and a good `Authorization` → 202 (precedence). Also update plan 9's
`kansoku-core/test/Kansoku/Metrics/RoutingSpec.hs`: its sentinel server now needs the auth
context and an authenticated request per call — give it a stub context whose handlers always
succeed with a fixed service-token principal, so the dispatch assertions stay exactly as plan
9 specified them.

```text
feat(auth): require write keys or service tokens on ingest and stamp the account

MasterPlan: docs/masterplans/2-kansoku-production-hardening-review-fixes-and-portfolio-service-readiness.md
ExecPlan: docs/plans/15-api-keys-service-auth-and-account-scoped-queries.md
```

### Milestone 3 — Metrics authentication, account-scoped queries, and account-dimensioned rollups

Scope: the metrics family requires a service token; every SQL builder filters by the
principal's account; `events_resolved` and the four rollups gain the `account_id` dimension.
This milestone creates ClickHouse objects, so it goes **through EP-12's versioned migration
mechanism** — if EP-12 is not landed, stop and land it first (it always is in the MasterPlan's
ordering; see Context). Commands: `cabal build all && cabal test all`, apply the new
ClickHouse migration, run the isolation demo. Acceptance: write key on metrics → 403; the
two-account demo shows disjoint counts; `QuerySpec` proves the predicate is in every builder.

**3a. Metrics auth.** Already structurally done by Milestone 2 (`MetricsAuth` sits on the
`metrics` field; `metricsAuthHandler` enforces `ServiceToken`); this milestone's server work
is threading the principal *into the queries*: `metricsServer` (in
`kansoku-core/src/Kansoku/Metrics/Handler.hs`) takes the `AuthenticatedPrincipal` and its
`queryRequest` helper gains the account:

```haskell
queryRequest authed fromDay toDay groupBy timeGrain =
  Query.QueryRequest
    { from = fromDay,
      to = toDay,
      groupBy = nonEmptyCsv <$> groupBy,
      timeGrain,
      accountId = authed ^. #accountId
    }
```

**3b. The query compiler.** In `Kansoku.Metrics.Query` (pre-plan-9 name: `Kansoku.Query`),
add `accountId :: !Text` to `QueryRequest` (strict, non-Maybe — an account-less metrics query
must be unrepresentable), and a single helper:

```haskell
accountPredicate :: QueryRequest -> Text
accountPredicate req = "account_id = " <> sqlString (req ^. #accountId)
```

(if EP-13 has landed, route the value through its validated/parameterized input path instead
of `sqlString`, keeping the same "predicate present in every builder" acceptance). Then thread
it through **every** builder — the complete inventory, none optional:

- `countEventsSQL`, `propertyAggregateSQL`, `buildSessionsSQL`: append
  `AND <accountPredicate>` to the `WHERE` over `events_raw`.
- `uniqueUsersSQL`: same, over `events_resolved` (column exists after 3c).
- `buildRatioSQL`: add it to **both** the numerator and denominator subselects.
- `buildRetentionSQL`: add it to **both** CTEs (`first_seen` and `activity`).
- `buildFunnelSQL`: add it to every step's `WHERE` **and** to every
  `canonical_user IN (SELECT … )` previous-step subquery — a funnel that scopes steps but not
  the membership subqueries silently mixes tenants' users into step qualification.
- `activeUsersDaySQL` / `activeUsersWeekSQL` / `pageViewsDaySQL`: add
  `WHERE <accountPredicate> AND day >= … ` (the rollups have the column after 3d; the
  `GROUP BY`/`ORDER BY` stay on `day`/`week`/`route` since the account is fixed per query).

The value never comes from a query parameter — only from `QueryRequest.accountId`, which only
`queryRequest` constructs, which only reads the principal. That chain is the tenancy
guarantee.

**3c. `events_resolved` gains `account_id`.** New ClickHouse migration (through EP-12's
mechanism; number it after EP-12's last). Against the current view definition
(`db/clickhouse/migrations/0002_identity.sql`) the delta is exactly "add `e.account_id AS
account_id` to the SELECT list"; EP-12's landed FINAL-free v2 definition may differ in *how*
it resolves `canonical_user` — keep EP-12's resolution untouched and apply the same
one-column delta (and if EP-12's v2 already includes the column, record that in Surprises &
Discoveries and skip this file). Shown against the current shape:

```sql
CREATE OR REPLACE VIEW analytics.events_resolved
AS
SELECT
    e.event_id AS event_id,
    e.event_name AS event_name,
    e.occurred_at AS occurred_at,
    e.url AS url,
    e.account_id AS account_id,
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
```

**3d. Rollups gain the account dimension.** Same migration file. An `AggregatingMergeTree`
table cannot have a new column *prepended* to its sort key in place, and the rollups are pure
derivations of `events_raw`, so the safe move is drop-recreate-backfill per rollup: drop the
MV first (stops the trigger), drop the table, create the table with `account_id String`
leading the `ORDER BY`, create the MV with `account_id` in `SELECT` and `GROUP BY`, then
backfill with an `INSERT … SELECT` that is textually identical to the MV body. Shown in full
for `daily_event_counts` and `dau`; `wau` follows `dau` with `toMonday`/`week`, and
`page_views_by_route` follows `daily_event_counts` with its `route`/`page_view` specifics —
write all four out in the actual migration file:

```sql
DROP VIEW IF EXISTS analytics.mv_daily_event_counts;
DROP TABLE IF EXISTS analytics.daily_event_counts;

CREATE TABLE analytics.daily_event_counts
(
    account_id String,
    day        Date,
    event_name String,
    events     AggregateFunction(uniqExact, String)
)
ENGINE = AggregatingMergeTree
ORDER BY (account_id, day, event_name);

CREATE MATERIALIZED VIEW analytics.mv_daily_event_counts
TO analytics.daily_event_counts
AS
SELECT
    account_id,
    toDate(occurred_at) AS day,
    event_name AS event_name,
    uniqExactState(toString(event_id)) AS events
FROM analytics.events_raw
GROUP BY account_id, day, event_name;

INSERT INTO analytics.daily_event_counts
SELECT
    account_id,
    toDate(occurred_at) AS day,
    event_name AS event_name,
    uniqExactState(toString(event_id)) AS events
FROM analytics.events_raw
GROUP BY account_id, day, event_name;

DROP VIEW IF EXISTS analytics.mv_dau;
DROP TABLE IF EXISTS analytics.dau;

CREATE TABLE analytics.dau
(
    account_id String,
    day        Date,
    users      AggregateFunction(uniqExact, String)
)
ENGINE = AggregatingMergeTree
ORDER BY (account_id, day);

CREATE MATERIALIZED VIEW analytics.mv_dau
TO analytics.dau
AS
SELECT
    account_id,
    toDate(occurred_at) AS day,
    uniqExactState(<canonical-user-expression>) AS users
FROM analytics.events_raw
WHERE <canonical-user-expression> != ''
GROUP BY account_id, day;

INSERT INTO analytics.dau
SELECT
    account_id,
    toDate(occurred_at) AS day,
    uniqExactState(<canonical-user-expression>) AS users
FROM analytics.events_raw
WHERE <canonical-user-expression> != ''
GROUP BY account_id, day;
```

`<canonical-user-expression>` is **EP-12's landed join-free expression** — do not resurrect
the pre-EP-12 insert-time `LEFT JOIN identity_map` (the review found it grows with total
identities; removing it is EP-12's whole point). If for some reason EP-12's rollups kept a
different shape or names, apply the same mechanical delta — `account_id` into the table,
leading the `ORDER BY`, into the MV/backfill `SELECT` and `GROUP BY` — and record the deltas
in Surprises & Discoveries. Backfilled rows from pre-auth data land under `account_id = ''`,
a bucket no authenticated query can ever select (see Idempotence).

**3e. Tests.** Extend `kansoku-core/test/Kansoku/QuerySpec.hs`: give the shared `dayRequest`
fixture `accountId = "acct_test"`, update the exact-string expectations (`activeUsersDaySQL`
and the others now contain `WHERE account_id = 'acct_test'` clauses), and add a completeness
spec that maps over *every* builder — `buildSQL` over a `Simple` count metric, a `UniqueCount`
metric, a `Sum` metric, an `active_users` day and week request, a `page_views` day request
(grouped and ungrouped), `Ratioed`, plus `buildSessionsSQL`, `buildRetentionSQL`, and
`buildFunnelSQL` with three steps — asserting each output contains
`account_id = 'acct_test'`, and for the funnel that the *count of occurrences* equals steps
plus previous-step subqueries (for 3 steps: 3 + 3 = 6), so a forgotten subquery fails. Add a
negative guard: an account value containing `'` renders escaped (via the existing `sqlString`
behavior), e.g. `accountId = "acc't"` produces `account_id = 'acc\'t'`.

```text
feat(metrics): require service tokens and scope every metric query by account

MasterPlan: docs/masterplans/2-kansoku-production-hardening-review-fixes-and-portfolio-service-readiness.md
ExecPlan: docs/plans/15-api-keys-service-auth-and-account-scoped-queries.md
```


## Concrete Steps

All commands run from the repository root
`/Users/shinzui/Keikaku/bokuno/kansoku-project/kansoku`, inside `nix develop`. Keep this
section updated with what was actually run.

Milestone 1, after the code edits:

```bash
cabal build all
cabal test all
just up            # in another terminal; starts postgres + clickhouse
cabal run kansoku-server -- issue-key --kind write --account acct_alpha --description "demo"
```

Expected (uuid and token vary):

```text
issued write_key 6f3e9d0a-4c1b-4b7e-9a52-1de1c2a4b970 for account acct_alpha
ksk_w_Uv38ByGCZU8WP18PmmIdcpVmx00QA3xNe7sEB9Hixkk
store this token now; it cannot be shown again
```

Verify hash-at-rest and ledger:

```bash
psql -d kansoku -c "select kind, account_id, left(token_hash, 12) as hash_prefix, revoked_at from kansoku.api_keys"
psql -d kansoku -c "select filename from kansoku.schema_migrations order by filename"
```

```text
    kind    | account_id | hash_prefix  | revoked_at
------------+------------+--------------+------------
 write_key  | acct_alpha | 91b4c1f22a0e |
(1 row)

   filename
---------------
 0001_api_keys
(1 row)
```

Milestone 2, after edits (server running via `just run` in another terminal):

```bash
cabal run kansoku-openapi && git diff --exit-code docs/api/openapi.json   # regenerated doc is committed
curl -si http://localhost:8080/v1/events -H 'content-type: application/json' -d @/tmp/e.json | head -3
```

```text
HTTP/1.1 401 Unauthorized
WWW-Authenticate: Bearer
Content-Type: application/json
```

Then with the Milestone 1 write key (either header form):

```bash
curl -si http://localhost:8080/v1/events \
  -H 'content-type: application/json' \
  -H 'X-Api-Key: ksk_w_Uv38ByGCZU8WP18PmmIdcpVmx00QA3xNe7sEB9Hixkk' \
  -d '{"eventId":"evt-m2-1","eventName":"page_view","source":"web","occurredAt":"2026-07-15T12:00:00Z","receivedAt":"2026-07-15T12:00:00Z","accountId":"acct_SPOOFED","anonymousId":"anon-1","url":"https://example.test/pricing","properties":{},"context":{}}' | head -1
sleep 6   # writer max latency is 5000 ms
clickhouse-client --port $CLICKHOUSE_TCP_PORT --query \
  "SELECT account_id FROM analytics.events_raw WHERE event_id = 'evt-m2-1'"
```

```text
HTTP/1.1 202 Accepted
acct_alpha
```

The spoofed `acct_SPOOFED` never reaches storage — that single line is the tenancy-stamping
proof. Milestone 3 commands are the isolation demo in Validation and Acceptance, plus:

```bash
just ch-migrate    # or EP-12's replacement recipe — apply the new versioned migration
cabal test all
```


## Validation and Acceptance

Everything below assumes `just up` services, migrations applied (`just ch-migrate` or EP-12's
successor recipe), and `just run` in another terminal. The unit-level acceptance is
`cabal test all` green, which now includes `Kansoku.Auth.TokenSpec`,
`Kansoku.Auth.HandlerSpec` (the 401/403 matrix over an in-memory key store — no Postgres
needed), the extended `Kansoku.QuerySpec` (account predicate in every builder), and plan 9's
routing spec still green under the auth context.

The behavioral acceptance is the **two-account isolation demo**. Issue four keys and capture
the tokens (each `issue-key` prints its token on the second line):

```bash
cabal run kansoku-server -- issue-key --kind write   --account acct_alpha
cabal run kansoku-server -- issue-key --kind service --account acct_alpha
cabal run kansoku-server -- issue-key --kind write   --account acct_beta
cabal run kansoku-server -- issue-key --kind service --account acct_beta
```

Call the tokens `$WA`, `$SA`, `$WB`, `$SB`. The 401/403/2xx matrix:

```bash
curl -s -o /dev/null -w '%{http_code}\n' 'http://localhost:8080/metrics/events?from=2026-07-14&to=2026-07-17'
curl -s -o /dev/null -w '%{http_code}\n' -H "X-Api-Key: $WA" 'http://localhost:8080/metrics/events?from=2026-07-14&to=2026-07-17'
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $SA" 'http://localhost:8080/metrics/events?from=2026-07-14&to=2026-07-17'
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/health
```

```text
401
403
200
200
```

(the 401 body is JSON: `{"error":"unauthorized","details":["missing or unknown credential"]}`
— exact envelope per whichever error shape is live, see Milestone 2c). Ingest two events for
alpha and three for beta, each through *its own account's write key*, with distinct
`eventId`s, `eventName` `"demo_event"`, and `occurredAt` `2026-07-15T12:0N:00Z`:

```bash
for i in 1 2; do
  curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/v1/events \
    -H 'content-type: application/json' -H "X-Api-Key: $WA" \
    -d "{\"eventId\":\"iso-a-$i\",\"eventName\":\"demo_event\",\"source\":\"web\",\"occurredAt\":\"2026-07-15T12:0$i:00Z\",\"receivedAt\":\"2026-07-15T12:00:00Z\",\"anonymousId\":\"anon-a\",\"properties\":{},\"context\":{}}"
done
for i in 1 2 3; do
  curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/v1/events \
    -H 'content-type: application/json' -H "X-Api-Key: $WB" \
    -d "{\"eventId\":\"iso-b-$i\",\"eventName\":\"demo_event\",\"source\":\"web\",\"occurredAt\":\"2026-07-15T12:0$i:00Z\",\"receivedAt\":\"2026-07-15T12:00:00Z\",\"anonymousId\":\"anon-b\",\"properties\":{},\"context\":{}}"
done
sleep 6
```

(five `202` lines; the sleep outwaits the writer's 5000 ms max flush latency). Now the same
query with each account's service token:

```bash
curl -s -H "Authorization: Bearer $SA" 'http://localhost:8080/metrics/events?from=2026-07-15&to=2026-07-16' | python3 -m json.tool
curl -s -H "Authorization: Bearer $SB" 'http://localhost:8080/metrics/events?from=2026-07-15&to=2026-07-16' | python3 -m json.tool
```

```json
{
    "metric": "events",
    "points": [
        {
            "bucket": "2026-07-15",
            "group": {},
            "value": 2.0
        }
    ]
}
```

```json
{
    "metric": "events",
    "points": [
        {
            "bucket": "2026-07-15",
            "group": {},
            "value": 3.0
        }
    ]
}
```

Acceptance is exactly this: alpha sees `2.0`, beta sees `3.0`, on the same endpoint, same
range, same instance — disjoint by credential alone. For rollup coverage, repeat the pair of
queries against `('/metrics/users?from=2026-07-15&to=2026-07-16&timeGrain=day'`) — the
day-grain active-users path reads `analytics.dau`, so alpha/beta seeing `1.0`/`1.0` from
*their own* single anonymous user (and not `2.0` from a shared account-blind rollup) proves
the account dimension reached the rollups. Finally, revocation:
`psql -d kansoku -c "update kansoku.api_keys set revoked_at = now() where account_id = 'acct_beta'"`,
then the `$SB` metrics query returns 401 on the next request.


## Idempotence and Recovery

Everything here is safe to re-run. `migrateKansoku` is checksum-ledgered: reapplying is a
no-op, and *changing* an applied script fails loudly at startup with hasql-migration's
`ScriptChanged` — the fix is always a new numbered script, never an edit. The `api_keys` DDL
itself is additionally `if not exists`-guarded, so even a lost ledger row cannot double-create.
`issue-key` is not idempotent by design (each run mints a new credential); a half-failed run
(generated but insert failed) leaks nothing because the token was never printed or stored.
Recovery from a mis-issued key is revocation (`update … set revoked_at = now()`), never
deletion.

The Milestone 3 ClickHouse migration is guarded by EP-12's versioned mechanism (applied
exactly once). Its drop-recreate-backfill of rollups destroys no source data — `events_raw` is
the source of truth and the backfill `INSERT … SELECT` fully reconstructs each rollup. If a
backfill fails midway, recovery is `TRUNCATE TABLE analytics.<rollup>` then re-running the
`INSERT` — do this while the writer is stopped or accept that the MV double-counts rows
inserted between truncate and backfill (in dev, just stop `just run` first). Rows ingested
before authentication existed carry `account_id = ''` in `events_raw` and therefore in the
backfilled rollups; they are invisible to every account-scoped query by construction. If that
pre-auth data ever matters in a real deployment, the remedy is an explicit one-off
`ALTER TABLE analytics.events_raw UPDATE account_id = '<owner>' WHERE account_id = ''` plus a
rollup re-backfill — deliberately out of scope here and recorded so nobody is surprised.

Auth rollback: because enforcement is a type-level declaration plus a context entry, reverting
the Milestone 2/3 commits restores the unauthenticated service exactly; there is no
data-format coupling (the `api_keys` table and stamped `account_id` values are inert to old
code).


## Interfaces and Dependencies

Libraries (all already pinned or in the dependency closure; added to `build-depends` where
named): `servant` / `servant-server` for `Servant.API.Experimental.Auth (AuthProtect)` and
`Servant.Server.Experimental.Auth (AuthHandler, AuthServerData, mkAuthHandler)` plus
`serveWithContext`/`Context`; `servant-client-core` in `kansoku-client` for
`AuthClientData`/`mkAuthenticatedRequest`; the pinned `shinzui/hasql-migration` fork plus
`hasql-transaction` for kansoku's Postgres migrations; `crypton` for `Crypto.Random
(getRandomBytes)` and `Crypto.Hash (SHA256, hashWith)`; `base64-bytestring` for
`Data.ByteString.Base64.URL (encodeUnpadded)`; `uuid` for `ApiKeyId`; the pinned local
`openapi-hs` (security-scheme data types) and `servant-openapi-hs` (`HasOpenApi` — the
`AuthProtect` instances are written locally per Surprises & Discoveries).

Modules and signatures that must exist at the end of each milestone (full module paths;
post-plan-9 layout):

Milestone 1 — `Kansoku.Postgres.Migration` (`kansoku-core`): `migrateKansoku :: Pool.Pool ->
IO ()`, `kansokuMigrations :: [(String, ByteString)]`. `Kansoku.Auth.Types` (`kansoku-core`):
`CredentialKind (..)`, `credentialKindText :: CredentialKind -> Text`, `parseCredentialKind ::
Text -> Maybe CredentialKind`, `ApiKeyId (..)`, `AuthenticatedPrincipal (..)`,
`IngestPrincipal (..)`, `MetricsPrincipal (..)`. `Kansoku.Auth.Token` (`kansoku-core`):
`Token (..)`, `generateToken :: CredentialKind -> IO Token`, `hashToken :: Token -> Text`,
`tokenKind :: Text -> Maybe CredentialKind`. `Kansoku.Auth.Store` (`kansoku-core`):
`insertApiKey :: Pool.Pool -> CredentialKind -> Text -> Text -> Text -> IO ApiKeyId`,
`lookupApiKey :: Pool.Pool -> Text -> IO (Maybe AuthenticatedPrincipal)`.
`Kansoku.Auth.Issue` (`kansoku-core`): `issueKey :: Pool.Pool -> CredentialKind -> Text ->
Text -> IO (ApiKeyId, Token)`. `kansoku-server/app/Main.hs`: argv dispatch (`[]` → server;
`issue-key` → issuance).

Milestone 2 — `Kansoku.Auth.Api` (`kansoku-api`): `type IngestAuth = AuthProtect
"kansoku-ingest"`, `type MetricsAuth = AuthProtect "kansoku-metrics"`; umbrella `KansokuAPI`
fields wrapped as `IngestAuth :> NamedRoutes IngestRoutes` / `MetricsAuth :> NamedRoutes
MetricsRoutes`. `Kansoku.Api.OpenApi` (`kansoku-api`): the two `HasOpenApi (AuthProtect … :>
sub)` instances and `securitySchemes` registration. `Kansoku.Auth.Handler` (`kansoku-core`):
`AuthServerData` type instances, `authenticateWith :: (Text -> IO (Maybe
AuthenticatedPrincipal)) -> Request -> Handler AuthenticatedPrincipal`, `ingestAuthHandler ::
Pool.Pool -> AuthHandler Request IngestPrincipal`, `metricsAuthHandler :: Pool.Pool ->
AuthHandler Request MetricsPrincipal`, `authContext :: Pool.Pool -> Context '[AuthHandler
Request IngestPrincipal, AuthHandler Request MetricsPrincipal]`. `Kansoku.Ingest.Handler`:
`ingestServer` takes the principal and stamps `#accountId`. `Kansoku.Client`
(`kansoku-client`): `AuthClientData` instance(s) and `kansokuCredential :: Text ->
AuthenticatedRequest (AuthProtect "kansoku-ingest")`.

Milestone 3 — `Kansoku.Metrics.Query` (`kansoku-core`): `QueryRequest` with `accountId ::
!Text`; `accountPredicate :: QueryRequest -> Text`; every exported builder (`buildSQL`,
`buildSessionsSQL`, `buildRetentionSQL`, `buildFunnelSQL` and the internal per-metric SQL
functions) emits the predicate. `Kansoku.Metrics.Handler`: `metricsServer` takes the
principal; `queryRequest` sets `accountId`. One new ClickHouse migration through EP-12's
mechanism: `events_resolved` with `account_id`, four rollups rebuilt with `account_id` leading
their `ORDER BY`, MVs and backfills to match.

Services: PostgreSQL (database `kansoku`) via the existing hasql pool for key storage and the
migration ledger; ClickHouse (database `analytics`) for everything the queries read. No new
processes, no new config, no new ports.

---

Revision note (2026-07-15, coordination update after plan authoring): the operator will run
the `migrate-keiro-stack` seihou blueprint
(`/Users/shinzui/Keikaku/bokuno/agent-seihou/blueprints/migrate-keiro-stack`) before MP-2
implementation begins. That blueprint establishes pg-migrate as the application's Postgres
migration framework (an ordered `pgmq -> application` component plan with a strict manifest),
which supersedes this plan's provisional Milestone 1 choice of the pinned hasql-migration
fork for the `kansoku.api_keys` migration. At implementation start, Milestone 1's implementer
must inspect the post-blueprint tree: if a pg-migrate application manifest exists, author the
`api_keys` DDL as a pg-migrate component in that plan (the blueprint's
`files/pg-migrate-implementation-reference.md` documents the authoring pattern) and record
the delta in this plan's Decision Log; the schema design, token format, issuance subcommand,
enforcement, and tenancy milestones are unaffected. Only the migration *mechanism* changes.
