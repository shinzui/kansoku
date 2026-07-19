---
id: 7
slug: haskell-server-sdk
title: "Haskell server SDK"
kind: exec-plan
created_at: 2026-07-01T16:04:44Z
intention: "intention_01kwf425fxenc904ear54cr2n7"
master_plan: "docs/masterplans/1-kansoku-analytics-service-mvp.md"
---

# Haskell server SDK

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Kansoku (観測, "observation") is a first-party analytics service being built in this
repository. It ingests analytics events over HTTP, stores them durably in ClickHouse (a
columnar SQL database optimized for high-volume append-only inserts), and answers metric
queries. The full product specification is in `docs/initial-spec.md` at the repository root,
and the overall plan is in `docs/masterplans/1-kansoku-analytics-service-mvp.md`.

Today a Haskell backend service that wants to record an authoritative business fact — a user
registered, a subscription started, a payment completed, a background job finished — has no
convenient way to send that fact to Kansoku. It would have to hand-assemble JSON, open its
own HTTP connection, and worry about batching and retries itself. This plan removes that
burden.

After this plan is complete, any Haskell backend service can add one dependency
(`kansoku-client`) and emit analytics events with a few lines of code:

```haskell
import Kansoku.Client

main :: IO ()
main =
  withClient (defaultClientConfig "http://localhost:8080") $ \client -> do
    -- Record an authoritative server-side fact. Identity ids (userId etc.) are
    -- first-class fields on the event, passed via EventIds; the pairs list
    -- feeds ONLY the free-form `properties` object.
    trackEvent client (emptyIds & #userId ?~ "user_42") "user_registered"
      [ "plan" .= ("pro" :: Text)
      ]
    -- Events are buffered and delivered in the background; flush before exit.
    flush client
```

What someone can do after this change that they could not before: a running backend service
can call `track`/`trackEvent`/`identify`/`group`/`alias`, and — with a Kansoku server running
— those events arrive in the ClickHouse `analytics.events_raw` table without the caller
writing any HTTP, JSON, batching, or retry code. The SDK batches events by default (many
events per HTTP request), retries transient network failures with backoff, and never blocks
the caller's business logic waiting on the network.

How the SDK talks to the server (the load-bearing architectural decision of this plan): the
client is **derived with `genericClient` from the same `IngestRoutes` record the ingestion
server exposes.** Both server and SDK import `Kansoku.Ingest.Api` from the shared
`kansoku-api` package. Because the client record is generated from that one type, the SDK's request shape is
provably identical to the server's — client/server contract drift is impossible at the type
level, not merely guarded by a test. This is why EP-7 now **hard-depends on EP-4**: it
imports `Kansoku.Ingest.Api` (`IngestRoutes`), which EP-4 owns.

How you can see it working: the integration milestone (Milestone 3) starts a real
`kansoku-server`, emits a known number of events through the SDK, and asserts they appear in
`analytics.events_raw` by running a `clickhouse-client` `COUNT(*)` query. That is the
observable, human-verifiable outcome.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Milestone 0: Confirm the two upstream artifacts this plan reuses — read
      `src/Kansoku/Event.hs` to learn the exact `AnalyticsEvent` record, its field names, its
      `ToJSON`/`FromJSON` instances, the id newtypes, and any id generator; and read EP-4's
      servant API type `Kansoku.Api.Ingest` (`IngestAPI`) that this plan derives its client
      from — and record any mismatch with the assumptions in this plan in Surprises &
      Discoveries.
- [x] Milestone 1: Ensure the shared public sub-library `kansoku:kansoku-api` exists in
      `kansoku.cabal`, exposing the event model (`Kansoku.Event`, `Kansoku.Event.Registry`,
      `Kansoku.Event.Validation`) and the servant API *type declarations only*
      (`Kansoku.Api.Ingest` with `IngestAPI`, `Kansoku.Api.Metrics`, `Kansoku.Api`) with
      dependencies on `servant` + aeson/base/text/time/containers/uuid — NOT `servant-server`,
      NOT `warp`. The SDK reuses both the event type and the `IngestAPI` type from it without
      pulling in the server's ClickHouse/pgmq/servant-server/warp dependencies. Verify the main
      `kansoku` library and `kansoku-server` executable still build (`cabal build all`).
- [x] Milestone 1: Create the `kansoku-client/` package directory with
      `kansoku-client/kansoku-client.cabal` and the module `Kansoku.Client` exposing `Client`,
      `ClientConfig`, `defaultClientConfig`, `newClient`, `withClient`, `close`, `flush`,
      `EventIds`, `emptyIds`, `track`, `trackEvent`, `identify`, `group`, `alias`. Add
      `./kansoku-client` to `cabal.project`'s `packages:` stanza.
- [x] Milestone 1: Derive the servant client from `IngestAPI` with
      `postEvent :<|> postBatch = client (Proxy @IngestAPI)`; implement event construction with
      sensible defaults (auto-generate `eventId`, set `occurredAt` to now, set
      `source = Service`) and a synchronous single-event path that runs `postEvent evt` via
      `runClientM` on a shared `ClientEnv`. Add unit tests proving each helper builds a
      well-formed `AnalyticsEvent`, that the client compiles against `IngestAPI`, and that an
      event round-trips through the shared type (the shared `IngestAPI`/`AnalyticsEvent` type is
      the drift guard — there is no separate golden-JSON test needed).
- [x] Milestone 1: `cabal test kansoku-client` is green (unit tests, no running server needed).
- [x] Milestone 2: Add the in-memory bounded buffer (`TBQueue`), a background flush thread,
      flush-on-size and flush-on-time-interval, delivery by running the `postBatch` client
      function (`POST /v1/batch`) via `runClientM`, bounded retry with exponential backoff on
      transient failures, and the overflow drop-newest policy with a dropped-event counter.
      Ensure `eventId` is generated once and reused across retries.
- [x] Milestone 2: Add unit/behavioral tests for batching (buffer flushes at size and at
      interval), retry (a stub HTTP endpoint that fails N times then succeeds), and overflow
      (buffer past capacity increments the drop counter). `cabal test kansoku-client` green.
- [x] Milestone 3: Add an integration test (guarded so it is skipped when no server is
      configured) that, against a running `kansoku-server` + ClickHouse, emits a known set of
      events through the SDK, flushes, and asserts the rows appear in `analytics.events_raw` via
      a `clickhouse-client` count. Document the exact commands and expected output.
- [x] Milestone 3: Provide the runnable example program (`kansoku-client/example/Main.hs` or
      documented inline) and confirm it produces the observable ClickHouse rows.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The `kansoku-api` sub-library existed but was private to the `kansoku` package. Cabal
  rejected `kansoku-client`'s dependency on `kansoku:kansoku-api` until the stanza gained
  `visibility: public`.
- EP-2's actual `AnalyticsEvent` has a required `receivedAt :: UTCTime`, and `baseEvent`
  requires both `occurredAt` and `receivedAt`. The SDK therefore sets both timestamps to the
  same client-side `now`; the server may still overwrite `receivedAt` on ingestion.
- Aeson exposes the `Pair` type from `Data.Aeson.Types`, not `Data.Aeson`, in this environment.
  The public helper signatures use `[Pair]`.
- The Warp-backed client tests require the threaded runtime. The `kansoku-client-test` stanza
  uses `ghc-options: -threaded`.


## Decision Log

Record every decision made while working on the plan.

- Decision: Deliver the SDK as a separate Cabal package `kansoku-client` (its own directory
  `kansoku-client/` with `kansoku-client.cabal`, added to `cabal.project`'s `packages:`
  stanza), NOT as new `Kansoku.Client.*` modules inside the existing `kansoku.cabal` library.
  Rationale: `docs/initial-spec.md` lists `kansoku-haskell` (the server SDK) as its own
  component under "Initial Components" (docs/initial-spec.md:480). A server
  SDK is imported by arbitrary backend services; it must not force them to compile the server's
  heavy dependencies (ClickHaskell, pgmq, servant-server, warp, shibuya). A separate package
  keeps the SDK's dependency footprint small and lets it be published independently.
  Date: 2026-07-01

- Decision: Reuse both the `AnalyticsEvent` type (EP-2) and the servant ingestion API type
  `Kansoku.Api.Ingest.IngestAPI` (EP-4) rather than re-declaring either, and obtain them via a
  shared public Cabal **sub-library** named `kansoku-api` declared in `kansoku.cabal`. This
  sub-library exposes the event model (`Kansoku.Event`, `Kansoku.Event.Registry`,
  `Kansoku.Event.Validation`) AND the servant API *type declarations only* — no handlers, no
  `warp` server — namely `Kansoku.Api.Ingest` (`IngestAPI` = the two ingestion endpoints, owned
  by EP-4), `Kansoku.Api.Metrics` (owned by EP-6), and `Kansoku.Api` (the combined
  `KansokuAPI`). Its `build-depends` are `servant` + `aeson`, `base`, `text`, `time`,
  `containers`, `uuid` — deliberately NOT `servant-server` and NOT `warp`. The main `kansoku`
  library, the `kansoku-server` executable (via EP-4), and `kansoku-client` all depend on this
  one sub-library. `kansoku-client` depends on `kansoku:kansoku-api` and NOT on the full
  `kansoku` library.
  Rationale: The MasterPlan's Integration Points pin the `AnalyticsEvent` record to the module
  `Kansoku.Event` in "package `kansoku`" (`src/Kansoku/Event.hs`) and pin the ingestion API to
  a servant type EP-4 owns. A Cabal public sub-library lives inside the same
  `kansoku.cabal`/package and keeps those module paths unchanged, so it fully respects the
  integration contract while letting the SDK import both the event type and the API type
  without dragging in the server's storage/queue/HTTP-server dependencies. Crucially, because
  the sub-library depends on `servant` alone (not `servant-server`/`warp`), importing
  `IngestAPI` to derive a `servant-client` is cheap and does not pull the server runtime into
  the SDK — which resolves the earlier objection that avoided `servant-client` (see the
  servant-client decision below). Dependency direction:
  `kansoku-client → kansoku:kansoku-api`, and `kansoku(main library) → kansoku:kansoku-api`;
  nothing heavy depends back on `kansoku-api`, so the graph stays acyclic and the SDK stays
  light. This decision SUPERSEDES the earlier `kansoku:kansoku-event` sub-library name this
  plan previously used: the sub-library is now `kansoku:kansoku-api` and holds the event model
  AND the API types.
  Fallback if importing `IngestAPI` proves impractical when this plan is executed (for example
  if `Kansoku.Api.Ingest` unexpectedly imports server-only modules): fix the sub-library so the
  API *type* has no server dependency (that is the whole point of the split); only as a last
  resort depend on the full `kansoku` library and accept the extra transitive dependencies, and
  record the change here. The clean split is strongly preferred.
  Date: 2026-07-01

- Decision: Use `servant-client`, deriving the client functions from the shared
  `Kansoku.Api.Ingest.IngestAPI` type in the `kansoku:kansoku-api` sub-library, NOT
  hand-written `http-client` + JSON, and NOT `req`. (This REVERSES the prior draft's decision to
  use `http-client` with hand-written JSON; see the Revision Note at the bottom.)
  Rationale: The human owner chose `servant-client` because it makes the client *provably the
  same shape as the server* — both `postEvent`/`postBatch` (the SDK) and EP-4's server handlers
  are generated from the *one* `IngestAPI` servant type, so the request paths, methods,
  content-types, and body encodings cannot drift; drift is prevented at the type level rather
  than merely caught by a test. The earlier objection to `servant-client` was that importing
  EP-4's API type would turn a soft dependency into a hard one and risk pulling
  `servant-server`/`warp` into the SDK. That objection is now resolved: the shared
  `kansoku:kansoku-api` sub-library holds the API *type declarations only* and depends on
  `servant` alone (not `servant-server`, not `warp`), so importing `IngestAPI` is cheap and
  server-free. Consequently EP-4 is now a HARD dependency of this plan (the SDK imports a type
  EP-4 owns), which is the correct relationship given the type-level coupling. The prior
  golden-JSON test is now redundant as a drift guard — drift is impossible because there is a
  single API type — so it is dropped; a lighter contract test (the client compiles against
  `IngestAPI` and an event round-trips through the shared type) is kept, and the Milestone-3
  integration test still exercises a running server end-to-end. `req` was rejected because it
  reintroduces hand-written request construction and offers none of servant-client's type-level
  drift guarantee.
  Date: 2026-07-01 (revised)

- Decision: The core SDK API is plain `IO`, not `effectful`.
  Rationale: `kansoku-client` is meant to be imported by any Haskell backend service, which may
  or may not run in the `effectful` effect system the Kansoku server uses. A plain-`IO` API
  (`track :: Client -> AnalyticsEvent -> IO ()`) is universally usable and keeps the SDK's
  dependency footprint minimal (no `effectful` dependency). An `effectful` wrapper can be
  layered on later in a separate module or package without changing the core; this is noted as
  a future extension, not built now.
  Date: 2026-07-01

- Decision: Batch by default. The SDK buffers events in memory and delivers them to
  `POST /v1/batch` when either a size threshold or a time-interval threshold is reached; a
  background thread performs the flushes. A single-event synchronous path to `POST /v1/events`
  exists only for Milestone 1 bring-up, but the default `track` path enqueues into the batch
  buffer.
  Rationale: The MasterPlan's whole write-path design exists to amortize per-write cost across
  many rows ("high write throughput ... amortizing the cost of each ClickHouse write across
  thousands of rows"). A server SDK that made one HTTP call per event would defeat that at the
  client edge and be unacceptable at volume. Batching at the client mirrors the server's batch
  ethos.
  Superseding note (2026-07-01): an earlier draft of this decision also promised an explicit
  "send now" convenience (`sendNow`). The final public API drops it — `flush` already covers
  the "deliver everything now" need, and a per-event synchronous escape hatch would invite
  callers to bypass batching in hot paths. Milestone 1's synchronous single-event helper is an
  internal stepping stone only: it exists to bring the derived `postEvent` client up before the
  buffer exists, and in Milestone 2 it is absorbed into (replaced by) the batched `track` path
  rather than exported. The exported emit surface is exactly `track`, `trackEvent`, `identify`,
  `group`, `alias`, plus `flush`/`close`.
  Date: 2026-07-01

- Decision: The convenience helpers take identity ids through a dedicated first-class record,
  `EventIds`, rather than through the `[Pair]` argument. `Kansoku.Client` exports
  `data EventIds = EventIds { userId, anonymousId, organizationId, accountId, sessionId ::
  !(Maybe Text) }` (strict fields, `deriving stock (Eq, Show, Generic)`) and
  `emptyIds :: EventIds` (all fields `Nothing`), and the helper signatures become
  `trackEvent :: Client -> EventIds -> Text -> [Pair] -> IO ()` and
  `group :: Client -> EventIds -> Text -> [Pair] -> IO ()`. The pairs list feeds ONLY the
  event's free-form `properties` object; the `EventIds` fields populate the corresponding
  first-class `AnalyticsEvent` identity fields. `identify` keeps taking the `userId` directly
  as its primary argument (that is what identify *is*), plus an optional `anonymousId` to
  stitch a pre-login anonymous history onto the user:
  `identify :: Client -> Text -> Maybe Text -> [Pair] -> IO ()`. `alias` is unchanged
  (`previousId`/`newId` are its whole payload). `track` with a caller-built `AnalyticsEvent`
  remains the escape hatch for anything the helpers do not cover.
  Rationale: `AnalyticsEvent` (EP-2, mirroring `docs/initial-spec.md`) carries `userId`,
  `anonymousId`, `organizationId`, `accountId`, and `sessionId` as first-class top-level
  fields, distinct from `properties`. The previous helper shape
  (`trackEvent :: Client -> Text -> [Aeson.Pair] -> IO ()`) gave callers no way to set those
  fields at all — a `"userId"` key in the pairs list would land inside `properties`, where the
  identity resolution and query layers would never see it. A small explicit record makes the
  distinction impossible to get wrong at the call site, keeps the common case terse
  (`emptyIds & #userId ?~ "user_42"` with generic-lens labels, per the house style), and avoids
  a long positional run of `Maybe Text` arguments.
  Date: 2026-07-01

- Decision: Delivery is at-least-once, and the SDK generates each event's `eventId` exactly
  once (at `track` time) and reuses that same id across all retries of that event.
  Rationale: EP-3 stores events in a ClickHouse `ReplacingMergeTree` keyed on `event_id`, so
  duplicate deliveries of the same `eventId` collapse on merge — retries are safe *only if the
  retried event carries the same id*. Generating the id once and holding it stable across
  retries is what makes at-least-once delivery correct end-to-end. If a helper regenerated the
  id on retry, every retry would create a distinct row and dedup would not help.
  Date: 2026-07-01

- Decision: On buffer overflow (producer faster than the network drain for a sustained period,
  buffer at capacity), drop the *newest* event and increment a counter that is logged, rather
  than blocking the calling thread.
  Rationale: A server SDK must never make the host service's business path hang on analytics
  back-pressure; losing some analytics events is preferable to stalling a payment handler. The
  buffer capacity, the drop policy, and the drop counter are all part of the public config/
  observability so operators can tune capacity and detect loss. (An alternative "block the
  caller" mode may be offered as an opt-in later, but drop-newest is the safe default.)
  Date: 2026-07-01

- Decision: `receivedAt` is populated by the SDK with the same client-side `now` used for
  `occurredAt`.
  Rationale: The original design preferred leaving `receivedAt` to the server, but EP-2's
  actual `AnalyticsEvent` type has a required `receivedAt :: UTCTime`, and `baseEvent` requires
  both timestamps. Setting both to the same value keeps the SDK's event construction total while
  still allowing the ingestion server to overwrite `receivedAt` if it chooses.
  Date: 2026-07-02

- Decision: Mark `library kansoku-api` with `visibility: public`.
  Rationale: A separate Cabal package cannot depend on a private sub-library. The SDK's intended
  dependency is `kansoku-client -> kansoku:kansoku-api`, so the shared servant/event sub-library
  must be public even though it still contains only lightweight type declarations and shared
  DTOs.
  Date: 2026-07-02

- Decision: Keep the exported helper property argument as `[Data.Aeson.Types.Pair]`.
  Rationale: In the Aeson version used by this project, `Pair` is exported from
  `Data.Aeson.Types`, not from `Data.Aeson`. This preserves the intended call-site ergonomics
  (`["plan" .= ("pro" :: Text)]`) while matching the real package API.
  Date: 2026-07-02


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

EP-7 is complete. The repository now has a separate `kansoku-client` Cabal package exposing
`Kansoku.Client`, a runnable `kansoku-client-example`, and a test suite. The SDK derives its
single-event and batch selectors from the shared `IngestRoutes` record, constructs service-source
`AnalyticsEvent`s with generated UUID event ids, buffers events in a bounded `TBQueue`, flushes
in batches, retries failed batches with stable event ids, drops newest events on overflow, and
reports the drop count.

Validation covered both the no-server and live-server paths. `cabal test kansoku-client`
passes with the integration case pending when `KANSOKU_SERVER_URL` is unset. With
`process-compose`, migrations, and `kansoku-server` running on port 18081,
`KANSOKU_SERVER_URL=http://127.0.0.1:18081 cabal test kansoku-client` passed all seven
examples and the integration test verified the emitted event in `analytics.events_raw` through
`clickhouse-client`.


## Context and Orientation

This section assumes you know nothing about this repository. Read it fully before editing.

This repository is a greenfield Haskell project built with a Nix flake, targeting GHC
9.12.4. The dev environment is entered with `nix develop` (or via `direnv`), which starts a
shell that provides `cabal`, `ghc`, PostgreSQL, and ClickHouse tooling. The Nix wiring is in
`nix/haskell.nix`; it builds the project with `haskellPackages.callCabal2nix "kansoku"`,
which expects a `kansoku.cabal` at the repository root. The dev shell exports environment
variables you will need later: `PG_CONNECTION_STRING`, `CLICKHOUSE_HOME`,
`CLICKHOUSE_TCP_PORT` (default `9000`), and `CLICKHOUSE_HTTP_PORT` (default `8123`). It also
puts a `clickhouse` binary on the PATH (so `clickhouse client` / `clickhouse-client` is
available) and `process-compose` for starting local services.

The overall system is decomposed into eight ExecPlans coordinated by
`docs/masterplans/1-kansoku-analytics-service-mvp.md`. This plan is EP-7, "the client
surface"; one more plan, EP-8 (OpenAPI documentation), lands after it. Three earlier plans
matter to you (EP-1, EP-2, and EP-4):

EP-1 (`docs/plans/1-project-skeleton-and-application-runtime.md`) creates the buildable
package: the root `kansoku.cabal` (a library stanza plus a `kansoku-server` executable) and
the root `cabal.project` (initially just `packages: .`). It also creates the `Kansoku.*`
module namespace and the test-suite wiring. You will extend `cabal.project` and `kansoku.cabal`.

EP-2 (`docs/plans/2-canonical-event-model-and-schema-registry.md`) defines the canonical
event vocabulary in the module `Kansoku.Event` (file `src/Kansoku/Event.hs`). It exposes the
`AnalyticsEvent` record, the `EventSource` enumeration, the `ToJSON`/`FromJSON` instances that
define the on-the-wire JSON, and the identity/id newtypes (and, per the shared repo context,
id helpers). This is the type your SDK constructs and serializes. **EP-7 hard-depends on
EP-2**: you reuse `AnalyticsEvent` and its JSON; you do not redefine them.

EP-4 (`docs/plans/4-ingestion-api-with-pgmq-queue-and-batched-clickhouse-writer.md`) defines
the HTTP ingestion API as the NamedRoutes record `IngestRoutes` in
`Kansoku.Ingest.Api`. A Servant route record describes the endpoints
(paths, methods, request/response bodies) at the type level; the same type can be interpreted
by `servant-server` to build a server (what EP-4 does) and by `servant-client` to *derive*
matching client-call fields (what this SDK does). This is the type interpreted as
`IngestRoutes (AsClientT ClientM)`. **EP-7 hard-depends on EP-4**: you import `IngestRoutes`
and generate the client record from it, so drift between the SDK and the server is impossible by
construction.

Both `Kansoku.Event` and `Kansoku.Ingest.Api` are delivered through the shared
`kansoku-api` Cabal package, described below and in the Decision Log. A
"public Cabal sub-library" is a second `library` stanza inside a single `.cabal` file
(`kansoku.cabal`) that can be depended on by name as `kansoku:kansoku-api`; it lets several
packages share the exact same modules without duplicating them. `kansoku-api` deliberately
depends on `servant` only (not `servant-server`, not `warp`), so importing the API *type* into
the SDK does not drag the server runtime along. (Note: this sub-library was called
`kansoku-event` in an earlier draft of this plan; it has been renamed to `kansoku-api` and now
carries the event model AND the API types.)

Definitions of terms used in this plan (defined here so the plan is self-contained):

- **Server SDK**: a small library a *backend service* imports so it can send analytics events
  to Kansoku. "Server-side analytics tells us what actually happened" (per `docs/initial-spec.md`):
  these are authoritative business facts emitted from backend code, e.g. `user_registered`,
  `subscription_started`, `payment_completed`, `background_job_completed`.
- **`AnalyticsEvent`**: the canonical event record owned by EP-2. Its TypeScript shape in
  `docs/initial-spec.md` is the normative field list: `eventId`, `eventName`,
  `source` (one of `web|app|service|worker|email|agent`), optional `sourceService`,
  `occurredAt`, `receivedAt`, optional identity ids (`anonymousId`, `userId`,
  `organizationId`, `accountId`, `sessionId`), optional web/UTM fields (`url`, `referrer`,
  `utmSource`, `utmMedium`, `utmCampaign`, `utmContent`, `utmTerm`), optional correlation
  fields (`correlationId`, `causationId`, `sourceEventId`, `sourceGlobalPosition`), and the
  `properties` and `context` objects.
- **`source = service`**: server SDK events are emitted from backend services, so their
  `source` field is the `service` variant of `EventSource`. The SDK sets this by default.
- **Batching**: accumulating several events in memory and sending them together in one HTTP
  request to `POST /v1/batch` (a JSON array), rather than one request per event.
- **Back-pressure / overflow**: the situation where events are produced faster than the SDK
  can deliver them, so the in-memory buffer fills up. The SDK's policy here is drop-newest
  (see Decision Log).
- **At-least-once delivery**: the SDK guarantees each event reaches the server *at least* once
  (it retries on failure), which means the server may receive the same event more than once;
  the server's ClickHouse `ReplacingMergeTree` deduplicates on `event_id`.
- **ClickHouse `ReplacingMergeTree` keyed on `event_id`**: the storage engine EP-3 uses; when
  it merges data parts it keeps one row per `event_id`, collapsing duplicates. This is why
  reusing the same `eventId` across retries makes retries harmless.
- **`TBQueue`**: a bounded transactional (STM) FIFO queue from the `stm` library; the SDK uses
  it as the in-memory event buffer because it gives thread-safe enqueue/dequeue with a capacity
  bound out of the box.

The EP-4 ingestion contract you target is the `IngestRoutes` record interpreted by
`genericClient`. The two endpoints and their bodies are described below in prose so
this plan is self-contained; the authoritative form is `Kansoku.Ingest.Api.IngestRoutes`,
and because you generate the client from that record you do not hand-encode any of it. EP-4
serves these two endpoints and sets `receivedAt` server-side:

```text
POST /v1/events
  Request body:  a single AnalyticsEvent, JSON-encoded (the exact JSON that
                 Kansoku.Event's ToJSON produces).
  Response:      202 Accepted on success (the event was validated and enqueued),
                 with a JSON IngestAck body (a DTO declared in Kansoku.Ingest.Api).

POST /v1/batch
  Request body:  a JSON array of AnalyticsEvent objects (the same per-element JSON
                 as /v1/events).
  Response:      202 Accepted on success (the batch was validated and enqueued),
                 with a JSON BatchAck body (a DTO declared in Kansoku.Ingest.Api).

Notes:
  - The client sets occurredAt, eventId, eventName, source, the identity ids, and
    properties/context. The server sets receivedAt.
  - Content-Type: application/json for both.
  - Each raw call returns an inner KansokuResult (202 or typed 400/404/503) inside
    runClientM's outer transport Either.
```

EP-4 is a **hard** dependency: the SDK imports EP-4's `IngestRoutes` record from
`kansoku-api` and derives its client fields from it, so EP-4's route type must exist
to compile the SDK. You can still build and unit-test the SDK without a *running* server (the
type is enough to generate and type-check the client), and you run the Milestone-3 integration
test once a `kansoku-server` built from EP-4 is up. Note the shared sub-library keeps this hard
dependency light: `kansoku-api` carries the API *type* only, so depending on it does not pull
in EP-4's server, queue, or ClickHouse code.

**Coding standards (read before writing any Haskell).** All Haskell in this repository — the
`kansoku-client` package included — follows the shared house style documented under
`/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/core/` (`standards.md`, `custom-prelude.md`,
`record-patterns.md`, `multiline-strings.md`). The load-bearing points the sketches below
already reflect: every stanza uses the GHC2024 language edition and a shared `common` cabal
stanza (`import: common`) that turns on `DeriveAnyClass`, `DuplicateRecordFields`,
`OverloadedLabels`, `OverloadedStrings`, and `MultilineStrings`; qualified imports are
postpositive (`import Network.HTTP.Client qualified as HTTP`); every module imports the shared
`Kansoku.Prelude` (established by EP-1 and re-exported from `kansoku:kansoku-api`, which supplies
`Text`, `Generic`, aeson, `time`, `NonEmpty`, and the lens operators) instead of restating those
imports; records use strict `!` fields, carry no field prefixes, and derive explicitly
(`deriving stock (Generic, ...)`, `deriving anyclass (FromJSON, ToJSON)`,
`deriving newtype (...)`); records are read and updated through generic-lens `#label` access
(each such module adds `import Data.Generics.Labels ()`) rather than record-selector or
record-update syntax; and any embedded JSON/text fixture is written with the `"""..."""`
`MultilineStrings` form.


## Plan of Work

The work proceeds in three milestones. Each is independently verifiable.

### Milestone 0 — Confirm the reused artifacts (no code, but blocking)

Before writing SDK code, also read EP-4's `Kansoku.Ingest.Api` module to learn the actual
`IngestRoutes` record: confirm the two endpoints it declares (the single-event `POST
/v1/events` and the batch `POST /v1/batch`), the request-body types (a single `AnalyticsEvent`
and a `[AnalyticsEvent]` / JSON array), and the response types/verbs (both return `202
Accepted` with response DTOs declared in `Kansoku.Ingest.Api`: `IngestAck` for `/v1/events`
and `BatchAck` for `/v1/batch`). Confirm `genericClient` yields
`IngestRoutes (AsClientT ClientM)` and that qualified selector application binds each call to
its named field. Record any mismatch with this plan's assumptions in Surprises & Discoveries.

Then read `src/Kansoku/Event.hs` to learn the *actual* shape of
`AnalyticsEvent` as EP-2 built it: the exact Haskell field names (they may be
record-selector-cased like `eventId` or `evtEventId` — you must use whatever EP-2 chose), the
constructor, the `EventSource` constructors and which one is the `service` variant, the id
newtypes (e.g. an `EventId` newtype), and whether EP-2 exposes an id generator (for example
`newEventId :: IO EventId`) and a "smart constructor"/default builder for `AnalyticsEvent`.
Also confirm how `ToJSON` renders an unset `receivedAt`. Record anything that differs from
this plan's assumptions in Surprises & Discoveries, and adjust the interface names below to
match reality. If EP-2 already provides a default `AnalyticsEvent` builder and an id
generator, prefer reusing them over re-implementing (this keeps the id scheme consistent with
the rest of the system — EP-2 may use time-ordered ids). If EP-2 exposes only the type and the
id newtype, generate `eventId` with a UUID: use `Data.UUID.V4.nextRandom :: IO UUID` from the
`uuid` package and render it with `Data.UUID.toText`, wrapping in EP-2's id newtype. (Note:
the `uuid` package in this ecosystem does not implement UUIDv7; if time-ordered ids are wanted,
EP-2's own generator — likely built on `mmzk-typeid`'s `Data.UUID.V7` — is the right source,
which is another reason to prefer reusing EP-2's generator.)

Acceptance: you can state, in Surprises & Discoveries or by confirming here, the exact
`AnalyticsEvent` constructor/fields, the `service` `EventSource` constructor, the id
generation approach you will use, and the shape of EP-4's `IngestRoutes` record
that you will derive the client from. No build artifact yet.

### Milestone 1 — Package, event construction, and JSON contract

Goal: a buildable `kansoku-client` package whose `track`/helper functions construct valid
`AnalyticsEvent`s with sensible defaults and deliver them through a `servant-client` derived
from EP-4's `IngestRoutes`, using a straightforward synchronous single-event call. At the end of
this milestone `cabal test kansoku-client` passes with no server running, proving the client
compiles against `IngestRoutes` and events round-trip through the shared type.

First, confirm the shared `kansoku-api` package exposes `Kansoku.Prelude`, the event modules,
`Kansoku.Api.Response`, `Kansoku.Ingest.Api`, `Kansoku.Metrics.Api`, and `Kansoku.Api`, without
depending on `servant-server` or `warp`. The `kansoku-client` package depends on `kansoku-api`,
`servant-client`, and `servant-client-core`; the last dependency directly provides
`Servant.Client.Generic`. Do not hand-write request paths or JSON bodies — the generic client
record is the contract.

Next, create the SDK package. Make a directory `kansoku-client/` at the repository root with:

- `kansoku-client/kansoku-client.cabal` — a package named `kansoku-client` with a `library`
  stanza exposing `Kansoku.Client`, and a `test-suite` stanza.
- `kansoku-client/src/Kansoku/Client.hs` — the SDK module.
- Later (Milestone 3) `kansoku-client/example/Main.hs` — the runnable example.

Add the package to the build by editing the root `cabal.project` `packages:` stanza to include
`./kansoku-client` alongside the existing `.` entry, for example:

```cabal
packages:
  .
  ./kansoku-client
```

The `kansoku-client` library `build-depends` for this milestone: `base`, `aeson`, `text`,
`time`, `bytestring`, `servant`, `servant-client`, `http-client`, `http-client-tls`, and
`kansoku:kansoku-api`. (`stm` and `async` are added in Milestone 2.) Here `http-client` and
`http-client-tls` are used only to build the `Manager` that `servant-client` runs on — you do
*not* hand-write requests with them. The id generator dependency (`uuid`, or whatever EP-2's
generator needs) is included per Milestone 0's finding.

Derive the client from the API type. In `Kansoku.Client`, import the API type and the servant
client machinery:

```haskell
-- GHC2024 (via the `common` cabal stanza EP-1 established) already provides
-- TypeApplications and ImportQualifiedPost, so no per-file pragmas are needed
-- here. Every module imports the shared `Kansoku.Prelude` (re-exported from the
-- `kansoku:kansoku-api` sub-library), which supplies `Proxy`, `Text`, `Generic`,
-- the aeson names, `time`, `NonEmpty`, and the lens operators.
import Kansoku.Prelude
import Kansoku.Api.Response (KansokuResult)
import Kansoku.Event (AnalyticsEvent, EventSource (..))
import Kansoku.Ingest.Api (BatchAck, IngestAck, IngestRoutes)
import Kansoku.Ingest.Api qualified as Ingest
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Client.TLS qualified as HTTP.TLS
import Servant.Client
  ( BaseUrl (..)
  , ClientEnv
  , ClientM
  , Scheme (..)
  , mkClientEnv
  , runClientM
  )
import Servant.Client.Generic (AsClientT, genericClient)

-- The same NamedRoutes record used by the server is interpreted as a client.
-- Qualified selector application keeps endpoint identity attached to its field.
ingestClient :: IngestRoutes (AsClientT ClientM)
ingestClient = genericClient

postOne :: AnalyticsEvent -> ClientM (KansokuResult IngestAck)
postOne event = Ingest.postEvent ingestClient event

postMany :: [AnalyticsEvent] -> ClientM (KansokuResult BatchAck)
postMany events = Ingest.postBatch ingestClient events
```

Build the `ClientEnv` once (stored in the `Client` handle) from an `http-client` `Manager` and
a `BaseUrl`, and run any client call with `runClientM`:

```haskell
-- Manager: reuse a caller-provided one from ClientConfig, else create one.
-- Read the optional manager field with generic-lens #label access rather than
-- the record selector (Data.Generics.Labels () is imported in this module).
mgr <- maybe (HTTP.newManager HTTP.TLS.tlsManagerSettings) pure (cfg ^. #manager)
-- BaseUrl parsed from the config's `baseUrl` (host/port/scheme);
-- parseBaseUrl :: String -> m BaseUrl is available from Servant.Client, or
-- construct BaseUrl {baseUrlScheme = Http, ...} directly.
let env = mkClientEnv mgr baseUrl :: ClientEnv
-- Deliver one event synchronously:
result <- runClientM (Ingest.postEvent ingestClient evt) env
  -- :: IO (Either ServantClient.ClientError (KansokuResult IngestAck))
```

The outer `Either` is the transport channel: connection failures, protocol errors, and decode
failures become `ServantClient.ClientError`. The inner `KansokuResult` is the endpoint channel:
`KansokuOk` is success, `KansokuBadRequest` and `KansokuNotFound` are permanent rejections, and
`KansokuUnavailable` is retryable only when its envelope says `retryable = True`. The SDK maps
these to `DeliveryFailed` and `DeliveryRejected`, retries transport failures plus retryable 503
results with backoff, and never retries typed 400/404 results.

Implement `Kansoku.Client` for this milestone with: the `ClientConfig` record and
`defaultClientConfig`; the opaque `Client` handle (holding the shared `ClientEnv`); the
`EventIds` record and `emptyIds` (see the Decision Log — identity ids are first-class event
fields, never `properties` entries); the event-building helpers (`trackEvent`, `identify`,
`group`, `alias`) that take their identity ids via `EventIds` (or, for `identify`, the
`userId` directly plus an optional `anonymousId`), route the `[Pair]` argument ONLY into
`properties`, and call an internal `buildEvent` which auto-generates `eventId`, sets
`occurredAt` to the current time (`Data.Time.Clock.getCurrentTime`), sets `source` to the
`service` variant, and sets `sourceService` from config; and an *internal* synchronous
single-event delivery function that runs `Ingest.postEvent ingestClient evt` via `runClientM`
on the shared `ClientEnv`, accepting only `Right (KansokuOk _)` as success. Outer transport
errors and inner typed endpoint results remain distinct as described above. That synchronous function is
a Milestone-1 stepping stone only: in Milestone 2 the public `track` becomes the non-blocking
batched enqueue and the synchronous path is absorbed into the batch-delivery machinery — no
`sendNow` is exported (see the Decision Log's superseding note; `flush` covers "deliver now").
The public `track`/`identify`/`flush`/`close` API stays plain `IO`; only the internals touch
`ClientM`/`runClientM`.

Then write the unit tests in the `test-suite`, using the test framework EP-1 established (match
whatever EP-1 chose — tasty+tasty-hunit or hspec; discover it from EP-1's `kansoku.cabal`
test-suite and from `docs/plans/1-...md`). Cover: (1) each helper produces an `AnalyticsEvent`
with the expected `eventName`, `source = service`, a non-empty `eventId`, and an `occurredAt`,
and that the `EventIds` argument populates the first-class identity fields (`userId`,
`anonymousId`, `organizationId`, `accountId`, `sessionId`) while the pairs argument lands only
in `properties` (assert a `userId` passed via `EventIds` is NOT present in `properties`);
(2) a contract test asserting the client compiles against `IngestRoutes` (the module type-checks
`ingestClient = genericClient` and qualified `Ingest.postEvent ingestClient` /
`Ingest.postBatch ingestClient` selector applications with the SDK's argument/return types)
and that a fully-populated event round-trips through the shared type — encode it and decode it
back through `Kansoku.Event`'s `FromJSON` and assert equality — proving the SDK builds exactly
the `AnalyticsEvent` the shared route record expects. Drift is prevented at the type level by
using the one `IngestRoutes` record, so no separate golden-JSON key-set test is needed; (3) confirm
`receivedAt` handling matches what Milestone 0 found.

Acceptance: `cabal build all` builds the main package and the SDK; `cabal test kansoku-client`
passes; no server is required.

### Milestone 2 — Batching, background flush, retry, overflow

Goal: `track` becomes non-blocking and batched. Events enqueue into a bounded in-memory buffer;
a background thread flushes them by applying `Ingest.postBatch` to `ingestClient` (which
targets `POST /v1/batch`) on a size or time threshold; transient failures are retried with
bounded exponential backoff; overflow drops the newest event and increments a counter. At the
end of this milestone the SDK sends many events per HTTP request and survives transient network
failures, verified by tests that use a local stub HTTP server. The batching/retry/overflow
design layers *on top of* servant-client: the generic client provides the typed `postBatch`
call, and this milestone adds the buffering, windowing, and retry loop around it.

Extend `Kansoku.Client`:

- Add to `ClientConfig`: `batchMaxSize :: Int` (flush when this many events are buffered),
  `batchMaxIntervalMicros :: Int` (flush at least this often),
  `bufferCapacity :: Int` (max buffered events before drop), `maxRetries :: Int`,
  `retryBaseDelayMicros :: Int` (backoff is `base * 2^attempt`, optionally capped). Give
  `defaultClientConfig` reasonable defaults (for example batch size 100, interval 5 s, buffer
  capacity 10000, 5 retries, base delay 100 ms).
- Add to the `Client` handle: a `TBQueue AnalyticsEvent` buffer, an `Async ()` handle for the
  background flush thread, a shared `IORef`/`TVar Int` drop counter, and the shared servant
  `ClientEnv` (which itself wraps the `Network.HTTP.Client.Manager` and the `BaseUrl`).
- `newClient` starts the background flush thread with `Control.Concurrent.Async.async`. The
  thread loops: it drains up to `batchMaxSize` events from the queue (or waits up to
  `batchMaxIntervalMicros` for at least one), and if it has any events it calls the batch delivery.
  Implement the size-or-time window by combining an STM read of the queue with a timeout using
  `System.Timeout.timeout` or `registerDelay` + `retry`; a simple, correct approach is:
  `registerDelay intervalMicros` to get a timer `TVar`, then in one STM transaction read
  everything currently queued OR block on the timer, flushing whatever accumulated.
- `track` uses a non-blocking enqueue: attempt `writeTBQueue` inside an STM transaction guarded
  by a fullness check (`isFullTBQueue`); if full, do not block — increment the drop counter and
  return. This realizes the drop-newest overflow policy without stalling the caller.
- Batch delivery: call `runClientM (Ingest.postBatch ingestClient events) env` on the shared
  `ClientEnv`. The result has an outer transport `Either` and an inner `KansokuResult`; retry
  transport failures and retryable `KansokuUnavailable`, but reject 400/404 without retry. The
  selector targets `POST /v1/batch` and encodes the
  `[AnalyticsEvent]` as a JSON array for you). Treat `Right _` as success; treat any
  `Left ClientError` — a non-2xx `FailureResponse` or a `ConnectionError` — as failure. On
  failure, retry up to `maxRetries` times with exponential backoff, **re-sending the exact
  same events (same `eventId`s)** — never regenerate ids. After exhausting retries, drop the
  batch and increment the drop counter by the batch size (and log). Crucially, `eventId` is
  generated in `buildEvent` at `track` time and stored in the event, so retries naturally reuse
  it.
- `flush :: Client -> IO ()` forces the background thread to deliver everything currently
  buffered and returns once the buffer is drained (implement by signalling the thread and
  waiting on an STM condition, or by having `flush` itself drain-and-send synchronously under a
  lock). `close :: Client -> IO ()` flushes, then stops the background thread
  (`Control.Concurrent.Async.cancel` after a final flush) so no events are lost on shutdown.
  `withClient` is `bracket newClient close`.

Tests for this milestone use a lightweight local stub HTTP server (start a `warp`/`wai`
application on an ephemeral port inside the test, or use `http-client` against a tiny handler)
that records the request bodies it receives:

- Batching test: emit 250 events with `batchMaxSize = 100`; assert the stub received them in
  batches (e.g. 3 requests, sizes 100/100/50) and that every `eventId` arrived exactly once
  across the batches.
- Interval test: emit a few events (fewer than the batch size), wait slightly longer than
  `batchMaxIntervalMicros`, and assert they were delivered by the timer path.
- Retry test: a stub that returns 503 for the first N requests then 202; assert the batch is
  eventually delivered and that the redelivered batch carries the *same* `eventId`s (proving
  the retry-with-same-id contract).
- Overflow test: set a tiny `bufferCapacity`, block the stub so the drain stalls, emit past
  capacity, and assert the drop counter increased and `track` never blocked.

Adding `warp`/`wai` (or an equally small HTTP stub) as a `test-suite`-only `build-depends` in
`kansoku-client.cabal` is acceptable because it is a test dependency only, not a library
dependency — the SDK library itself stays light.

Acceptance: `cabal test kansoku-client` passes all batching/retry/overflow tests; still no
real Kansoku server required.

### Milestone 3 — Integration against a running server

Goal: prove end-to-end that events emitted through the SDK land in ClickHouse
`analytics.events_raw`. This requires a running `kansoku-server` (from EP-4) with its pgmq
queue and ClickHouse writer, plus ClickHouse.

Add an integration test that is *guarded*: it reads an environment variable (for example
`KANSOKU_SERVER_URL`) and skips (passes trivially with a printed "skipped" note) when it is
unset, so `cabal test` in a plain checkout stays green. When the variable is set, the test:
creates a `Client` pointed at that URL; emits a known number of events with unique, testable
`eventName`s or a unique run tag placed in `properties` (so the count query can isolate this
run); calls `flush` and `close`; waits briefly for the server's asynchronous pgmq→ClickHouse
writer to drain (the server batches, so allow a few seconds or poll); then queries ClickHouse
for the count and asserts it equals the number emitted.

Provide the runnable example program `kansoku-client/example/Main.hs` matching the Purpose
snippet, wired as an `executable` stanza in `kansoku-client.cabal`, so a reader can
`cabal run kansoku-client-example` against a running server and see events flow.

Acceptance: with `kansoku-server` and ClickHouse running (see Concrete Steps), the integration
test emits events and the ClickHouse `COUNT(*)` matches; the example program runs and produces
observable rows.


## Concrete Steps

Run everything from the repository root inside the Nix dev shell (enter it with `nix develop`
or via `direnv allow` if `.envrc` uses `use flake`). Commands below show the working directory
as the repo root unless noted.

Build the whole workspace after the cabal edits (Milestone 1):

```bash
cd /Users/shinzui/Keikaku/bokuno/kansoku-project/kansoku
cabal build all
```

Expected: the `kansoku` library, the `kansoku:kansoku-api` sub-library, the `kansoku-server`
executable, and the `kansoku-client` library all compile. If `callCabal2nix`/Nix caching is
stale, `nix build` also works but `cabal build all` in the dev shell is the fast inner loop.

Run the SDK unit tests (Milestones 1 and 2):

```bash
cabal test kansoku-client
```

Expected transcript (shape; exact wording depends on the chosen test framework):

```text
Test suite kansoku-client-test: RUNNING...
Kansoku.Client
  trackEvent builds a service-source event with an eventId:      OK
  EventIds fill identity fields; pairs land only in properties:  OK
  client derives from IngestRoutes and event round-trips the type:  OK
  buffer flushes at batch size (250 events -> 100/100/50):       OK
  buffer flushes on interval:                                    OK
  retry re-sends the same eventId after 503s:                    OK
  overflow drops newest and increments the drop counter:         OK
All N tests passed
Test suite kansoku-client-test: PASS
```

Start the dependencies for the integration test (Milestone 3). The dev shell provides
`process-compose`, ClickHouse, and PostgreSQL. Bring up the local services (per EP-1/EP-4's
`process-compose.yaml`):

```bash
process-compose up -d
```

Then start the server (from EP-4; command per that plan, typically):

```bash
cabal run kansoku-server
```

Expected: the server logs that it is listening on `http://localhost:8080` (confirm the port
from EP-1/EP-4) and that it created the pgmq queue and connected to ClickHouse.

Run the guarded integration test against it:

```bash
KANSOKU_SERVER_URL=http://localhost:8080 cabal test kansoku-client --test-options=--pattern=integration
```

Verify the rows landed in ClickHouse directly (independent of the test's own assertion). Using
the dev shell's ClickHouse client over the native TCP port (`$CLICKHOUSE_TCP_PORT`, default
9000) or HTTP port (8123):

```bash
clickhouse client --port "$CLICKHOUSE_TCP_PORT" \
  --query "SELECT count() FROM analytics.events_raw WHERE event_name = 'user_registered'"
```

Expected output: a single integer equal to the number of `user_registered` events the test
emitted (use `FINAL` or a run-tag filter if a prior run inserted the same `event_name`, since
`ReplacingMergeTree` may not have merged yet):

```text
3
```

Run the example program against the running server:

```bash
KANSOKU_SERVER_URL=http://localhost:8080 cabal run kansoku-client-example
```

Expected: the program prints that it emitted and flushed events; a follow-up `clickhouse
client` count shows them present.


## Validation and Acceptance

The plan is accepted when all of the following observable behaviors hold.

Milestone 1 is accepted when `cabal build all` succeeds and `cabal test kansoku-client` passes
its construction and contract tests with no server running. Concretely: the client is derived
from EP-4's `IngestRoutes` (`ingestClient = genericClient`) and calls routes through qualified
selectors, so module type-checking proves the SDK's request shapes match the server's — the guard
against SDK/server drift is now at the type level, not a JSON key-set comparison. The
round-trip test additionally proves that a fully populated event encodes and decodes back into
a `Kansoku.Event.AnalyticsEvent` (via EP-2's `FromJSON`) equal to the original, confirming the
SDK constructs exactly the type the shared `IngestRoutes` record carries.

Milestone 2 is accepted when the batching, interval, retry, and overflow tests pass against the
in-test stub HTTP server: 250 events sent through `track` arrive as multiple `/v1/batch`
requests (not 250 single requests), a typed retryable 503 then 202 results in eventual delivery
with the *same* `eventId`s, typed 400/404 results are not retried, and exceeding the buffer capacity increments the drop counter
without `track` ever blocking.

Milestone 3 is accepted when, with a real `kansoku-server` and ClickHouse running, emitting N
events through the SDK and flushing results in exactly N matching rows in
`analytics.events_raw` (verified both by the guarded integration test's assertion and by an
independent `clickhouse client` `count()` query), and the example program runs and produces
those rows. This is the end-to-end proof that a Haskell backend service can emit analytics
events to Kansoku with a few lines of code, which is the stated purpose.

Beyond compilation, effectiveness is demonstrated by: the retry test (fails before the SDK
retries, passes after — the same batch is redelivered with stable ids); the batching test
(proves requests are amortized, not one-per-event); and the integration count (proves the
events physically reached the columnar store of record).


## Idempotence and Recovery

The cabal edits are idempotent: re-running `cabal build all` after the same edits is a no-op;
adding `./kansoku-client` to `packages:` a second time is harmless if you check before editing.
Creating the `kansoku-client/` directory and files is safe to repeat (overwrite with the same
content). If the `kansoku-api` sub-library causes a build break in the main library or
`kansoku-server`, first fix the API package so the route types remain server-free (its purpose);
only as a last resort revert to depending on the full `kansoku` library from `kansoku-client`
(record this in the Decision Log). Under that last-resort fallback the SDK code is unchanged
*except* that it still imports `Kansoku.Ingest.Api`/`Kansoku.Event` from the same module paths,
so the servant-client derivation is unaffected.

The SDK's runtime behavior is safe under repetition by design: because delivery is
at-least-once and the server deduplicates on `event_id`, re-running the integration test or the
example program does not corrupt data — duplicate deliveries collapse in the
`ReplacingMergeTree`. If a count query shows more rows than expected shortly after a run, that
is un-merged duplicates from retries; query with `FINAL` or filter by a unique run tag to get
the deduplicated count, and re-check after ClickHouse merges. If the integration test cannot
reach the server, it is guarded to skip (when `KANSOKU_SERVER_URL` is unset) so it never breaks
a plain `cabal test`.


## Interfaces and Dependencies

Package and build structure (exact edits):

- New package `kansoku-client` in directory `kansoku-client/`, with
  `kansoku-client/kansoku-client.cabal` declaring a `library` (exposing `Kansoku.Client`), a
  `test-suite`, and (Milestone 3) an `executable` `kansoku-client-example`.
- Root `cabal.project` lists `./kansoku-api`, `./kansoku-core`, `./kansoku-server`, and
  `./kansoku-client`.
- `kansoku-api/kansoku-api.cabal` exposes the shared prelude, event model, response algebra,
  `Kansoku.Ingest.Api`, `Kansoku.Metrics.Api`, and `Kansoku.Api` (no `servant-server`, no `warp`).

Libraries the SDK uses and why:

- `kansoku-api` — provides `Kansoku.Prelude` (the shared custom prelude every module
  imports, re-exporting `Text`, `Generic`, the aeson names, `time`, `NonEmpty`, and the lens
  operators), `Kansoku.Event.AnalyticsEvent`, `EventSource`, the JSON instances, the id newtypes
  (per the EP-2 hard dependency), and `Kansoku.Ingest.Api.IngestRoutes`, the route record the SDK
  derives its client from (per the EP-4 hard dependency). Reused, not redefined. `kansoku-client`
  therefore lists `kansoku-api` in its `build-depends`, and its `library` and
  `test-suite` stanzas both `import: common` (GHC2024 + `DeriveAnyClass`,
  `DuplicateRecordFields`, `OverloadedLabels`, `OverloadedStrings`, `MultilineStrings`).
- `servant` — provides the API-type combinators used by `IngestRoutes`; the SDK imports the
  record and does not declare endpoints itself.
- `servant-client` (`haskell-servant/servant`, package `servant/servant-client`) — derives the
  client calls from the API type. Key pieces (confirmed against the servant source):
  `ClientM` (the client
  monad); `runClientM :: ClientM a -> ClientEnv -> IO (Either ClientError a)`;
  `mkClientEnv :: Manager -> BaseUrl -> ClientEnv`; `ClientEnv (..)`;
  `BaseUrl (..)` with fields `baseUrlScheme`, `baseUrlHost`, `baseUrlPort`, `baseUrlPath`;
  `Scheme (..)` = `Http | Https`; and `parseBaseUrl :: MonadThrow m => String -> m BaseUrl` for
  parsing `baseUrl`. `servant-client-core` provides
  `genericClient :: GenericMode mode => routes mode` and `AsClientT ClientM`.
  Chosen over hand-written `http-client` to make the SDK provably the same shape as the server
  (drift-proof at the type level); see the Decision Log.
- `http-client` + `http-client-tls` (`snoyberg/http-client`) — only used to build the
  `Manager` that servant-client runs on: `Network.HTTP.Client.newManager` and
  `Network.HTTP.Client.TLS.tlsManagerSettings` (for https base URLs). The SDK does not build or
  send requests with these directly — servant-client does that.
- `stm` — `Control.Concurrent.STM.TBQueue` for the bounded buffer; `TVar` for the drop counter.
- `async` — `Control.Concurrent.Async.async`/`cancel` for the background flush thread.
- `time` — `Data.Time.Clock.getCurrentTime`/`NominalDiffTime` for `occurredAt` and the flush
  interval.
- `uuid` (`haskell-hvr/uuid`) — `Data.UUID.V4.nextRandom :: IO UUID` and `Data.UUID.toText`
  for `eventId`, used only if EP-2 does not already expose an id generator (prefer EP-2's).
- Test-only: `warp`+`wai` (or a minimal stub) for the Milestone-2 stub HTTP server that the
  servant client posts against, and the test framework EP-1 chose (tasty/tasty-hunit or hspec)
  plus `aeson` for the round-trip assertion.

Public module and signatures that must exist at the end of the milestones (adjust names to
match EP-2's actual `AnalyticsEvent` field/constructor names discovered in Milestone 0):

```haskell
module Kansoku.Client
  ( -- Configuration
    ClientConfig(..)
  , defaultClientConfig      -- :: Text -> ClientConfig  (base URL, e.g. "http://localhost:8080")
    -- Handle lifecycle
  , Client                   -- opaque
  , ClientError(..)          -- DeliveryFailed transport error | DeliveryRejected typed envelope
  , newClient                -- :: ClientConfig -> IO Client
  , withClient               -- :: ClientConfig -> (Client -> IO a) -> IO a
  , flush                    -- :: Client -> IO ()
  , close                    -- :: Client -> IO ()
  , droppedCount             -- :: Client -> IO Int
    -- Identity ids for the convenience helpers
  , EventIds(..)             -- first-class identity fields; NOT properties entries
  , emptyIds                 -- :: EventIds  (all fields Nothing)
    -- Emitting events
  , track                    -- :: Client -> AnalyticsEvent -> IO ()   (non-blocking enqueue; escape hatch)
  , trackEvent               -- :: Client -> EventIds -> Text -> [Pair] -> IO ()
  , identify                 -- :: Client -> Text -> Maybe Text -> [Pair] -> IO ()  (userId, optional anonymousId to stitch, traits)
  , group                    -- :: Client -> EventIds -> Text -> [Pair] -> IO ()    (ids, groupId + traits)
  , alias                    -- :: Client -> Text -> Text -> [Pair] -> IO ()  (previousId, newId, properties)
  ) where

import Kansoku.Prelude
import Data.Generics.Labels ()               -- enables #label access over Generic records
import Data.Aeson.Types (Pair)               -- Pair is exported from Data.Aeson.Types
import Kansoku.Api.Response (ErrorEnvelopeWire, KansokuResult (..))
import Kansoku.Event (AnalyticsEvent, EventSource (..))
import Kansoku.Ingest.Api (BatchAck, IngestRoutes)
import Kansoku.Ingest.Api qualified as Ingest
import Servant.Client
  ( BaseUrl (..)
  , ClientEnv
  , ClientM
  , Scheme (..)
  , mkClientEnv
  , runClientM
  )
import Servant.Client qualified as ServantClient
import Servant.Client.Generic (AsClientT, genericClient)

data ClientError
  = DeliveryFailed !ServantClient.ClientError
  | DeliveryRejected !ErrorEnvelopeWire
  deriving stock (Eq, Show)

ingestClient :: IngestRoutes (AsClientT ClientM)
ingestClient = genericClient
```

The `EventIds` record (see the Decision Log entry for the full rationale). In every helper the
`[Pair]` argument feeds ONLY the event's `properties` object; the identity fields come
exclusively from this record (or, for `identify`, from its direct arguments):

```haskell
-- Identity ids are first-class AnalyticsEvent fields (userId, anonymousId,
-- organizationId, accountId, sessionId), distinct from `properties`. House
-- style: strict fields, no prefixes, explicit stock deriving; set fields with
-- generic-lens labels, e.g. `emptyIds & #userId ?~ "user_42"`.
data EventIds = EventIds
  { userId         :: !(Maybe Text)
  , anonymousId    :: !(Maybe Text)
  , organizationId :: !(Maybe Text)
  , accountId      :: !(Maybe Text)
  , sessionId      :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)

emptyIds :: EventIds
emptyIds = EventIds Nothing Nothing Nothing Nothing Nothing
```

`ClientConfig` fields (final, Milestone 2):

```haskell
-- No field prefixes (DuplicateRecordFields + generic-lens #label handle the
-- naming), strict `!` fields throughout, and an explicit stock-`Generic`
-- deriving. `Generic` is what makes the `#label` lenses resolve; the config is
-- read with `cfg ^. #baseUrl` etc. `Manager` comes from the qualified
-- `Network.HTTP.Client` import (`HTTP.Manager`).
data ClientConfig = ClientConfig
  { baseUrl          :: !Text                       -- e.g. "http://localhost:8080"
  , sourceService    :: !(Maybe Text)               -- populates AnalyticsEvent.sourceService
  , batchMaxSize     :: !Int                         -- flush when this many events buffered   (default 100)
  , batchMaxIntervalMicros :: !Int                  -- flush at least this often              (default 5s)
  , bufferCapacity   :: !Int                         -- max buffered before drop-newest        (default 10000)
  , maxRetries       :: !Int                         -- retries per batch on transient failure (default 5)
  , retryBaseDelayMicros :: !Int                    -- backoff base*2^attempt                 (default 100ms)
  , manager          :: !(Maybe HTTP.Manager)        -- reuse a caller-provided http-client Manager
  }
  deriving stock (Generic)
```

`Client` (opaque) internally holds: the shared servant `ClientEnv` (built with
`mkClientEnv manager baseUrl`, wrapping the `http-client` `Manager` and the resolved
`BaseUrl`), the `TBQueue AnalyticsEvent` buffer, the background `Async ()`, the `TVar Int` drop
counter, and the config. The shared `ingestClient = genericClient` record is a module-level value;
call sites use qualified selectors such as `Ingest.postBatch ingestClient events` and execute
them with `runClientM ... env`.

Endpoints the SDK calls are derived from `IngestRoutes`, so the SDK never hand-builds requests.
`Ingest.postEvent ingestClient` targets `POST {baseUrl}/v1/events`, and
`Ingest.postBatch ingestClient` targets `POST {baseUrl}/v1/batch`. Each raw call returns a
`KansokuResult` carrying either the 202 ack DTO or the shared 400/404/503 envelope. The outer
`Either ServantClient.ClientError` remains the transport channel. `Content-Type` and every
status/body pair are fixed by `IngestRoutes` and `Kansoku.Api.Response`, not by the SDK. The client sets
`receivedAt` to the same value as `occurredAt` because the shared event type requires it;
the ingestion server may overwrite it. The client also sets `eventId`, `eventName`, `source`
(= the `service` variant of `EventSource`),
the identity ids, and `properties`/`context`. A `Left ServantClient.ClientError` is
`DeliveryFailed`; a non-success `KansokuResult` is `DeliveryRejected`. Retry outer transport
failures and retryable 503 envelopes with the same `eventId`; never retry typed 400/404 results.

Commit trailers. Every commit made while executing this plan must carry these trailers (in
addition to a Conventional Commits subject such as `feat(client): add kansoku-client batching`),
with no feature branch (commit to the current branch):

```text
feat(client): add batching and retry to kansoku-client

MasterPlan: docs/masterplans/1-kansoku-analytics-service-mvp.md
ExecPlan: docs/plans/7-haskell-server-sdk.md
Intention: intention_01kwf425fxenc904ear54cr2n7
```


## Revision Note

- 2026-07-02 (implementation): **EP-7 implementation completed.** Added the separate
  `kansoku-client` package, `Kansoku.Client`, `kansoku-client-example`, and
  `kansoku-client-test`; added `./kansoku-client` to `cabal.project`; made the shared
  `kansoku-api` sub-library public so the separate package can depend on
  `kansoku:kansoku-api`. The SDK derives `_postEvent :<|> postBatch` from `IngestAPI`, builds
  service-source `AnalyticsEvent`s, queues events in a bounded `TBQueue`, flushes in batches,
  retries failed batches with stable event ids, drops newest events on overflow, and exposes a
  dropped-event counter.

  Evidence: `cabal test kansoku-client` passes with the live integration case pending when
  `KANSOKU_SERVER_URL` is unset. With `process-compose` services, `just ch-migrate`, and
  `kansoku-server` running on port 18081,
  `KANSOKU_SERVER_URL=http://127.0.0.1:18081 cabal test kansoku-client` passed all seven
  examples and verified the SDK-emitted event in `analytics.events_raw` with
  `clickhouse-client`. Implementation discoveries recorded above: `kansoku-api` needed
  `visibility: public`, EP-2 requires `receivedAt`, Aeson `Pair` comes from
  `Data.Aeson.Types`, and Warp tests require `-threaded`.

- 2026-07-01 (revision): **Switched the SDK's HTTP transport from hand-written `http-client` +
  JSON to `servant-client`, and promoted EP-4 from a soft to a HARD dependency.** The SDK now
  derives its `postEvent`/`postBatch` functions from EP-4's servant API type,
  `Kansoku.Api.Ingest.IngestAPI`, via `postEvent :<|> postBatch = client (Proxy @IngestAPI)`,
  runs them with `runClientM` on a shared `ClientEnv` (`mkClientEnv manager baseUrl`), and keeps
  the public API plain `IO`. The event model and the API type are now both delivered through one
  shared public Cabal sub-library, renamed from `kansoku:kansoku-event` to `kansoku:kansoku-api`
  (it holds `Kansoku.Event*` AND `Kansoku.Api.*`), which depends on `servant` only — not
  `servant-server`, not `warp`.

  What changed across sections: Purpose (added the servant-client/`kansoku-api` architecture and
  the EP-4 hard-dependency statement); Progress (Milestone-1 items now build `kansoku-api`,
  derive the client, and test the type-level contract instead of a golden JSON test; Milestone-2
  item delivers via `postBatch`); Decision Log (replaced the "`http-client` + hand-written JSON,
  NOT servant-client" decision with the "use `servant-client` from the shared `IngestAPI`"
  decision, and rewrote the sub-library decision for `kansoku-api` carrying the API types);
  Context and Orientation (EP-4 added as a third relevant plan and as a hard dependency; the
  quoted contract reframed as the imported `IngestAPI` type; sub-library renamed); Plan of Work
  (Milestone 0 now reads `IngestAPI`; Milestone 1 builds `kansoku-api`, shows the real
  servant-client derivation and `ClientEnv`/`runClientM` usage, and replaces the golden test;
  Milestone 2 delivers via `postBatch`); Concrete Steps and the test transcript (sub-library
  and test names updated); Validation (drift guard is now type-level); Idempotence (fallback
  reworded for `kansoku-api`); Interfaces and Dependencies (build-depends now
  `servant`/`servant-client`/`http-client`/`http-client-tls` + `kansoku:kansoku-api`; module
  imports, the `Client` internals holding a `ClientEnv`, and the endpoint description all
  updated to servant-client).

  Why: this is an authoritative decision by the human owner. `servant-client` makes the SDK
  *provably the same shape as the server* because both are generated from the single `IngestAPI`
  servant type, so client/server drift is impossible at the type level rather than merely caught
  by a golden test. The prior draft avoided `servant-client` for fear that importing EP-4's API
  type would drag in `servant-server`/`warp` and force lifting the type into a shared
  sub-library; that objection is fully resolved by the shared `kansoku:kansoku-api` sub-library,
  which carries the API *type declarations only* and depends on `servant` alone. The
  batching/retry/overflow design is orthogonal and is retained unchanged, layered on top of the
  servant-derived `postBatch` call.

- 2026-07-01 (revision): **Adopted the shared `haskell-jitsurei/core` coding standards
  throughout the plan's Haskell sketches.** No design changed — the servant-client transport, the
  batching/retry/overflow logic, and the `kansoku:kansoku-api` structure are all exactly as
  before; only the *code style* of the embedded Haskell was brought into compliance with
  `/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/core/` (`standards.md`, `custom-prelude.md`,
  `record-patterns.md`, `multiline-strings.md`).

  What changed: every Haskell sketch now imports the shared `Kansoku.Prelude` (re-exported from
  `kansoku:kansoku-api`, established by EP-1) instead of restating `Data.Proxy`/`Text`/aeson
  imports, and drops the redundant `{-# LANGUAGE TypeApplications #-}` pragma (GHC2024 + the
  `common` stanza provide it); qualified imports use postpositive `qualified` syntax
  (`import Network.HTTP.Client qualified as HTTP`); the `ClientConfig` record now uses strict `!`
  fields, drops the `cc` field-name prefixes (relying on `DuplicateRecordFields`), and derives
  explicitly (`deriving stock (Generic)`), with its prose field references renamed to match; the
  config is now read through generic-lens `#label` access (`cfg ^. #manager`) and the SDK module
  gains `import Data.Generics.Labels ()` to enable it. The Context and Orientation section gained
  a "Coding standards" paragraph pointing at `haskell-jitsurei/core/` and EP-1's `Kansoku.Prelude`
  + `common` stanza; the sub-library and Interfaces descriptions now note that `kansoku-api` also
  exposes `Kansoku.Prelude` and that `kansoku-client`'s stanzas `import: common`.

  Why: consistency with the rest of the codebase. The house style (GHC2024, the `common`
  extension set including `MultilineStrings`, a single custom prelude, prefix-free strict records
  with explicit deriving, and generic-lens `#label` access over record syntax) is mandatory for
  every Haskell package here, and the SDK sketches must model it so a novice implementing the plan
  writes conforming code from the start.

- 2026-07-01 (revision): **Corrections from a pre-implementation validation pass.** No
  architectural decision changed — servant-client transport, the `kansoku:kansoku-api`
  sub-library, batching/retry/overflow are all as before. Six fixes:

  1. *Client return types and imports.* The client sketches previously typed the derived
     functions as `ClientM NoContent` and imported `NoContent (..)` from `Servant.Client` —
     wrong on both counts (`NoContent` lives in `Servant.API`, and EP-4's `IngestAPI` does not
     use it anyway: its endpoints return the ack DTOs `IngestAck` for `POST /v1/events` and
     `BatchAck` for `POST /v1/batch`, both 202, both declared in `Kansoku.Api.Ingest`). Both
     import sketches now import `IngestAck`/`BatchAck` from `Kansoku.Api.Ingest`, the derived
     types are `ClientM IngestAck` / `ClientM BatchAck`, the "adjust the return type per
     Milestone 0" hedge is dropped, and the contract block, Milestone 0, and the endpoint
     description in Interfaces name the ack DTOs.
  2. *Removed a fabricated MasterPlan quote.* The separate-package Decision Log entry quoted
     the MasterPlan as saying EP-7 "is deliberately decoupled ... could even be extracted to
     its own package later"; no such sentence exists in the MasterPlan. The quote is removed
     and the decision stands on its own stated rationale (the `docs/initial-spec.md:480`
     `kansoku-haskell` component citation is kept).
  3. *Plan count.* "seven ExecPlans ... EP-7, the last one" was stale: the MasterPlan registry
     has eight ExecPlans and EP-8 (OpenAPI documentation) lands after EP-7. Context and
     Orientation now says eight and notes EP-8.
  4. *Identity fields vs. properties (`EventIds`).* The old helper shape
     (`trackEvent :: Client -> Text -> [Aeson.Pair] -> IO ()`) gave no way to set the
     first-class `AnalyticsEvent` identity fields, and the Purpose example wrongly put
     `"userId"` into the pairs list — which would land in `properties`, invisible to identity
     resolution. Introduced `EventIds` (five strict `Maybe Text` fields: `userId`,
     `anonymousId`, `organizationId`, `accountId`, `sessionId`) with `emptyIds`; `trackEvent`
     and `group` now take an `EventIds` argument, `identify` takes the `userId` directly plus
     an optional `anonymousId` to stitch, `alias` is unchanged, pairs feed ONLY `properties`,
     and `track` with a full `AnalyticsEvent` remains the escape hatch. Purpose example, the
     Progress export list, Milestone 1 (implementation and tests), the test transcript, the
     module sketch, and a new dated Decision Log entry all reflect this.
  5. *`sendNow` inconsistency resolved.* The Decision Log promised an explicit "send now"
     convenience and Milestone 1 defined a public synchronous `track`/`sendNow`, but the final
     export list had neither. Resolution: the final API drops `sendNow` (`flush` covers the
     need); the batch-by-default decision carries a superseding note, and Milestone 1 now
     frames its synchronous single-event helper as an internal stepping stone absorbed into
     the batched path in Milestone 2.
  6. *`Aeson.Pair` import.* `Pair` is exported from `Data.Aeson.Types`, not `Data.Aeson`; the
     module sketch now imports `Data.Aeson.Types qualified as Aeson`.

  Why: these were factual errors (wrong module homes, a nonexistent quote, a stale count) and
  two API-surface ambiguities that would have sent a novice implementer down the wrong path —
  cheapest to fix before any code exists.

- 2026-07-18 — **Plan 9 alignment.** Replaced positional client derivation in the live sketches
  with `ingestClient = genericClient` and qualified `Ingest` selector application. Documented
  the outer transport versus inner typed-result channels and the retry policy. Historical
  Progress entries remain unchanged.
