---
id: 14
slug: sdk-grade-ingest-contract-partial-batch-acceptance-cors-and-payload-limits
title: "SDK-grade ingest contract: partial batch acceptance, CORS, and payload limits"
kind: exec-plan
created_at: 2026-07-15T21:30:34Z
master_plan: "docs/masterplans/2-kansoku-production-hardening-review-fixes-and-portfolio-service-readiness.md"
---

# SDK-grade ingest contract: partial batch acceptance, CORS, and payload limits

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Kansoku is the first-party analytics service for the kikan portfolio, and a deferred initiative
will build JS/React browser SDKs (`kansoku-js`, `kansoku-react`) plus microservice producers on
top of its ingest API. The server must be contract-ready *before* any client SDK is written —
every contract defect that ships now becomes a breaking change against a fleet of deployed SDKs
later. The 2026-07-15 architecture review found three foundation-readiness gaps in the ingest
surface, and this plan closes all three:

First, **one poison event wedges a whole batch forever**. Today `POST /v1/batch` returns HTTP 400
for the *entire* batch if *any single event* fails validation
(`kansoku-core/src/Kansoku/Ingest/Handler.hs`, `validateBatchOrThrow`). An SDK that buffers events
client-side and flushes periodically — which is exactly what `kansoku-client` already does and
what the JS SDK will do — retries a failed flush with the same buffer, so a single invalid event
permanently re-rejects every valid event queued behind it. After this plan, the batch endpoint
accepts the valid events, enqueues them, and returns HTTP 202 with a per-event rejection list
(`{"accepted": 3, "rejected": [{"index": 1, ...}, ...]}`), the way Segment-style analytics APIs
behave. The SDK's retry logic becomes trivial: a 202 means the flush is done; rejected events are
reported and dropped, never retried.

Second, **browsers cannot POST to kansoku at all**. Browser SDKs send events from arbitrary
product origins, and without CORS response headers every cross-origin `fetch` is blocked by the
browser. After this plan, the ingest routes (and only the ingest routes) answer CORS preflights
and carry the `Access-Control-Allow-*` headers, with allowed origins configurable via
`KANSOKU_CORS_ORIGINS`. The metrics/query surface is deliberately *not* CORS-opened.

Third, **nothing bounds a request**. There is no request-body size cap and no batch-length cap,
so one misbehaving producer can post a multi-gigabyte body or a million-event batch. After this
plan, bodies above 5 MiB and batches above 500 events are rejected with HTTP 413 and a JSON body
naming the limit, both limits configurable through `Kansoku.Config`.

You can see all of it working with `curl` against a locally running server: a 3-valid-plus-2-invalid
batch returns `202` with `"accepted":3` and two rejection records; an `OPTIONS` preflight with an
`Origin` header returns the allow headers; a 6 MB body and a 501-event batch each return `413`.
The Haskell SDK (`kansoku-client`), its example program, and the generated OpenAPI document all
move in the same commits as the wire change, so no consumer of the repository is ever left behind
the contract.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").

- [ ] Milestone 0: reconcile this plan's Context against plan 9's *landed* state (module paths,
      MultiVerb idiom, response-envelope types). Record any divergence in Surprises & Discoveries
      and update this plan's file paths and code sketches before writing any code.
- [ ] Milestone 1: `RejectedEvent` + new `BatchAck` wire types; `renderValidationError`; partial
      acceptance in the batch handler (`partitionBatch`); `kansoku-client` and its tests updated;
      OpenAPI document regenerated; `OpenApiSpec` and routing-test expectations updated;
      handler/DTO specs added; `cabal build all && cabal test all` green.
- [ ] Milestone 2: `wai-cors` middleware on the ingest paths only; `KANSOKU_CORS_ORIGINS` config
      field; preflight verified end-to-end with the curl transcript; tests green.
- [ ] Milestone 3: 5 MiB body cap via wai-extra's request-size-limit middleware; 500-event batch
      cap in the handler with a 413 JSON response; `KANSOKU_INGEST_MAX_BODY_BYTES` and
      `KANSOKU_INGEST_MAX_BATCH_LENGTH` config fields; 413 transcripts verified; tests green.
- [ ] MasterPlan registry row for EP-14 flipped to Complete; MasterPlan Progress ticks updated.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Partial batch acceptance answers HTTP 202 with an in-body rejection list, not HTTP 207
  (multi-status) and not HTTP 400.
  Rationale: SDK retry logic keys off the status code. A 202 means "this flush is finished; do not
  resend anything", which is the only behavior that cannot wedge a client-side buffer. 207 is
  WebDAV-flavored, poorly supported by HTTP tooling, and would force every SDK to parse a
  multi-status body just to learn it should do nothing. A 400 is what causes the poison-event
  wedge today. Segment's `/batch` behaves the same way for the same reason.
  Date: 2026-07-15

- Decision: A batch in which *every* event is invalid still answers 202 with `accepted = 0` and
  the full rejection list. HTTP 400 stays reserved for bodies that fail aeson parsing (malformed
  JSON, wrong field types), which servant rejects before the handler runs.
  Rationale: The SDK must drop rejected events either way; making all-invalid a special 400 case
  would force SDKs to implement two code paths for the same outcome and would reintroduce the
  retry wedge for the all-invalid case. The 400/202 split then has a crisp meaning: 400 = "the
  body was not a `[AnalyticsEvent]` at all" (a programming error in the producer), 202 = "the body
  was understood; here is the per-event verdict".
  Date: 2026-07-15

- Decision: `RejectedEvent.errors` strings are human-facing diagnostics, not machine-parseable
  codes. Machine handling keys off `index` (and `eventId` when present).
  Rationale: The stable machine contract is "which submitted events were rejected", which the
  zero-based `index` answers exactly. Freezing error prose into a machine contract would make
  every future improvement to a validation message a breaking change. This is documented in the
  wire type's haddock so SDK authors do not build parsers over the strings.
  Date: 2026-07-15

- Decision: CORS is applied to the ingest paths (`/v1/*`) only, default-open (`*`) for origins,
  with `Content-Type`, `X-Api-Key`, and `Authorization` pre-allowed as request headers. The
  metrics surface is not CORS-opened.
  Rationale: Ingest write keys are public credentials by design (they ship inside browser
  bundles), so origin restrictions add no security on the write path — Segment-style ingest is
  open-origin. The metrics surface is what needs protecting; dashboards are same-origin or
  server-mediated, and EP-15 (`docs/plans/15-api-keys-service-auth-and-account-scoped-queries.md`)
  adds authentication there. Pre-allowing `X-Api-Key`/`Authorization` now is a deliberate
  integration decision with EP-15: when EP-15 attaches write keys to ingest, browsers will start
  sending those headers, and if they were not already in `Access-Control-Allow-Headers` every
  deployed SDK would hit a second CORS change. Operators who want to pin origins set
  `KANSOKU_CORS_ORIGINS` to a comma-separated list.
  Date: 2026-07-15

- Decision: One global 5 MiB request-body cap on the whole HTTP app (not per-route 1 MiB / 5 MiB),
  plus a 500-event batch-length cap enforced in the batch handler.
  Rationale: Route-scoped size limits require path inspection inside the middleware for a
  distinction that buys nothing: the cap exists to bound memory and abuse, not to enforce
  per-route semantics, and a single event above 1 MiB is already pathological but harmless under
  the 5 MiB bound. One knob is simpler to configure, document, and test. The batch-length cap is
  the semantically meaningful per-route limit and it is enforced where the length is known — in
  the handler, after aeson parsing. 500 comfortably exceeds `kansoku-client`'s default
  `batchMaxSize` of 100 (a server cap below a shipped client default would break every SDK flush).
  Date: 2026-07-15

- Decision: Add HTTP 413 to plan 9's *shared* MultiVerb response tail (making it 400/404/413/503)
  with a new `KansokuTooLarge` constructor in `KansokuResult`, rather than widening only the
  ingest response list.
  Rationale: Plan 9's convention (from `haskell-jitsurei/api/servant-routes.md`) is one shared
  response list across the service so the fault-to-result conversion stays total. A batch-only
  413 alternative would need a `KansokuResult` constructor that the metrics-tail `AsUnion`
  instance cannot map, breaking that totality. Documenting 413 on metric GETs is honest enough —
  the global body cap sits in front of them too — and costs nothing. Plan 9's "error responses"
  conformance test expectation (`["400","404","503"]`) is updated to
  `["400","404","413","503"]` in the same commit. If plan 9's MultiVerb milestone turns out not to
  have landed (see Milestone 0), the fallback is a thrown `ServerError` with status 413 and the
  JSON body, and this decision is revisited.
  Date: 2026-07-15

- Decision: `kansoku-client` counts server-rejected batch events into its existing `dropped`
  counter (readable via `droppedCount`) and never retries them.
  Rationale: Rejected events are permanently gone by contract; the SDK's only honest move is to
  surface that. `droppedCount` is the client's existing observability hook for lost events
  (buffer overflow, delivery failure), and rejection is a third way to lose an event. No new API
  surface is needed.
  Date: 2026-07-15


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

### Dependencies and the reconciliation rule (read this first)

This plan **hard-depends on plan 9**
(`docs/plans/9-convert-kansoku-to-namedroutes-vertical-slices-and-multiverb.md`) being complete:
plan 9 converts the hand-rolled WAI router and the positional servant APIs into `NamedRoutes`
records with vertical-slice modules and `MultiVerb` responses, and this plan changes the ingest
wire contract *inside that landed shape*. Doing this work against the pre-plan-9 layout would
mean changing the same routes twice. Plan 9 in turn hard-depends on plan 10
(`docs/plans/10-restore-the-build-and-supervise-the-writer.md`): **the repository does not compile
until EP-10 lands** (`Kansoku/Writer/Batch.hs` still pattern-matches a shibuya type that was
renamed), so no milestone here can even be type-checked before EP-10 and EP-9 are done.

Because plan 9 is itself a living document that may adjust course during its implementation, this
plan describes the ingest surface **as plan 9 intends to leave it**, and names the pre-plan-9
fallback locations where relevant. **Milestone 0 of this plan is mandatory: at implementation
start, re-read plan 9's Progress, Surprises & Discoveries, and Decision Log, verify every file
path and type name used below against the actual working tree, and reconcile this Context section
(and the code sketches in Plan of Work) with what actually landed before writing any code.**
Record divergences in this plan's Surprises & Discoveries.

### What this repository is

Kansoku is a product-analytics service written in Haskell (GHC 9.12.4, `GHC2024` language
edition, nix flake dev shell, `cabal` build) at the repository root
`/Users/shinzui/Keikaku/bokuno/kansoku-project/kansoku`. Applications POST it analytics events
over HTTP; the ingest handler validates them and enqueues them into **pgmq** (a PostgreSQL-backed
message queue); a batch writer drains the queue into ClickHouse; a metrics API answers queries.
Four cabal packages:

- `kansoku-api` — servant route types, DTOs, the `AnalyticsEvent` event model and its validation,
  and `Kansoku.Prelude`. Depends only on servant and light libraries; both server and client SDK
  build against it so they cannot disagree about the wire format. After plan 9 it also owns the
  OpenAPI generator (`Kansoku.Api.OpenApi`), the shared response machinery
  (`Kansoku.Api.Response`), and the `kansoku-openapi` executable that writes the checked-in
  `docs/api/openapi.json`.
- `kansoku-core` — handlers, config, queue producer, ClickHouse adapter, writer, server assembly.
- `kansoku-server` — the executable (`kansoku-server/app/Main.hs`).
- `kansoku-client` — the Haskell server-side SDK: a buffering, batching, retrying event emitter
  over the servant-generated client.

Build and run commands, all from the repository root inside `nix develop`:

```bash
just build   # cabal build all
just test    # cabal test (kansoku-core suite); prefer `cabal test all` to include kansoku-client
just run     # cabal run kansoku-server (listens on :8080, KANSOKU_SERVER_PORT)
just up      # process-compose up: postgres, clickhouse, create_schema
```

### The ingest surface after plan 9 (the shape this plan edits)

Plan 9 leaves the ingest routes as a `NamedRoutes` record — a Haskell record with one field per
route, where each field ties a name to a route type — in
`kansoku-api/src/Kansoku/Ingest/Api.hs` (moved there from `Kansoku/Api/Ingest.hs` by plan 9's
Milestone 3; if the move did not land, edit the file at its old path and note it):

```haskell
data IngestRoutes mode = IngestRoutes
  { postEvent :: mode :- "v1" :> "events" :> ReqBody '[JSON] AnalyticsEvent
                          :> MultiVerb 'POST '[JSON] (AcceptedResponses "Event accepted" IngestAck) (KansokuResult IngestAck),
    postBatch :: mode :- "v1" :> "batch"  :> ReqBody '[JSON] [AnalyticsEvent]
                          :> MultiVerb 'POST '[JSON] (AcceptedResponses "Batch accepted" BatchAck) (KansokuResult BatchAck)
  }
  deriving stock (Generic)
```

**MultiVerb** (plan 9, Milestone 4) is the servant combinator that lists, in the route type, every
HTTP status an operation can answer; the handler returns a plain sum type (`KansokuResult`) with
one constructor per status instead of throwing exceptions. Plan 9's shared machinery lives in
`kansoku-api/src/Kansoku/Api/Response.hs`: `ErrorEnvelopeWire` (the one JSON error body:
`code`/`message`/`retryable`), the `KansokuResult` sum (`KansokuOk` / `KansokuBadRequest` /
`KansokuNotFound` / `KansokuUnavailable`), the `AcceptedResponses`/`OkResponses` response-list
aliases (success plus a shared 400/404/503 error tail), hand-written `AsUnion` instances mapping
the sum onto each list, and helper constructors (`badRequest`, `notFound`, `unavailable`).
Malformed JSON bodies never reach a handler: servant's `ErrorFormatters` (installed by plan 9 in
`kansoku-core/src/Kansoku/Server.hs`) rejects them with HTTP 400 carrying the same envelope.

If plan 9's Milestone 4 did *not* land and the routes still end in
`Verb 'POST 202 '[JSON] BatchAck`, everything in this plan still applies with one substitution:
handlers return the ack directly and signal errors by throwing `ServerError` values with JSON
bodies (the pre-plan-9 `jsonError` helper), and the 413 for the batch cap is a thrown
`ServerError` with status 413. Milestone 0 decides which world you are in.

The current wire acks (in the same module as the routes):

```haskell
data IngestAck = IngestAck
  { accepted :: !Int,
    eventId :: !Text
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

newtype BatchAck = BatchAck
  { accepted :: Int
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)
```

The handlers live in `kansoku-core/src/Kansoku/Ingest/Handler.hs`. The defect this plan fixes is
`validateBatchOrThrow`:

```haskell
validateBatchOrThrow ::
  (Error.Error [ValidationError] :> es) =>
  [AnalyticsEvent] ->
  Eff es [AnalyticsEvent]
validateBatchOrThrow events =
  case partitionEithers (validateEvent <$> events) of
    ([], ok) -> pure ok
    (errs, _) -> Error.throwError (concat errs)
```

It already computes the valid/invalid partition (`partitionEithers`) and then throws the whole
batch away if the error side is non-empty. Note two behaviors that must be preserved: the handler
stamps `receivedAt` with the server clock (`now`) on every event *before* validating
(`(& #receivedAt .~ now) <$> raw` — `#receivedAt` is a generic-lens `OverloadedLabels` field
lens), and the valid events are enqueued in one pgmq round trip via `enqueueMany`
(`kansoku-core/src/Kansoku/Ingest/Producer.hs`, which calls pgmq's `batchSendMessage` and is
already a no-op for an empty list — the all-invalid case needs no special casing).

Validation is pure and lives in `kansoku-api/src/Kansoku/Event/Validation.hs`:

```haskell
data ValidationError
  = EmptyEventId
  | EmptyEventName
  | ReceivedBeforeOccurred UTCTime UTCTime   -- occurredAt, receivedAt
  | MissingRequiredProperty EventName Text
  | WrongPropertyType EventName Text PropertyType
  deriving stock (Generic, Eq, Show)

validateEvent :: AnalyticsEvent -> Either [ValidationError] AnalyticsEvent
```

Today the handler renders these with `Text.pack . show` (`validationErrorText` at the bottom of
the handler module), producing constructor dumps like
`ReceivedBeforeOccurred 2026-07-15 12:00:00 UTC 2026-07-15 11:59:00 UTC` — unreadable for SDK
users. Milestone 1 replaces it with a stable human-readable rendering.

One subtlety worth knowing before you design SDK behavior on top of this: because `receivedAt` is
server-stamped before validation, `ReceivedBeforeOccurred` fires exactly when an event's
`occurredAt` is in the future relative to the *server* clock — i.e. client clock skew. Under
today's whole-batch-400 behavior, one skewed clock wedges a client forever; under partial
acceptance it drops only the skewed events and reports them, which is the correct containment.

### The client SDK

`kansoku-client/src/Kansoku/Client.hs` derives its HTTP calls from the route types, so it follows
the wire change by construction. After plan 9 the derivation is
`ingestClient = genericClient :: IngestRoutes (AsClientT ClientM)` and batch delivery calls
`postBatch ingestClient events` (before plan 9 it is the positional
`_postEvent :<|> postBatch = ServantClient.client (Proxy @IngestAPI)`). The delivery pipeline that
matters here: `deliverWithRetry` runs `postBatch`, retrying with exponential backoff up to
`maxRetries`; `deliverBatch` counts a permanently failed batch into the `dropped :: TVar Int`
counter exposed as `droppedCount`. The client *test suite*
(`kansoku-client/test/Spec.hs`) runs a fake in-process server whose `ackBody` function fabricates
batch responses as `{"accepted": N}` — after Milestone 1's `BatchAck` change that JSON no longer
decodes (the derived `FromJSON` will require the `rejected` field), so the test fake must be
updated in the same commit. The example program `kansoku-client/example/Main.hs` uses only
`trackEvent`/`flush` and needs no source change, but must be compiled and run as acceptance.

### OpenAPI

The OpenAPI document is generated from the same servant types the server serves (plan 9,
Milestone 5): `kansoku-api/src/Kansoku/Api/OpenApi.hs` holds `kansokuOpenApi` plus the DTO
`ToSchema` orphan instances, the `kansoku-openapi` executable writes the checked-in
`docs/api/openapi.json`, and `just openapi-check`
(`cabal run kansoku-openapi && git diff --exit-code docs/api/openapi.json`) fails when the
artifact is stale. `kansoku-core/test/Kansoku/OpenApiSpec.hs` holds conformance tests, including
"every DTO's `ToJSON` validates against its `ToSchema`" and "every operation declares exactly the
shared error tail". Changing `BatchAck` therefore ripples: a new `ToSchema` instance for
`RejectedEvent`, a regenerated artifact, and updated spec expectations — all in the Milestone 1
commit. (Pre-plan-9 fallback: the generator is `kansoku-core/src/Kansoku/OpenApi.hs`, value
`openApiDoc`, no checked-in artifact; then only the instances and the loose spec need updating.)

### Server assembly and configuration

After plan 9, `kansoku-core/src/Kansoku/Server.hs` assembles one servant application:
`kansokuApp pool queueName conn = waiWrapper (serve (Proxy @(NamedRoutes KansokuAPI)) (kansokuServer ...))`,
where `waiWrapper` answers `/health` and `/openapi.json` at the WAI level and delegates everything
else to servant. **Middleware** — a function `Application -> Application` that wraps a WAI app to
observe/modify requests and responses — attaches here. Milestones 2 and 3 wrap the servant
application (inside `waiWrapper`, so `/health` stays untouched); the pre-plan-9 fallback location
is the `_ -> ingestApp pool queueName req respond` branch of the old `pathInfo` dispatch in the
same file.

`kansoku-core/src/Kansoku/Config.hs` holds the `Config` record loaded by `loadConfig` from
environment variables, total with defaults (missing variables never fail). Per the MasterPlan's
integration-point rule, this plan adds **additive fields only** and keeps `loadConfig` total:
`corsAllowedOrigins`, `ingestMaxBodyBytes`, `ingestMaxBatchLength` (Milestones 2 and 3). Note that
`kansokuApp` today does not receive the `Config`; this plan threads it through (an additive
signature change in `Server.hs` and `kansoku-server/app/Main.hs`).

### Code standards

Follow the standards recorded in `/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/core/`
(`standards.md`, `custom-prelude.md`): `GHC2024` with the project's default extensions, import
`Kansoku.Prelude` (never `Prelude` directly), postpositive qualified imports
(`import Data.Text qualified as Text`), generic-lens `OverloadedLabels` field access
(`event ^. #eventId`, `raw & #receivedAt .~ now`), strict fields (`!`) on all record components,
and explicit deriving strategies (`deriving stock` / `deriving newtype` / `deriving anyclass`) on
every `deriving` clause.


## Plan of Work

### Milestone 0 — Reconcile against plan 9's landed state

Scope: no code. Read plan 9's living sections and the working tree; confirm or correct every
assumption this plan makes: (a) the ingest route module path (`Kansoku/Ingest/Api.hs` vs
`Kansoku/Api/Ingest.hs`), (b) whether routes are `MultiVerb` with `KansokuResult` or plain
`Verb 'POST 202`, (c) whether `Kansoku.Api.Response` exists and what its constructors are named,
(d) whether the OpenAPI generator is `Kansoku.Api.OpenApi.kansokuOpenApi` with a checked-in
`docs/api/openapi.json` or the old `Kansoku.OpenApi.openApiDoc`, (e) whether the client is
`genericClient` or positional, and (f) the exact shape of `kansokuApp`/`waiWrapper` in
`Server.hs`. A quick sweep:

```bash
cd /Users/shinzui/Keikaku/bokuno/kansoku-project/kansoku
ls kansoku-api/src/Kansoku/Ingest/ kansoku-api/src/Kansoku/Api/ 2>/dev/null
grep -rn "MultiVerb\|KansokuResult\|IngestRoutes" --include='*.hs' kansoku-api/src | head -20
grep -n "waiWrapper\|kansokuApp" kansoku-core/src/Kansoku/Server.hs
test -f docs/api/openapi.json && echo "artifact checked in"
cabal build all && cabal test all   # baseline must be green before starting
```

Acceptance: this plan's Context and code sketches match the tree (edited here if not, with a
revision note), and the baseline build/test is green. If the repository does not compile, stop:
EP-10 has not landed and this plan cannot start.

### Milestone 1 — The partial-acceptance contract (types + handler + client + OpenAPI, one coherent change)

Scope: this is a **breaking wire change** to `BatchAck`, so the API types, the handler, the
Haskell SDK, its tests, and the OpenAPI document all move together — land it as one or two
commits, never leaving any consumer behind the contract. At the end, `POST /v1/batch` returns 202
whenever the body parses, with `accepted` counting enqueued events and `rejected` describing the
rest; `POST /v1/events` keeps its current behavior (a single event has no partial case: invalid
still answers 400 with the shared error envelope).

**Step 1 — the wire types.** In the ingest route module (`kansoku-api/src/Kansoku/Ingest/Api.hs`
after plan 9), add `RejectedEvent` and change `BatchAck`:

```haskell
-- | One rejected event in a batch. 'index' is the zero-based position of the event in the
-- submitted batch array and is the machine-usable key: SDKs correlate rejections to their
-- buffered events by index (and by 'eventId' when the submitted id was non-empty).
-- 'errors' are stable, human-readable diagnostics for logs and dashboards; they are NOT a
-- machine contract — do not parse them. Their wording may improve without notice.
data RejectedEvent = RejectedEvent
  { index :: !Int,
    eventId :: !(Maybe Text),
    errors :: ![Text]
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | Acknowledgement for POST /v1/batch. 'accepted' counts the events enqueued; 'rejected'
-- lists the events that failed validation, in ascending 'index' order. A batch answers 202
-- whenever its body parses as [AnalyticsEvent] — even when accepted == 0 — so client retry
-- logic is uniform: a 202 means the flush is complete and rejected events must be dropped,
-- never resent. HTTP 400 is reserved for bodies that fail JSON parsing entirely.
data BatchAck = BatchAck
  { accepted :: !Int,
    rejected :: ![RejectedEvent]
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)
```

Export `RejectedEvent (..)` alongside `BatchAck (..)`. `eventId` is `Nothing` exactly when the
submitted event's id was empty (an empty id is useless for correlation and `EmptyEventId` will be
among that event's errors). Note `BatchAck` stops being a `newtype`; the `deriving newtype`
strategy is replaced by the stock/anyclass pair shown. The route types themselves do not change
in this milestone — `postBatch` already returns `BatchAck` through whatever verb idiom plan 9
landed; the *shape* of `BatchAck` is the change. Under MultiVerb, the success value flows through
`KansokuOk BatchAck{..}` into the 202 alternative exactly as before.

**Step 2 — readable, stable error rendering.** In
`kansoku-api/src/Kansoku/Event/Validation.hs`, add and export:

```haskell
-- | Human-readable rendering of a validation error, for RejectedEvent.errors and error
-- envelopes. Wording is stable in spirit but is not a machine contract.
renderValidationError :: ValidationError -> Text
renderValidationError = \case
  EmptyEventId ->
    "eventId must not be empty"
  EmptyEventName ->
    "eventName must not be empty"
  ReceivedBeforeOccurred occurred received ->
    "receivedAt (" <> iso received <> ") precedes occurredAt (" <> iso occurred
      <> "); occurredAt is in the future relative to the server clock"
  MissingRequiredProperty name prop ->
    "event '" <> unEventName name <> "': missing required property '" <> prop <> "'"
  WrongPropertyType name prop expected ->
    "event '" <> unEventName name <> "': property '" <> prop <> "' must be of type "
      <> renderPropertyType expected
  where
    iso = Text.pack . formatTime defaultTimeLocale "%FT%T%QZ"
```

with a small `renderPropertyType :: PropertyType -> Text` (`PTString -> "string"`, and so on;
`PropertyType` is defined in `kansoku-api/src/Kansoku/Event/Registry.hs` — check its constructors
there). `formatTime`/`defaultTimeLocale` come from `Data.Time.Format` (the `time` package, already
a dependency). This lives in `kansoku-api` (not the handler) because it renders a `kansoku-api`
type and future non-Haskell SDK documentation will quote it. Delete the handler's
`validationErrorText = Text.pack . show` and use `renderValidationError` everywhere, including
the single-event 400 path.

**Step 3 — the handler.** In `kansoku-core/src/Kansoku/Ingest/Handler.hs`, delete
`validateBatchOrThrow` and add a pure, exported partition function (exported so the test suite
exercises it without pgmq):

```haskell
-- | Partition a receivedAt-stamped batch into the events to enqueue and the per-event
-- rejections, preserving submission order and zero-based indices.
partitionBatch :: [AnalyticsEvent] -> ([AnalyticsEvent], [RejectedEvent])
partitionBatch events =
  swap (partitionEithers (verdict <$> zip [0 ..] events))
  where
    verdict (i, event) =
      case validateEvent event of
        Right ok -> Right ok
        Left errs ->
          Left
            RejectedEvent
              { index = i,
                eventId =
                  let raw = unEventId (event ^. #eventId)
                   in if Text.null raw then Nothing else Just raw,
                errors = renderValidationError <$> errs
              }
```

(`partitionEithers` collects the `Left`s first, so with rejections on the `Left` it returns
`([RejectedEvent], [AnalyticsEvent])`; `swap` from `Data.Tuple` puts accepted events first to
match the signature. The plumbing is free to differ — the acceptance tests pin the observable
behavior, not this sketch.)

Rewrite `postBatch` to validate per event, enqueue the valid subset, and report the rest —
preserving the existing `receivedAt` stamping with the server clock before validation:

```haskell
postBatch :: [AnalyticsEvent] -> Handler (KansokuResult BatchAck)
postBatch raw = effToHandler pool $ do
  now <- liftIO getCurrentTime
  let stamped = (& #receivedAt .~ now) <$> raw
      (valid, rejectedEvents) = partitionBatch stamped
  _ <- enqueueMany queueName valid
  pure BatchAck {accepted = length valid, rejected = rejectedEvents}
```

Notes: `enqueueMany` is already a no-op on `[]`, so an all-invalid batch enqueues nothing and
still answers 202 with `accepted = 0`. The `Error.Error [ValidationError]` effect stays in the
stack for the single-event path (`postEvent` still uses `validateOrThrow` and answers 400 —
`KansokuBadRequest` under MultiVerb — when its one event is invalid); only the batch path stops
throwing validation errors. The batch endpoint's only remaining failure modes are the pgmq error
(503, unchanged) and — after Milestone 3 — the batch-length 413. Wherever the 400 envelope is
built for the single-event path, join the rendered errors into the envelope `message` with
`"; "` (the `ErrorEnvelopeWire` envelope has no details array; if plan 9's envelope differs,
follow what landed).

**Step 4 — the client SDK.** In `kansoku-client/src/Kansoku/Client.hs` the servant-derived call
follows the type automatically; the behavioral addition is counting rejections as dropped. In
`deliverBatch`, on a successful delivery, add the rejection count to the existing `dropped`
counter:

```haskell
deliverBatch cfg env dropped events = do
  result <- deliverWithRetry cfg env events
  case result of
    Right ack ->
      unless (null (ack ^. #rejected)) $
        atomically (modifyTVar' dropped (+ length (ack ^. #rejected)))
    Left _ -> atomically (modifyTVar' dropped (+ length events))
```

Rejected events are never retried — the 202 already completed the flush. Update the haddock on
`droppedCount` to say it counts buffer-overflow drops, permanently failed deliveries, *and*
server-rejected events.

In `kansoku-client/test/Spec.hs`, fix the fake server's `ackBody` so batch responses decode
against the new `BatchAck` (`{"accepted": N, "rejected": []}`):

```haskell
ackBody request body
  | pathInfo request == ["v1", "events"] = "{\"accepted\":1,\"eventId\":\"test\"}"
  | otherwise =
      case Aeson.decode body :: Maybe [AnalyticsEvent] of
        Just events -> Aeson.encode (Aeson.object ["accepted" Aeson..= length events, "rejected" Aeson..= ([] :: [Aeson.Value])])
        Nothing -> "{\"accepted\":0,\"rejected\":[]}"
```

Add one new client test: a fake server that rejects one event
(`{"accepted": N-1, "rejected": [{"index":0,"eventId":null,"errors":["rejected by test"]}]}`)
and an assertion that `droppedCount` reports `1` and that no retry happened (attempts == 1).
`kansoku-client/example/Main.hs` needs no source change; compiling and running it is acceptance.

**Step 5 — OpenAPI and specs.** In the OpenAPI module (`kansoku-api/src/Kansoku/Api/OpenApi.hs`
after plan 9), add `instance O.ToSchema RejectedEvent` next to the `BatchAck` instance and import
`RejectedEvent`. Regenerate and check in the artifact: `cabal run kansoku-openapi`, then commit
the changed `docs/api/openapi.json` (its `BatchAck` schema gains `rejected`, and a
`RejectedEvent` component schema appears). In `kansoku-core/test/Kansoku/OpenApiSpec.hs`: add a
`RejectedEvent` sample to the DTO `ToJSON`-validates-against-`ToSchema` test, and add an
assertion that the `BatchAck` component schema's properties contain both `accepted` and
`rejected`. Update plan 9's routing test
(`kansoku-core/test/Kansoku/Metrics/RoutingSpec.hs`) where its ingest sentinel constructs
`BatchAck { accepted = 2 }` — it now needs `rejected = []`.

**Step 6 — new handler/DTO specs.** Create `kansoku-core/test/Kansoku/Ingest/HandlerSpec.hs`
(register it in `kansoku-core/test/Spec.hs` and the test stanza's `other-modules`), pure of any
database:

- `partitionBatch` on a 3-valid-plus-2-invalid list (invalid at indices 1 and 3: one with an
  empty `eventId`, one with an empty `eventName`) yields 3 accepted events in submission order
  and rejections exactly `[{index = 1, eventId = Nothing, ...}, {index = 3, eventId = Just "...", ...}]`.
- `partitionBatch` on an all-invalid list yields no accepted events and a full rejection list;
  on an empty list yields `([], [])`.
- A JSON golden assertion pinning the wire shape:
  `Aeson.encode (BatchAck 3 [RejectedEvent 1 Nothing ["eventId must not be empty"]])` decodes
  back to the same value, and its object keys are exactly `accepted` and `rejected` (this is what
  a JS SDK will parse; the test makes the field names load-bearing).
- `renderValidationError` produces the exact strings documented above for each constructor
  (pinning them is fine — the test may be edited when wording improves; the *wire* contract is
  the index, and that is pinned separately).

Acceptance: `cabal build all && cabal test all` green; `just openapi-check` clean; the
Validation section's partial-batch curl transcript reproduces against a live server; the client
example runs. Commit message form (trailers mandatory on every commit in this plan):

```text
feat(ingest)!: partial batch acceptance with per-event rejections

POST /v1/batch now enqueues the valid subset and answers 202 with
BatchAck {accepted, rejected :: [RejectedEvent {index, eventId, errors}]},
including accepted = 0 when every event is invalid; 400 stays reserved for
unparseable bodies. Adds renderValidationError (stable human-readable
diagnostics), updates kansoku-client (rejections count into droppedCount)
and the OpenAPI document in the same change.

BREAKING CHANGE: BatchAck gains the required `rejected` field.

MasterPlan: docs/masterplans/2-kansoku-production-hardening-review-fixes-and-portfolio-service-readiness.md
ExecPlan: docs/plans/14-sdk-grade-ingest-contract-partial-batch-acceptance-cors-and-payload-limits.md
```

### Milestone 2 — CORS for browser ingest

Scope: browsers enforce the *same-origin policy*: a page on `https://app.example.com` may only
read responses from a different origin (kansoku) if the response carries
`Access-Control-Allow-Origin` headers, and a JSON POST is preceded by a *preflight* — an
`OPTIONS` request asking which methods and headers are allowed. Without server support, every
browser SDK call fails. This milestone adds CORS middleware from the `wai-cors` package to the
ingest paths only, configurable origins, and proves the preflight end-to-end.

**Step 1 — dependency.** Add `wai-cors` to `kansoku-core`'s library `build-depends`
(`kansoku-core/kansoku-core.cabal`). It is a small, stable Hackage package
(`Network.Wai.Middleware.Cors`); the project pulls Hackage packages freely (see `cabal.project`),
so no pin change is expected. If the solver refuses, add a `wai-cors >=0.2.7` bound and record it
in Surprises & Discoveries.

**Step 2 — config.** In `kansoku-core/src/Kansoku/Config.hs`, add an additive field and parsing:

```haskell
    -- | Origins allowed to ingest cross-origin. Nothing = any origin (the MVP default:
    -- write keys are public credentials, so origin pinning adds no write-path security).
    -- KANSOKU_CORS_ORIGINS: "*" or a comma-separated list of exact origins
    -- (e.g. "https://app.example.com,https://admin.example.com").
    corsAllowedOrigins :: !(Maybe [Text]),
```

In `loadConfig`, read `KANSOKU_CORS_ORIGINS`; absent or `"*"` yields `Nothing`; otherwise split
on commas (`Text.splitOn ","`, trimming whitespace with `Text.strip`, dropping empties) yielding
`Just origins`. `loadConfig` stays total — there is no invalid value, so no new `ConfigError`
case.

**Step 3 — the middleware, ingest-scoped.** In `kansoku-core/src/Kansoku/Server.hs`, define a
middleware that applies CORS only under `/v1` (the ingest prefix) and leaves every other path —
all of `/metrics/*`, `/health`, `/openapi.json` — without CORS headers:

```haskell
import Data.Text.Encoding qualified as Text.Encoding
import Network.Wai.Middleware.Cors qualified as Cors

-- | CORS on the ingest surface only. Browser SDKs POST events from arbitrary product
-- origins; the metrics surface stays same-origin (EP-15 adds auth there and dashboards are
-- server-mediated). X-Api-Key and Authorization are pre-allowed so EP-15's write keys do
-- not force a second CORS change on deployed SDKs.
ingestCors :: Maybe [Text] -> Middleware
ingestCors allowedOrigins inner req respond =
  case pathInfo req of
    "v1" : _ -> Cors.cors (const (Just policy)) inner req respond
    _ -> inner req respond
  where
    policy =
      Cors.simpleCorsResourcePolicy
        { Cors.corsOrigins =
            (\origins -> (Text.Encoding.encodeUtf8 <$> origins, False)) <$> allowedOrigins,
          Cors.corsMethods = ["POST"],
          Cors.corsRequestHeaders = ["Content-Type", "X-Api-Key", "Authorization"],
          Cors.corsMaxAge = Just 3600
        }
```

The load-bearing facts about `wai-cors`, stated here so the implementer does not rediscover them:
`cors` takes a function from the request to a policy (constant here); `corsOrigins = Nothing`
means any origin is allowed (the open MVP default), while `Just (origins, credentials)` restricts
to the listed origins (the `False` disables `Access-Control-Allow-Credentials`; ingest never
needs cookies); `simpleCorsResourcePolicy`'s default `corsRequestHeaders` is **empty**, and a
JSON POST's `Content-Type: application/json` is *not* a "simple" header, so omitting
`"Content-Type"` from `corsRequestHeaders` makes every browser JSON POST fail preflight — this is
the classic wai-cors pitfall and the reason the header list is explicit. The middleware answers
`OPTIONS` preflights itself (they never reach servant, which would otherwise 405 them), and
`corsMaxAge` lets browsers cache the preflight verdict for an hour so SDK traffic is not doubled.

Attach it around the servant application, inside plan 9's `waiWrapper` so `/health` and
`/openapi.json` are untouched, threading the config in (additive signature change; update the
call in `kansoku-server/app/Main.hs`, which already holds the loaded `Config`):

```haskell
kansokuApp :: Config -> Pool.Pool -> QueueName -> Connection -> Application
kansokuApp config pool queueName conn =
  waiWrapper
    ( ingestCors
        (config ^. #corsAllowedOrigins)
        (serve (Proxy @(NamedRoutes KansokuAPI)) (kansokuServer pool queueName conn))
    )
```

(Pre-plan-9 fallback: wrap only the `ingestApp pool queueName` value in the `_ ->` branch of the
old `pathInfo` dispatch — the path guard then becomes redundant but harmless.)

**Step 4 — a middleware test.** Add `kansoku-core/test/Kansoku/CorsSpec.hs` (register in
`Spec.hs` and the cabal stanza) exercising `ingestCors` over a sentinel inner app with
`Warp.testWithApplication` + `http-client` (both already test dependencies from plan 9's
Milestone 1): an `OPTIONS /v1/batch` with `Origin: https://sdk.example.com` and
`Access-Control-Request-Method: POST` returns 200 with `Access-Control-Allow-Origin` present and
`Access-Control-Allow-Headers` containing `Content-Type`, `X-Api-Key`, and `Authorization`; a
`GET /metrics/events` request with an `Origin` header comes back *without* any
`Access-Control-Allow-Origin` header; with `corsAllowedOrigins = Just ["https://allowed.example"]`
a preflight from a different origin is refused (wai-cors answers preflight failures with a 4xx —
assert "no allow-origin header for the disallowed origin" rather than a specific status, and
record the observed status in Surprises & Discoveries).

Acceptance: `cabal build all && cabal test all` green; the preflight curl transcript in
Validation reproduces against a live server. Commit message form:

```text
feat(server): CORS for the ingest surface

Adds wai-cors middleware scoped to /v1/* with configurable origins
(KANSOKU_CORS_ORIGINS, default open), POST + preflight, and Content-Type /
X-Api-Key / Authorization pre-allowed for EP-15's auth headers. The metrics
surface is deliberately not CORS-opened.

MasterPlan: docs/masterplans/2-kansoku-production-hardening-review-fixes-and-portfolio-service-readiness.md
ExecPlan: docs/plans/14-sdk-grade-ingest-contract-partial-batch-acceptance-cors-and-payload-limits.md
```

### Milestone 3 — Payload and batch limits

Scope: a single global request-body size cap (default 5 MiB) enforced by WAI middleware before
any body is read into memory, and a batch-length cap (default 500 events) enforced in the batch
handler after parsing, both answering HTTP 413 ("Payload Too Large") with a JSON body naming the
limit, both configurable.

**Step 1 — dependency.** Add `wai-extra` to `kansoku-core`'s library `build-depends`. It is
almost certainly already in the project's transitive closure (warp's ecosystem), but per policy
every directly imported package is declared explicitly — verify with
`cabal build kansoku-core` after adding; no pin is expected. The module used is
`Network.Wai.Middleware.RequestSizeLimit` (available in `wai-extra >= 3.1.1`).

**Step 2 — config.** Two additive `Config` fields with total defaults, same pattern as the
existing writer settings:

```haskell
    -- | Maximum request body size in bytes (KANSOKU_INGEST_MAX_BODY_BYTES, default 5 MiB).
    ingestMaxBodyBytes :: !Int,
    -- | Maximum number of events in one POST /v1/batch (KANSOKU_INGEST_MAX_BATCH_LENGTH,
    -- default 500).
    ingestMaxBatchLength :: !Int,
```

parsed with the existing `parseInt` helper, defaults `5242880` (5 MiB = 5 * 1024 * 1024) and
`500`. Add named constants `defaultIngestMaxBodyBytes` / `defaultIngestMaxBatchLength` next to
`defaultServerPort` so tests and docs reference one source of truth.

**Step 3 — the body-size middleware.** In `kansoku-core/src/Kansoku/Server.hs`:

```haskell
import Network.Wai.Middleware.RequestSizeLimit qualified as SizeLimit

-- | One global body cap. 5 MiB bounds the batch endpoint (the largest legitimate body);
-- a per-route 1 MiB /v1/events cap was considered and rejected — the cap exists to bound
-- memory and abuse, not per-route semantics, and one knob is simpler to operate.
bodySizeLimit :: Int -> Middleware
bodySizeLimit maxBytes =
  SizeLimit.requestSizeLimitMiddleware
    ( SizeLimit.setOnLengthExceeded
        (\_ _ _ respond -> respond (payloadTooLarge maxBytes))
        (SizeLimit.setMaxLengthForRequest
            (\_ -> pure (Just (fromIntegral maxBytes)))
            SizeLimit.defaultRequestSizeLimitSettings)
    )

payloadTooLarge :: Int -> Response
payloadTooLarge maxBytes =
  responseLBS
    status413
    [(hContentType, "application/json")]
    ( Aeson.encode
        ( Aeson.object
            [ "code" Aeson..= ("payload_too_large" :: Text),
              "message" Aeson..= ("request body exceeds the " <> Text.pack (show maxBytes) <> "-byte limit"),
              "retryable" Aeson..= False
            ]
        )
    )
```

The JSON body deliberately mirrors plan 9's `ErrorEnvelopeWire` shape (`code`/`message`/
`retryable`) so every error a client can receive — handler-produced, routing-layer, or
middleware — has one shape; if the landed envelope differs, mirror what landed (encode an actual
`ErrorEnvelopeWire` value if the type is importable here — it is, from `kansoku-api`).
`setOnLengthExceeded`'s callback receives the exceeded limit and the wrapped
application/request/respond; ignoring all but `respond` is correct. Note the middleware rejects
requests with a declared `Content-Length` over the cap immediately and guards chunked bodies as
they stream, so an attacker cannot dodge the cap by omitting `Content-Length`. `status413` comes
from `Network.HTTP.Types`.

Composition order matters and is deliberate: `ingestCors` goes *outermost*, `bodySizeLimit`
inside it. A preflight has no body and always passes the size check, but the actual oversized
POST's 413 must still carry the `Access-Control-Allow-Origin` header or browser JavaScript
cannot *read* the rejection (the SDK would see an opaque network error instead of a
`payload_too_large` envelope). wai-cors adds its response headers to whatever the inner app
answers, including the middleware's 413, so this order gives cross-origin callers a readable
413. The reverse order (size check outermost) would strip CORS headers from exactly the
responses browser SDKs most need to understand — recorded here so the next reader does not
"simplify" the nesting:

```haskell
kansokuApp :: Config -> Pool.Pool -> QueueName -> Connection -> Application
kansokuApp config pool queueName conn =
  waiWrapper
    ( ingestCors
        (config ^. #corsAllowedOrigins)
        ( bodySizeLimit
            (config ^. #ingestMaxBodyBytes)
            (serve (Proxy @(NamedRoutes KansokuAPI)) (kansokuServer pool queueName conn))
        )
    )
```

**Step 4 — the batch-length cap and the 413 response alternative.** The batch length is only
knowable after aeson parsing, so it is enforced first thing in `postBatch`. Under plan 9's
MultiVerb idiom the 413 must be a declared response alternative, which means widening the
*shared* response machinery in `kansoku-api/src/Kansoku/Api/Response.hs` (see the Decision Log
entry for why the shared tail is widened rather than forking an ingest-only list):

- Add `Respond 413 "Payload too large" ErrorEnvelopeWire` to both `OkResponses` and
  `AcceptedResponses`, keeping the tail order `400, 404, 413, 503`.
- Add a constructor `KansokuTooLarge !ErrorEnvelopeWire` to `KansokuResult` (between `KansokuNotFound`
  and `KansokuUnavailable`, matching the list order).
- Extend both hand-written `AsUnion` instances with the new alternative in the matching position;
  the exhaustiveness witness (`case impossible of {}` on the one-past-the-end index) moves out by
  one and will not compile until both sides agree — that loud breakage is the design working.
- Add a helper `tooLarge :: Text -> Text -> ErrorEnvelopeWire` with `retryable = False` (resending
  the same oversized batch cannot succeed; the client must split it).

Update plan 9's OpenAPI conformance test ("every operation declares its error responses") from
`["400", "404", "503"]` to `["400", "404", "413", "503"]`, regenerate `docs/api/openapi.json`
(`cabal run kansoku-openapi`), and commit the artifact in the same change.

Then in `kansoku-core/src/Kansoku/Ingest/Handler.hs`, thread the cap in (give `ingestServer` the
limit as a parameter — a plain `Int` or a small `IngestLimits` record if EP-15 is expected to add
more; a plain parameter threaded from `Config` via `kansokuServer` is enough today) and guard:

```haskell
postBatch :: [AnalyticsEvent] -> Handler (KansokuResult BatchAck)
postBatch raw
  | length raw > maxBatchLength =
      pure
        ( KansokuTooLarge
            ( tooLarge
                "batch_too_large"
                ( "batch of " <> Text.pack (show (length raw))
                    <> " events exceeds the limit of " <> Text.pack (show maxBatchLength)
                )
            )
        )
  | otherwise = effToHandler pool $ do
      ... -- Milestone 1 body unchanged
```

(Pre-MultiVerb fallback: `throwError` a `ServerError` with `errHTTPCode = 413` and the same JSON
body via the old `jsonError` helper.)

**Step 5 — specs.** Extend `kansoku-core/test/Kansoku/Ingest/HandlerSpec.hs`: a 501-event list
against the guard logic yields the `KansokuTooLarge` verdict whose message contains both `"501"`
and `"500"` (test the exported pure guard or the handler via a sentinel server — whichever plan
9's test toolkit makes cheap; the curl transcript is the end-to-end proof either way). Add a
size-limit middleware test in `kansoku-core/test/Kansoku/CorsSpec.hs`'s style (or a small
`LimitsSpec`): a `POST /v1/events` with a body of `ingestMaxBodyBytes + 1` bytes against
`bodySizeLimit` over a sentinel app returns 413 with `code = "payload_too_large"`, and the
sentinel is never reached.

Acceptance: `cabal build all && cabal test all` green; `just openapi-check` clean (413 now
documented per operation); both 413 curl transcripts in Validation reproduce. Commit message
form:

```text
feat(ingest): request-size and batch-length limits

Adds a global 5 MiB body cap (wai-extra RequestSizeLimit, 413 JSON envelope)
and a 500-event batch cap enforced in the handler via a new KansokuTooLarge /
413 alternative in the shared MultiVerb response tail. Both limits are
configurable (KANSOKU_INGEST_MAX_BODY_BYTES, KANSOKU_INGEST_MAX_BATCH_LENGTH).

MasterPlan: docs/masterplans/2-kansoku-production-hardening-review-fixes-and-portfolio-service-readiness.md
ExecPlan: docs/plans/14-sdk-grade-ingest-contract-partial-batch-acceptance-cors-and-payload-limits.md
```

Finally, update the MasterPlan
(`docs/masterplans/2-kansoku-production-hardening-review-fixes-and-portfolio-service-readiness.md`):
tick the two EP-14 Progress entries and set the registry row's Status to Complete, with a
`docs(masterplan)` commit carrying both trailers.


## Concrete Steps

All commands run from the repository root
`/Users/shinzui/Keikaku/bokuno/kansoku-project/kansoku`, inside `nix develop`.

Milestone 0 (reconcile, baseline):

```bash
grep -rn "IngestRoutes\|MultiVerb\|KansokuResult" --include='*.hs' kansoku-api/src | head
grep -n "waiWrapper\|kansokuApp\|ingestApp" kansoku-core/src/Kansoku/Server.hs
cabal build all && cabal test all
```

Milestone 1 (partial acceptance — one coherent change):

```bash
# Edit the ingest route module (RejectedEvent, BatchAck), Event/Validation.hs
# (renderValidationError), Ingest/Handler.hs (partitionBatch, postBatch),
# kansoku-client/src/Kansoku/Client.hs (deliverBatch), kansoku-client/test/Spec.hs (ackBody
# + rejection test), the OpenAPI module (ToSchema RejectedEvent), OpenApiSpec, RoutingSpec,
# and add test/Kansoku/Ingest/HandlerSpec.hs (+ Spec.hs and cabal registration).
cabal build all && cabal test all
cabal run kansoku-openapi && git diff --stat docs/api/openapi.json   # BatchAck + RejectedEvent schema changes
git add -A && git commit    # message form in Milestone 1
```

Milestone 2 (CORS):

```bash
# Add wai-cors to kansoku-core.cabal; add corsAllowedOrigins to Config.hs;
# add ingestCors to Server.hs and thread Config through kansokuApp + app/Main.hs;
# add test/Kansoku/CorsSpec.hs (+ registrations).
cabal build all && cabal test all
git add -A && git commit    # message form in Milestone 2
```

Milestone 3 (limits):

```bash
# Add wai-extra to kansoku-core.cabal; add the two limit fields to Config.hs;
# widen Kansoku/Api/Response.hs (413 alternative, KansokuTooLarge, AsUnion, tooLarge);
# add bodySizeLimit to Server.hs (CORS outermost); guard postBatch; update the
# OpenApiSpec error-tail expectation; extend HandlerSpec / add LimitsSpec.
cabal build all && cabal test all
cabal run kansoku-openapi && git diff --stat docs/api/openapi.json   # 413 appears per operation
git add -A && git commit    # message form in Milestone 3
```

Live verification for every milestone (two shells):

```bash
just up      # shell 1: postgres + clickhouse + create_schema; leave running
just run     # shell 2: the server on :8080
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/health   # -> 200 (readiness)
# If EP-10's readiness endpoint is present, also: curl -s http://localhost:8080/ready
```

Ingest needs only postgres (pgmq); ClickHouse matters for the metrics surface and the writer, so
the ingest transcripts work even while ClickHouse is still starting. Then run the transcripts in
Validation and Acceptance.


## Validation and Acceptance

### Milestone 1 — partial batch acceptance, end to end

With the server running (`just run`) and postgres up (`just up`):

```bash
BASE='http://localhost:8080'
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# 3 valid + 2 invalid (index 1: empty eventId; index 3: empty eventName)
jq -n --arg now "$NOW" '[
  {eventId: "evt-ok-0", eventName: "page_view", source: "web", occurredAt: $now, receivedAt: $now},
  {eventId: "",         eventName: "page_view", source: "web", occurredAt: $now, receivedAt: $now},
  {eventId: "evt-ok-2", eventName: "page_view", source: "web", occurredAt: $now, receivedAt: $now},
  {eventId: "evt-bad-3", eventName: "",         source: "web", occurredAt: $now, receivedAt: $now},
  {eventId: "evt-ok-4", eventName: "page_view", source: "web", occurredAt: $now, receivedAt: $now}
]' > /tmp/kansoku-partial-batch.json

curl -s -w '\n%{http_code}\n' -X POST "$BASE/v1/batch" \
  -H 'content-type: application/json' --data-binary @/tmp/kansoku-partial-batch.json
```

Expected (the `receivedAt` values you send are overwritten by the server clock; body shown
re-formatted):

```json
{
  "accepted": 3,
  "rejected": [
    { "index": 1, "eventId": null, "errors": ["eventId must not be empty"] },
    { "index": 3, "eventId": "evt-bad-3", "errors": ["eventName must not be empty"] }
  ]
}
```

with status `202` on the following line. The all-invalid case:

```bash
jq -n --arg now "$NOW" '[{eventId: "", eventName: "", source: "web", occurredAt: $now, receivedAt: $now}]' \
  | curl -s -w '\n%{http_code}\n' -X POST "$BASE/v1/batch" -H 'content-type: application/json' --data-binary @-
# -> {"accepted":0,"rejected":[{"index":0,"eventId":null,"errors":["eventId must not be empty","eventName must not be empty"]}]}
# -> 202
```

Malformed JSON still 400s (servant rejects it before the handler; envelope via ErrorFormatters):

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST "$BASE/v1/batch" -H 'content-type: application/json' -d '{ not json'
# -> 400
```

The single-event endpoint keeps its 400-on-invalid behavior:

```bash
jq -n --arg now "$NOW" '{eventId: "", eventName: "page_view", source: "web", occurredAt: $now, receivedAt: $now}' \
  | curl -s -w '\n%{http_code}\n' -X POST "$BASE/v1/events" -H 'content-type: application/json' --data-binary @-
# -> a JSON error envelope whose message contains "eventId must not be empty"
# -> 400
```

Prove the accepted subset actually reached the queue: the writer drains pgmq into ClickHouse, so
with ClickHouse up,

```bash
clickhouse-client --port "$CLICKHOUSE_TCP_PORT" \
  --query "SELECT count() FROM analytics.events_raw WHERE event_id IN ('evt-ok-0','evt-ok-2','evt-ok-4')"
# -> 3 (within a few seconds; the writer's max latency defaults to 5000 ms)
```

Tests and the SDK:

```bash
cabal test all                       # HandlerSpec, OpenApiSpec, RoutingSpec, client suite all green
cabal run kansoku-client-example    # kansoku-client/example/Main.hs; runs against
                                     # localhost:8080 and exits 0 with the server up
cabal run kansoku-openapi && git diff --exit-code docs/api/openapi.json   # artifact current
curl -s "$BASE/openapi.json" | jq '.components.schemas.BatchAck.properties | keys'
# -> ["accepted", "rejected"]
curl -s "$BASE/openapi.json" | jq '.components.schemas.RejectedEvent.properties | keys'
# -> ["errors", "eventId", "index"]
```

### Milestone 2 — CORS preflight, end to end

The preflight transcript (the decisive acceptance — a browser SDK performs exactly this exchange
before its first POST):

```bash
curl -s -i -X OPTIONS "$BASE/v1/batch" \
  -H 'Origin: https://app.example.com' \
  -H 'Access-Control-Request-Method: POST' \
  -H 'Access-Control-Request-Headers: content-type, x-api-key'
```

Expected response headers (order may vary; with the default-open config `Access-Control-Allow-Origin`
is `*` or the echoed origin depending on wai-cors's rendering — record the observed form in
Surprises & Discoveries and pin it in `CorsSpec`):

```text
HTTP/1.1 200 OK
Access-Control-Allow-Origin: *
Access-Control-Allow-Methods: POST
Access-Control-Allow-Headers: Content-Type, X-Api-Key, Authorization
Access-Control-Max-Age: 3600
```

The actual cross-origin POST then carries the allow-origin header on its 202:

```bash
jq -n --arg now "$NOW" '[{eventId: "evt-cors", eventName: "page_view", source: "web", occurredAt: $now, receivedAt: $now}]' \
  | curl -s -i -X POST "$BASE/v1/batch" -H 'content-type: application/json' -H 'Origin: https://app.example.com' --data-binary @- \
  | grep -i 'access-control-allow-origin'
# -> Access-Control-Allow-Origin: * (or the echoed origin)
```

And the metrics surface is not opened:

```bash
curl -s -i "$BASE/metrics/events?from=2026-06-01&to=2026-06-04" -H 'Origin: https://app.example.com' \
  | grep -ci 'access-control-allow-origin'
# -> 0
```

Restricted-origin mode:

```bash
KANSOKU_CORS_ORIGINS='https://allowed.example' just run   # restart the server with pinned origins
curl -s -o /dev/null -w '%{http_code}\n' -X OPTIONS "$BASE/v1/batch" \
  -H 'Origin: https://evil.example' -H 'Access-Control-Request-Method: POST'
# -> a non-2xx preflight refusal with no allow-origin header
```

### Milestone 3 — limits, end to end

Oversized body (build a ~6 MB single event, over the 5 MiB cap):

```bash
python3 -c "
import json
e = {'eventId':'evt-big','eventName':'page_view','source':'web',
     'occurredAt':'2026-07-15T00:00:00Z','receivedAt':'2026-07-15T00:00:00Z',
     'properties':{'blob':'x'*6291456}}
open('/tmp/kansoku-big.json','w').write(json.dumps(e))
"
curl -s -w '\n%{http_code}\n' -X POST "$BASE/v1/events" \
  -H 'content-type: application/json' --data-binary @/tmp/kansoku-big.json
# -> {"code":"payload_too_large","message":"request body exceeds the 5242880-byte limit","retryable":false}
# -> 413
```

A 501-event batch (each event tiny, so only the length cap can fire):

```bash
jq -n --arg now "$NOW" \
  '[range(0; 501) | {eventId: ("evt-\(.)"), eventName: "page_view", source: "web", occurredAt: $now, receivedAt: $now}]' \
  > /tmp/kansoku-batch-501.json
curl -s -w '\n%{http_code}\n' -X POST "$BASE/v1/batch" \
  -H 'content-type: application/json' --data-binary @/tmp/kansoku-batch-501.json
# -> {"code":"batch_too_large","message":"batch of 501 events exceeds the limit of 500","retryable":false}
# -> 413
```

A 500-event batch still passes (the cap is exclusive above 500):

```bash
jq -n --arg now "$NOW" \
  '[range(0; 500) | {eventId: ("evt-cap-\(.)"), eventName: "page_view", source: "web", occurredAt: $now, receivedAt: $now}]' \
  | curl -s -o /dev/null -w '%{http_code}\n' -X POST "$BASE/v1/batch" -H 'content-type: application/json' --data-binary @-
# -> 202
```

And the document declares the new status:

```bash
curl -s "$BASE/openapi.json" | jq '.paths."/v1/batch".post.responses | keys'
# -> ["202", "400", "404", "413", "503"]
```

Configurability spot-check: restart with `KANSOKU_INGEST_MAX_BATCH_LENGTH=2 just run` and confirm
a 3-event batch answers 413 naming the limit 2.

### Overall acceptance

All three milestones' transcripts reproduce; `cabal build all && cabal test all` is green;
`just openapi-check` is clean; the `kansoku-client` example compiles and runs against the local
server; and the MasterPlan's two EP-14 Progress entries can be honestly ticked: "partial batch
acceptance contract live in API, server, and kansoku-client" and "CORS preflight and
payload/batch limits enforced".


## Idempotence and Recovery

Every step is an ordinary edit plus build; re-running `cabal build all`, `cabal test all`, and
`cabal run kansoku-openapi` is safe and convergent (the OpenAPI artifact is byte-stable: sorted
keys, fixed trailing newline). If a milestone breaks halfway, `git checkout -- .` discards
uncommitted changes and `git reset --hard HEAD` returns to the last committed milestone — commit
at every milestone boundary so that point always exists. There are no database migrations and no
destructive operations in this plan; `just up` services can be restarted freely, and re-running
the curl transcripts re-inserts events whose duplicates collapse in ClickHouse's
`ReplacingMergeTree` (dedup by `event_id`), so repeated validation runs do not accumulate.

The two riskiest edits are (a) the `BatchAck` shape change — a consumer left on the old shape
fails to *decode* responses, which is why the client, its test fake, the routing-test sentinel,
and the OpenAPI artifact move in the Milestone 1 commit, and why the JSON golden test pins the
field names — and (b) the `AsUnion` widening in Milestone 3, which is self-guarding: the
exhaustiveness witness stops compiling until both instances and the constructor agree, so a
half-done widening cannot build, let alone serve. If the 413 widening proves wrong at
implementation time (for example plan 9 landed a different envelope mechanism), fall back to the
thrown-`ServerError` variant described in Milestone 3 and record the decision.


## Interfaces and Dependencies

New package dependencies, both small and Hackage-stable, both added to
`kansoku-core/kansoku-core.cabal` `build-depends` only:

- `wai-cors` (Milestone 2) — `Network.Wai.Middleware.Cors`: `cors`,
  `simpleCorsResourcePolicy`, `CorsResourcePolicy (..)`.
- `wai-extra` (Milestone 3) — `Network.Wai.Middleware.RequestSizeLimit`:
  `requestSizeLimitMiddleware`, `defaultRequestSizeLimitSettings`, `setMaxLengthForRequest`,
  `setOnLengthExceeded`. Likely already transitively present; declared explicitly because it is
  directly imported.

No changes to `cabal.project` pins are expected. `kansoku-api` and `kansoku-client` gain no new
dependencies (`renderValidationError` uses `time`, already present).

What must exist at the end of each milestone (full module paths; reconcile per Milestone 0):

```haskell
-- Milestone 1
-- kansoku-api/src/Kansoku/Ingest/Api.hs (or Kansoku/Api/Ingest.hs pre-move)
data RejectedEvent = RejectedEvent { index :: !Int, eventId :: !(Maybe Text), errors :: ![Text] }
data BatchAck = BatchAck { accepted :: !Int, rejected :: ![RejectedEvent] }

-- kansoku-api/src/Kansoku/Event/Validation.hs
renderValidationError :: ValidationError -> Text

-- kansoku-core/src/Kansoku/Ingest/Handler.hs
partitionBatch :: [AnalyticsEvent] -> ([AnalyticsEvent], [RejectedEvent])  -- exported for specs

-- kansoku-api/src/Kansoku/Api/OpenApi.hs
instance ToSchema RejectedEvent

-- Milestone 2
-- kansoku-core/src/Kansoku/Config.hs
corsAllowedOrigins :: !(Maybe [Text])          -- field on Config; KANSOKU_CORS_ORIGINS

-- kansoku-core/src/Kansoku/Server.hs
ingestCors :: Maybe [Text] -> Middleware
kansokuApp :: Config -> Pool.Pool -> QueueName -> Connection -> Application

-- Milestone 3
-- kansoku-core/src/Kansoku/Config.hs
ingestMaxBodyBytes :: !Int                     -- KANSOKU_INGEST_MAX_BODY_BYTES, default 5242880
ingestMaxBatchLength :: !Int                   -- KANSOKU_INGEST_MAX_BATCH_LENGTH, default 500

-- kansoku-api/src/Kansoku/Api/Response.hs
-- KansokuResult gains KansokuTooLarge !ErrorEnvelopeWire; both response-list aliases gain
-- Respond 413 "Payload too large" ErrorEnvelopeWire; both AsUnion instances extended.
tooLarge :: Text -> Text -> ErrorEnvelopeWire

-- kansoku-core/src/Kansoku/Server.hs
bodySizeLimit :: Int -> Middleware
```

Services used at validation time: postgres with the pgmq extension and ClickHouse, both via
`just up` (`process-compose.yaml`); the server via `just run`; readiness by `GET /health`
(HTTP 200, body `OK`) and, if EP-10's readiness endpoint has landed, `GET /ready`.

Cross-plan contracts this plan must respect: `Kansoku.Config` fields are additive and
`loadConfig` stays total (MasterPlan integration point); the ingest wire types move in the same
commits as `kansoku-client` and the OpenAPI document (MasterPlan integration point "Ingest and
metrics wire types", order EP-9 → EP-14 → EP-15); EP-15 will attach write-key authentication to
the contract this plan finalizes, which is why `X-Api-Key`/`Authorization` are pre-allowed in
CORS and why nothing here hard-codes an assumption that ingest is unauthenticated.
