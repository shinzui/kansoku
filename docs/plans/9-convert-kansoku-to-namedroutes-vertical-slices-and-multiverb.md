---
id: 9
slug: convert-kansoku-to-namedroutes-vertical-slices-and-multiverb
title: "Convert kansoku to NamedRoutes, vertical slices, and MultiVerb"
kind: exec-plan
created_at: 2026-07-09T14:38:45Z
intention: intention_01kxr5jt2heyvt0n768ym9dwqd
master_plan: docs/masterplans/2-kansoku-production-hardening-review-fixes-and-portfolio-service-readiness.md
---

# Convert kansoku to NamedRoutes, vertical slices, and MultiVerb

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Kansoku's metrics API is a loaded gun pointed at production, and this plan unloads it. There are
two defects here, not one. The louder one is visible below: nine interchangeable handlers bound to
their routes by list position alone, so any two can be transposed and the build stays green. The
quieter one is strictly worse, and — after the correction recorded in Surprises & Discoveries,
which falsified this plan's original claim that a `NamedRoutes` record turns a same-typed
transposition into a compile error — it is the **strongest single justification** for this plan.
Kansoku *publishes* an OpenAPI document generated from a servant type —
`toOpenApi (Proxy @KansokuAPI)` — that **nothing serves**: the running server dispatches by hand
on WAI `pathInfo`, so the published contract and the routes actually answered are joined by
nothing but convention and can drift apart silently, with no compile error and no test to catch
it. That is exactly the anti-pattern the canonical recipe names — "Don't Generate From a
Different Type Than You Serve" (`haskell-jitsurei/api/openapi-from-types.md`), which cites this
very shape, the hand-rolled WAI `pathInfo` router, as the thing to eliminate. Folding that
router into one served `NamedRoutes KansokuAPI` record fixes the served-versus-documented defect
outright: the same `Proxy` becomes the server's sole router *and* the document's source, so the
description is *derived from* what is served rather than merely resembling it. For the misordering
defect the fold does less than an earlier draft of this plan claimed. It binds each handler to its
route by name rather than by position, which removes the *positional* failure mode — you cannot
miscount across nine identical slots, and a route added mid-list cannot shift every handler after
it — but it does **not** make a transposition of two same-typed handlers a compile error. With nine
handlers sharing the `MetricQuery` type, writing `users` and `organizations` swapped still
typechecks and serves. The guard against that is the runtime dispatch test in Milestone 1, not the
record and not the compiler; that is why Milestone 1 is the centrepiece of this plan and must land
first.

`kansoku-api/src/Kansoku/Api/Metrics.hs` declares eleven metric endpoints as one positional
chain joined by servant's `:<|>` operator (pronounced "alt", it means "this route *or* that
route"). Nine of those eleven endpoints share a single response-type alias, `MetricQuery`,
differing only in one path literal:

```haskell
type MetricQuery =
  QueryParam' '[Required] "from" Day
    :> QueryParam' '[Required] "to" Day
    :> QueryParam "groupBy" Text
    :> QueryParam "timeGrain" TimeGrain
    :> Get '[JSON] MetricResult

type MetricsAPI =
  "metrics" :> "events"          :> MetricQuery
    :<|> "metrics" :> "page-views"      :> MetricQuery
    :<|> "metrics" :> "sessions"        :> MetricQuery
    :<|> ...
    :<|> "metrics" :> "users"           :> MetricQuery
    :<|> "metrics" :> "organizations"   :> MetricQuery
    :<|> "metrics" :> "custom"          :> MetricQuery
```

Because the server supplies handlers as a matching positional chain — in
`kansoku-core/src/Kansoku/Metrics/Handler.hs`, `metricsServer` is `metricHandler "events" :<|>
metricHandler "page_views" :<|> ...` — nothing but *list position* binds a handler to its route.
The nine `MetricQuery` endpoints all have the *same* Haskell type, so any two of them are
interchangeable. Transpose the `users` and `organizations` handlers in that chain and GHC has
nothing to object to: it compiles, it serves, and `/metrics/users` now answers with the
organizations handler's result. No test in the repository would catch it. This was long taken to
be the single strongest motivating example for the whole "adopt NamedRoutes" effort across the
codebase — but that reading turned on a false premise, that converting to a record would make GHC
reject the swap. It does not, and for a family of nine same-typed handlers the record is *not*
type-checked against transposition any more than the chain is (Surprises & Discoveries). What makes
kansoku the strongest example is not that the record closes this hazard, but that nine same-typed
handlers make it the case that *nothing static* can close it: the runtime dispatch test is the only
guard, so it is load-bearing here in a way it is nowhere else.

After this change, the metrics API is a Haskell *record* — one named field per route — so a
handler is bound to a route by *field name* rather than by list position. Where two routes have
*different* handler types (kansoku's `funnel` and `retention`, and the ingest pair), a
transposition is now a compile error naming the offending field. But the nine metric routes that
share the `MetricQuery` type are exactly where that protection does not reach: swapping any two of
them still typechecks and serves (Surprises & Discoveries). What the record buys those nine is
narrower and still worth having: nine identical slots can no longer be *miscounted*, adding a tenth
metric cannot shift the other nine, a wrong wiring must be written out by name in full view of a
reader rather than fallen into by arithmetic, and the record is what enables the vertical-slice
split that the rest of this plan performs. The load-bearing guard for the same-typed nine is the
runtime dispatch test, elevated to Milestone 1 and asserting each of the nine endpoints returns
*its own* metric. The same treatment is applied to the two-endpoint ingestion API and to the
umbrella that combines them. On top of that, the modules
are reorganized so that everything belonging to one concept (its routes, its DTOs, its query
compiler, its handler) sits under one module prefix, and every handler stops throwing
`ServerError` to signal a 4xx/5xx and instead returns a typed result whose statuses are declared
in the route type (servant's `MultiVerb`), so the error contract is visible in the type, the
generated OpenAPI document, and the generated client.

You can see the change working five ways. First, `cabal build all && cabal test all` stays
green throughout. Second, a new routing test (added *before* the conversion) pins each of the
eleven metric paths — including all nine that share the `MetricQuery` type — to a distinct sentinel
handler and fails loudly if any path reaches the wrong one. This test, not the record, is the only
thing that protects the same-typed nine from a transposition; it survives the NamedRoutes
conversion and the module moves unchanged, and every one of the nine is reachable by it. Third, the
behavioral acceptance in Validation curls all nine `MetricQuery` endpoints against a live server
and asserts each returns *its own* metric identity, never a neighbour's — the concrete proof
that the dispatch guard holds against the assembled server, which is the only proof available since
the compiler offers none for these nine. Fourth, the OpenAPI document is now generated by
`toOpenApi` from the *same* `Proxy (NamedRoutes KansokuAPI)` the server serves, written to a
checked-in `docs/api/openapi.json` by a dedicated `kansoku-openapi` executable, and a CI step
(`cabal run kansoku-openapi && git diff --exit-code docs/api/openapi.json`) turns any un-regenerated
API change into a red build. Fifth — the acceptance unique to this service — a test asserts that
the set of paths the application *serves* equals the set of paths the document *describes*: today
those are two unrelated things, and after the fold they are provably one. That test is the
regression guard that proves the fold happened and stops anyone reintroducing a hand-rolled
route.


## Progress

- [x] Milestone 1 (completed 2026-07-18; the centrepiece): add a routing test that pins each of the eleven metric paths
      (all nine that share `MetricQuery`, plus `funnel` and `retention`) and the two ingest paths
      to a distinct handler, over the *current* `:<|>` API, before any conversion. This is the only
      guard against a same-typed transposition — the record does not type-check the nine against
      it — so it is a hard prerequisite, not a precaution. It must assert each of the nine returns
      *its own* metric. `cabal test all` passes.
- [x] Milestone 2 (completed 2026-07-18): convert `MetricsAPI`, `IngestAPI`, and the umbrella `KansokuAPI` from `:<|>`
      chains to `NamedRoutes` records; rewrite the servers as handler records; rewrite the SDK
      client with `genericClient`; collapse the server's manual `pathInfo` metrics-vs-ingest
      dispatch into one servant application. The Milestone 1 routing test still passes.
- [x] Milestone 3 (completed 2026-07-18): move the layer-first route/DTO modules into vertical slices —
      `Kansoku/Api/Ingest.hs` → `Kansoku/Ingest/Api.hs`, `Kansoku/Api/Metrics.hs` →
      `Kansoku/Metrics/Api.hs`, `Kansoku/Query.hs` → `Kansoku/Metrics/Query.hs`. Update cabals
      and imports. `cabal build all` and the full test suite pass; the routing guard remains green.
- [x] Milestone 4 (completed 2026-07-18): adopt `MultiVerb`. Add `Kansoku/Api/Response.hs` (error envelope, the
      `KansokuResult` sum, the `OkResponses`/`AcceptedResponses` aliases, a hand-written
      `AsUnion` with an exhaustiveness witness, and total envelope constructors). Make every route a `MultiVerb`
      and every handler return a `KansokuResult`. Install `ErrorFormatters` so pre-handler
      rejections carry the same envelope. `cabal build all` and both suites pass: 39 core
      examples and 8 client examples, with only dependency-backed/live checks pending.
- [ ] Milestone 5: adopt the OpenAPI-from-types recipe. Relocate the generator into `kansoku-api`
      as `Kansoku.Api.OpenApi`, deriving the document from the served `Proxy (NamedRoutes
      KansokuAPI)`; assign stable `operationId`s; add a `kansoku-openapi` executable that writes
      `docs/api/openapi.json` (aeson-pretty, sorted keys, trailing newline); check the artifact
      in; add the `cabal run kansoku-openapi && git diff --exit-code` regeneration check; and add
      the conformance tests — exact path set, every operation declares its error responses, every
      DTO's `ToJSON` validates against its `ToSchema`, and the served-path-set-equals-documented-
      path-set guard.
- [ ] Milestone 6: amend the plans of record (`docs/plans/4`, `6`, `7`, `8`) whose code blocks
      specify the `:<|>` shapes this plan removes, and note plan 8's OpenAPI executable and
      conformance tests.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Discovery (pre-implementation audit, 2026-07-09): the umbrella API type
  `Kansoku.Api.KansokuAPI = IngestAPI :<|> MetricsAPI` is **never served through servant**. The
  running server (`kansoku-core/src/Kansoku/Server.hs`, `kansokuApp`) dispatches by WAI
  `pathInfo`: it matches `["health"]`, `["openapi.json"]`, and `"metrics" : _` by hand, sending
  the metrics prefix to `metricsApp` and everything else to `ingestApp`, each of which calls
  `serve` on its *own* sub-API. `KansokuAPI` is used only to generate the OpenAPI document
  (`kansoku-core/src/Kansoku/OpenApi.hs`, `toOpenApi (Proxy @KansokuAPI)`). This means there are
  in fact *three* positional route surfaces to consider — `MetricsAPI` (the dangerous one),
  `IngestAPI`, and the `KansokuAPI` alt used only for OpenAPI — plus a hand-rolled WAI router
  that duplicates what servant should do. Milestone 2 folds all of it into one served record.

- Discovery (served-vs-documented path audit, 2026-07-09): a direct comparison of the two path
  sets, done before this revision. The document `toOpenApi (Proxy @KansokuAPI)` describes exactly
  **thirteen** paths — `/v1/events`, `/v1/batch`, and the eleven `/metrics/*`. The running
  `kansokuApp` serves those thirteen (`serve (Proxy @MetricsAPI)` for the metrics prefix,
  `serve (Proxy @IngestAPI)` for the rest) **plus** `/health` and `/openapi.json`, answered at
  the WAI level. At audit time there were two endpoints **served but undocumented** (`/health`,
  `/openapi.json`) and **none documented but unserved**; EP-10 later added `/ready` as a third
  operational WAI endpoint. The thirteen analytics paths line up *only* because the
  router's `"metrics" : _` prefix happens to match the `"metrics"` literal in the route type and
  its `_ -> ingestApp` catch-all happens to reach the ingest sub-API — a coincidence of two
  independently-edited surfaces, not an enforced invariant. Move a metric under a different
  prefix, add a route to one sub-API but not the WAI dispatch, or add a WAI branch, and the two
  sets desync with no error. That *absent enforcement* — not any present concrete mismatch of the
  thirteen — is the headline defect this plan closes; Milestone 5's served==documented test is
  the enforcement that was missing.

- Discovery (OpenAPI tooling audit, 2026-07-09): kansoku's `cabal.project` **already pins the
  `shinzui` forks, not Hackage** — it lists the local packages `openapi-hs` (4.1.0) and
  `servant-openapi-hs` (4.1.0), the OpenAPI-3.1 toolchain that carries the `HasOpenApi` instance
  for `MultiVerb`; `kansoku-core` depends on both today. This is the correct toolchain: had it
  pinned Hackage `openapi3`/`servant-openapi3`, the 400/404/503 error responses the Milestone 4
  `MultiVerb` conversion adds would be **silently dropped** from the generated document (those
  packages have no `HasOpenApi` instance for `MultiVerb`). No pin change is needed. Milestone 5
  only relocates the *dependency* on the forks from `kansoku-core` to `kansoku-api`.

- Discovery (pre-implementation audit, 2026-07-09): kansoku-core is **already mostly
  domain-first**. `Kansoku/Ingest/*` (Handler, Producer, Queue) and `Kansoku/Writer/*` (Batch,
  Run) and `Kansoku/Metrics/*` (Definition, Handler, Registry) already put the concept at the
  root and the layer at the leaf, which is exactly the target shape. The layer-first residue is
  narrow: it is concentrated in `kansoku-api` under the `Kansoku/Api/*` prefix (the two route
  modules), plus one stray top-level `Kansoku/Query.hs` that is really the metrics query
  compiler. So Milestone 3 is a small, surgical set of three moves, not a sweeping reorg.

- Discovery / falsified premise (2026-07-10): **a `NamedRoutes` record does *not* make a
  transposition of two same-typed handlers a compile error.** An earlier draft of this plan asserted
  throughout that converting the positional `:<|>` chain to a record makes swapping two same-typed
  handlers a compile/field-name error and that the compiler would catch it. That is false, and it
  was falsified by direct experiment in the sibling meibo project (`meibo`,
  `docs/plans/7-adopt-namedroutes-and-vertical-slices.md`, Surprises & Discoveries §§1–3). meibo
  converted its API to `NamedRoutes`, then swapped its two genuinely same-typed handlers
  (`byHandle`/`byCredential`, both `AuthUser -> Text -> Handler (MeiboResult PrincipalView)`) in the
  server record — writing `byHandle = byCredentialH env, byCredential = byHandleH env` — and
  `cabal build meibo-core` **succeeded**. The record removes only the *positional* failure mode: you
  cannot miscount, and a route inserted mid-record cannot shift every later handler. A same-typed
  transposition still typechecks; it must now be written out by name (visible to a reader) but the
  compiler does not reject it. Only a runtime dispatch test catches it. This matters more for kansoku
  than for meibo: meibo had a single same-typed pair, but kansoku has **nine** endpoints sharing the
  `MetricQuery` type, so neither the chain nor the record is type-checked against transposition
  across those nine. The consequence for this plan: Milestone 1's routing test is not a precaution
  but the *only* guard, elevated to the centrepiece; and the canonical
  `haskell-jitsurei/api/servant-routes.md` was corrected in step (see "Positional chains silently
  misroute", "Same-Typed Routes Need a Dispatch Test", and "Field Order Is Not Load-Bearing"). The
  Purpose, current-state, Terms, Milestone 1, Milestone 2, Validation, Idempotence, and Decision Log
  sections were all corrected to reflect this.

- Discovery (2026-07-10, corollary from meibo §3): **field order is not load-bearing for
  static-versus-capture precedence** — servant's router hoists a literal path segment above the
  sibling `Capture` it shadows independent of declaration order (meibo verified this by reordering a
  route record's fields and re-running its whole suite; all tests stayed green). kansoku's metric
  paths are all static literals with no sibling captures, so the question barely arises here, but the
  plan now instructs the implementer to *verify* order-independence in kansoku (reorder the record's
  fields, re-run `cabal test all`, confirm each path still resolves to itself) rather than assume it,
  and to record the result here.

- Discovery (implementation audit, 2026-07-18): the repository resolves `servant`,
  `servant-server`, `servant-client`, and `servant-client-core` 0.20.3.0, plus
  `openapi-hs` and `servant-openapi-hs` 4.1.0. Mori source inspection confirmed that
  MultiVerb is present in Servant and that the fork's `HasOpenApi (MultiVerb ...)`
  instances are compiled only for Servant 0.20.3 or newer. Hackage and upstream release
  tags identify these as the current releases. The earlier `>=0.20` fallback advice was
  therefore too broad; this implementation keeps the already-resolved cohort and adds no
  dependency bound or compatibility workaround.

- Discovery (Milestone 1, 2026-07-18): `Warp.testWithApplication` requires the test
  executable to use GHC's threaded runtime. The first run failed before accepting a
  request with `the TimerManager requires linking against the threaded runtime`;
  adding `ghc-options: -threaded` to `kansoku-core-test` made the database-free
  routing harness reliable.

- Discovery (Milestone 1, 2026-07-18): the runtime guard demonstrably detects the
  same-typed hazard. Temporarily crossing only the `users` and `organizations`
  sentinels compiled and ran, then failed with `expected: "users"` and
  `but got: "organizations"`. Restoring the intended mapping returned the full suite
  to 37 core examples, 0 failures, with 9 dependency-backed examples pending.

- Discovery (Milestone 2, 2026-07-18): `Servant.Client.Generic` is exposed by the
  `servant-client-core` package, not by `servant-client`. Mori source inspection and
  the working meibo client both show it as a direct dependency. `kansoku-client` now
  declares `servant-client-core` explicitly; Cabal continues to resolve the same
  released 0.20.3.0 cohort.

- Discovery (Milestone 2, 2026-07-18): EP-10 and EP-11 changed the assembly context
  after this child plan was authored. `kansokuApp` now carries `ReadyProbe` and must
  retain the WAI-level `/ready` route; metrics handlers consume `QueryPool`, not a
  single ClickHouse `Connection`. The NamedRoutes assembly preserves both completed
  dependencies while removing only the manual metrics-versus-ingest dispatch.

- Discovery (Milestone 2, 2026-07-18): temporarily declaring `pageViews` before
  `events` in `MetricsRoutes` left all 37 core examples green, including the thirteen-
  path sentinel guard. Restoring the presentation order did not change behavior. This
  verifies in Kansoku that record field declaration order is not load-bearing.

- Discovery (Milestone 3, 2026-07-18): the original structural acceptance command's
  `/Query\.hs$` alternative also matched the intended destination
  `Kansoku/Metrics/Query.hs`, so it could not distinguish residue from success. The
  acceptance check now names the three obsolete paths exactly and asserts that each is
  absent; the new paths are asserted present separately.

- Discovery (Milestone 4, 2026-07-18): `AsUnion`'s `Z`/`S` and `I` constructors come
  from `Data.SOP`; Servant uses them internally but does not re-export them from
  `Servant.API.MultiVerb`. Mori located the released Servant source and the working en/meibo
  implementations, and the resolved Cabal plan identifies `sop-core` 0.5.0.2. Therefore
  `kansoku-api` needs `sop-core` as an explicit direct dependency rather than relying on
  Servant's transitive dependency.

- Discovery (Milestone 4, 2026-07-18): changing ingestion to `MultiVerb` changes the
  generated batch client from `ClientM BatchAck` to `ClientM (KansokuResult BatchAck)`.
  Servant's released client source confirms declared HTTP statuses decode into the inner
  result value while transport and decoding failures stay in the outer `ClientError`.
  The SDK retry loop now retries transport failures and retryable 503 envelopes, rejects
  400/404 values without retrying, and has tests for both application paths.


## Decision Log

- Decision: Order the milestones as (1) pin behavior with a routing test, (2) NamedRoutes, (3)
  module moves, (4) MultiVerb, (5) amend the plans of record.
  Rationale: The four technical changes are independent, and interleaving them produces diffs a
  reviewer cannot read (a route-type change tangled with a file rename tangled with a
  status-code change). Risk decreases in this order. The routing test must come *first* because
  the misordering hazard is exactly what every later milestone could silently reintroduce: the
  NamedRoutes conversion re-writes the server by hand (a chance to mis-assign a field), the
  module moves re-thread imports (a chance to swap a re-export), and the MultiVerb change
  rewrites every handler body (a chance to return the wrong result). Pinning path→handler once,
  up front, protects all three. NamedRoutes precedes the moves because a record makes the moves
  purely mechanical (each slice already exports a self-contained record). MultiVerb comes last
  because it is the largest per-handler rewrite and benefits from the routes already being named
  and sliced.
  Date: 2026-07-09

- Decision: The Milestone 1 runtime dispatch test is a **hard prerequisite** of the NamedRoutes
  conversion, not an optional guard around it, and it must assert that each of the nine same-typed
  `MetricQuery` endpoints (`events`, `page-views`, `sessions`, `acquisition`, `feature-adoption`,
  `conversion`, `users`, `organizations`, `custom`) returns *its own* metric identity.
  Rationale: An earlier draft treated the routing test as a nice-to-have that made an otherwise
  compiler-enforced property visible. That rested on a false premise — that a `NamedRoutes` record
  makes a same-typed transposition a compile error — which meibo's experiment falsified (Surprises &
  Discoveries; meibo plan 7 §§1–2). With nine handlers sharing the `MetricQuery` type, neither the
  `:<|>` chain nor the record is type-checked against a swap of any two of them: the swap
  typechecks, builds, and serves. Nothing static can catch it. The dispatch test is therefore the
  *only* thing that protects the conversion, so it must exist and be green before Milestone 2 begins
  and must stay green through Milestones 3 and 4 (whose edits — re-threading imports, rewriting every
  handler body for MultiVerb — are each a fresh opportunity to mis-wire). Because it is the sole
  guard, its coverage must be total over the nine: a test that pinned only some of them would leave
  the unpinned ones swappable in silence.
  Date: 2026-07-10

- Decision: In Milestone 2, collapse the server's hand-written `pathInfo` dispatch between
  metrics and ingest into a single servant application serving the `NamedRoutes KansokuAPI`
  record, keeping `["health"]`, `["ready"]`, and `["openapi.json"]` at the WAI level.
  Rationale: The manual `"metrics" : _ -> metricsApp; _ -> ingestApp` branch in
  `kansoku-core/src/Kansoku/Server.hs` is a second, hand-maintained router that can disagree
  with the type — a route family added to one sub-API but forgotten in the dispatch would 404 or
  worse. A single `serve (Proxy @(NamedRoutes KansokuAPI))` makes servant the sole router and is
  the natural payoff of having a record that mounts both sub-records. Health, readiness, and the
  OpenAPI JSON stay at the WAI level because they are operational/meta endpoints; EP-10 introduced
  readiness after this decision was first recorded.
  Date: 2026-07-09

- Decision: Keep `Kansoku/Event/*` and `Kansoku/Prelude.hs` in `kansoku-api`, and keep
  `Kansoku/ClickHouse.hs` + `Kansoku/ClickHouse/EventRow.hs` where they are in `kansoku-core`.
  Rationale: `Kansoku/Event/*` is the canonical wire model (the `AnalyticsEvent` type and its
  validation) shared by both the server and the generated client; wire types living in the
  `-api` package is the correct layer placement, and the modules are already domain-first
  (`Event` is the root). `Kansoku/Prelude.hs` is a shared prelude, aggregate-agnostic. The
  ClickHouse modules are a genuinely cross-slice storage substrate: the Writer slice *writes*
  `analytics.events_raw` and the Metrics slice *reads* it and the rollups. No single slice owns
  it, exactly like a cross-aggregate store. Moving it under one slice would misrepresent the
  dependency. These are deliberate keeps, not oversights.
  Date: 2026-07-09

- Decision: In Milestone 4, use one shared `KansokuResult` sum with statuses 200/202/400/404/503
  and replace the four `notImplemented` stubs' HTTP 501 responses with an HTTP 404 carrying
  `code = "not_implemented"` in the envelope.
  Rationale: The MultiVerb convention (recorded in `haskell-jitsurei/api/servant-routes.md`)
  says share one response list across the service unless there is a strong reason not to, so that
  the fault-to-result conversion is total. HTTP 501 is idiosyncratic to four stub endpoints and
  would force a metrics-only widening of the shared list. Folding the stubs into a 404 whose
  machine-readable `code` field still names them "not_implemented" keeps one list, keeps the
  per-endpoint discriminator the Validation section relies on, and is an honest status ("this
  named resource is not available"). This is a deliberate, documented behavior change; Milestone
  4 updates the Milestone 1 test's pinned status expectations in the same commit.
  Date: 2026-07-09

- Decision: Preserve Servant MultiVerb's two client failure channels in the ingestion SDK.
  Rationale: a returned 400/404/503 is an application answer represented by `KansokuResult`,
  while a dropped connection or undecodable response is an outer `ServantClient.ClientError`.
  `deliverWithRetry` converts either channel into the SDK's `ClientError`: `DeliveryRejected`
  carries a typed envelope and `DeliveryFailed` carries the transport error. It retries only
  transport failures and `retryable = True` envelopes, preventing invalid events from being
  resubmitted while still retrying queue outages.
  Date: 2026-07-18

- Decision: Keep the package split (`kansoku-api`, `kansoku-core`, `kansoku-client`,
  `kansoku-server`) exactly as it is.
  Rationale: Packages are dependency boundaries, not domain boundaries. `kansoku-client` depends
  on `kansoku-api` to obtain the route *types* without dragging in `kansoku-core`'s ClickHouse
  and effect machinery. Vertical slicing rearranges module *paths inside* each package; it does
  not merge packages.
  Date: 2026-07-09

- Decision: Treat the served-vs-documented split as the headline defect this plan closes — after
  the 2026-07-10 falsification (below), the **strongest single justification** for the plan, ahead
  of the misordering hazard rather than merely co-equal with it — and add (Milestone 5) a test
  asserting the served path set equals the documented path set.
  Rationale: The pre-implementation audit found that `toOpenApi (Proxy @KansokuAPI)` describes a
  type the server never serves — the server routes by hand on WAI `pathInfo`. This is exactly the
  anti-pattern named in `haskell-jitsurei/api/openapi-from-types.md` ("Don't Generate From a
  Different Type Than You Serve"), which cites the hand-rolled WAI `pathInfo` router by name: a
  document that describes a type with no necessary relationship to what the service answers, free
  to drift silently. Milestone 2's fold (one served `NamedRoutes KansokuAPI`) is what *makes* the
  document the real contract. But a fold with no test can be silently undone by a future
  hand-rolled route, so the served==documented test is the regression guard that proves the fold
  happened and keeps it holding. Why this now leads: the misordering hazard is real, but the record
  conversion does not by itself close it (the nine same-typed handlers stay swappable to the
  compiler — Surprises & Discoveries), so that argument's strength now rests on a runtime dispatch
  test. The served-vs-documented drift, by contrast, is a hazard that *nothing* in the codebase
  catches today — no compile error, no test, only convention — and the fold plus its guard is a
  structural fix that removes the drift entirely. That makes it the more decisive reason to do this
  work.
  Date: 2026-07-09 (reordered 2026-07-10)

- Decision: In Milestone 5, adopt the OpenAPI-from-types recipe in full. Relocate the generator
  from `kansoku-core/src/Kansoku/OpenApi.hs` into `kansoku-api` as `Kansoku.Api.OpenApi` (renaming
  the value `openApiDoc` to `kansokuOpenApi`), carrying its DTO `ToSchema`/`ToParamSchema` orphans
  with it; assign stable `operationId`s; add a `kansoku-openapi` executable
  (`kansoku-api/app/OpenApi.hs`) that writes `docs/api/openapi.json` with aeson-pretty, sorted
  keys, and a trailing newline; check the artifact in; and enforce it with
  `cabal run kansoku-openapi && git diff --exit-code docs/api/openapi.json`.
  Rationale: The recipe puts the document "in one module, in the package that owns the route
  types", because everything the document contains comes from the API type and its DTOs — both of
  which live in `kansoku-api`. Placing the generator there confines the orphan instances to the
  package whose types they describe and lets `kansoku-api` own its published contract, exactly as
  `meibo-api/src/Meibo/Api/OpenApi.hs` + `meibo-api/app/OpenApi.hs` do. The cost is that
  `kansoku-client` (which depends on `kansoku-api` for route types) gains `openapi-hs` /
  `servant-openapi-hs` in its transitive closure; this is accepted because that toolchain is a
  pure, light OpenAPI library, not the heavy `kansoku-core` runtime (ClickHouse, effectful, warp)
  the package split exists to keep out of the client. The checked-in artifact plus the diff check
  make drift a red build — the enforcement the current loose `OpenApiSpec` (hasKey probes) does
  not provide.
  Date: 2026-07-09

- Decision: Keep `/health`, `/ready`, and `/openapi.json` outside the servant `KansokuAPI` record
  (served at the WAI level); the document describes exactly the thirteen analytics-contract paths.
  Rationale: All three are operational/meta endpoints, not part of the analytics contract.
  `/openapi.json` *delivers* the document and returns the raw document rather than a DTO — putting
  it into the document it serves is self-referential noise. `/health` is a liveness probe
  returning plain `"OK"` with no DTO and, decisively, no error modes; folding it into the record
  would either force an artificial `MultiVerb` error tail onto a route that genuinely has none, or
  require exempting it from the "every operation declares its error responses" conformance test —
  weakening a test that should be total. `/ready` is a dependency probe introduced by EP-10 and
  returns operational state rather than analytics data. Keeping all three out keeps the documented
  surface exactly the analytics contract and keeps the error-tail test exemption-free. The served==documented test
  accounts for this precisely: it asserts (a) the documented path set equals the servant-routed
  path set, and (b) the only WAI-level escapes are exactly the allowlist
  `{/health, /ready, /openapi.json}`
  — so a *new* hand-rolled route fails the test rather than passing unnoticed. To make (b)
  testable without a live ClickHouse, Milestone 5 factors `kansokuApp`'s WAI wrapper to accept the
  inner servant `Application` as an argument, so the wrapper can be exercised over a sentinel
  servant app.
  Date: 2026-07-09

- Decision: Make no change to the OpenAPI toolchain pins; `cabal.project` already pins the
  `shinzui` forks (`openapi-hs` 4.1.0, `servant-openapi-hs` 4.1.0).
  Rationale: The forks are the only toolchain that emits the `MultiVerb` error responses Milestone
  4 adds; Hackage `openapi3`/`servant-openapi3` would drop them silently, describing a service
  that only ever succeeds. kansoku already has the right pins, so Milestone 5 relocates the
  *dependency* from `kansoku-core` to `kansoku-api` but changes no pin. Recorded so a future reader
  does not "simplify" to the Hackage packages and quietly destroy the error contract.
  Date: 2026-07-09

- Decision: Associate EP-9 implementation commits with the parent MasterPlan intention
  `intention_01kxr5jt2heyvt0n768ym9dwqd`.
  Rationale: The user asked to use the intention recorded in the plan being implemented;
  EP-9 is now a child of MasterPlan 2, whose intention is the active initiative-level
  identifier. The child frontmatter and commit examples are aligned so the plan remains
  self-contained.
  Date: 2026-07-18

- Decision: Exercise the current umbrella `KansokuAPI` chain in one sentinel application
  during Milestone 1, rather than stand up the ingest and metrics sub-APIs separately.
  Rationale: Serving `sentinelIngestServer :<|> sentinelMetricsServer` through
  `Proxy @KansokuAPI` pins all thirteen paths and the current top-level composition in one
  database-free test. The exported sentinel servers remain reusable when Milestone 2
  converts each level to records and when Milestone 5 compares served and documented paths.
  Date: 2026-07-18

- Decision: Preserve `/ready` alongside `/health` and `/openapi.json` as a WAI-level
  operational route while serving the thirteen analytics paths through the one
  `kansokuAPI :: Proxy (NamedRoutes KansokuAPI)` value.
  Rationale: EP-10 introduced readiness after EP-9 was authored. It is operational rather
  than part of the analytics contract, and removing or documenting it here would violate
  the completed dependency. Milestone 5's WAI allowlist and conformance test must therefore
  include all three operational/meta escapes, not the older two-route list.
  Date: 2026-07-18


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion. Compare the
result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

### What this repository is

Kansoku is a product-analytics service. Applications send it *analytics events* (a page view, a
signup, a feature use) over HTTP; kansoku queues them, writes them into ClickHouse (a
column-oriented analytics database), and answers *semantic metric* queries over them ("how many
active users per day", "session counts", "the signup conversion rate"). It is a Haskell project
built with `cabal`, using the GHC2024 language edition, pinned by `cabal.project` at the
repository root `/Users/shinzui/Keikaku/bokuno/kansoku-project/kansoku`.

The four kansoku packages, each a directory at the repository root with its own `.cabal` file:

- `kansoku-api` — the HTTP contract and wire types, as *types only*: the servant route types,
  the `AnalyticsEvent` model and its validation, the metric DTOs, and the shared `Kansoku.Prelude`.
  Both the server and the generated client depend on this so they cannot disagree about the wire
  format. No handlers, no database. After Milestone 5 it also owns the OpenAPI generator
  (`Kansoku.Api.OpenApi`), the `kansoku-openapi` executable, and the checked-in
  `docs/api/openapi.json` — the document lives with the route types it is derived from.
- `kansoku-core` — the effectful runtime: configuration, logging, the pgmq queue producer, the
  ClickHouse storage adapter, the batch writer, the metric query compiler and handlers, and the
  HTTP application assembly. (Today it also holds the OpenAPI generator, `Kansoku.OpenApi`;
  Milestone 5 relocates that to `kansoku-api`.)
- `kansoku-client` — a lightweight Haskell SDK for *emitting* events, plus a servant-generated
  client for the ingestion endpoints. Depends on `kansoku-api`.
- `kansoku-server` — the executable that wires config, pools, and the WAI application together.

The OpenAPI toolchain is pinned in `cabal.project` to the `shinzui` forks — the local packages
`openapi-hs` (4.1.0) and `servant-openapi-hs` (4.1.0), which emit OpenAPI 3.1 and, decisively,
carry the `HasOpenApi` instance for `MultiVerb` that Hackage `openapi3` / `servant-openapi3` lack.
Milestone 4's error responses reach the generated document *only* through that instance; on the
Hackage packages they would vanish with no error and no warning, leaving a document that describes
a service that only ever succeeds. No pin change is needed — the forks are already in place; this
is stated so it is not "simplified" away.

### Terms used in this plan

Because this plan must be self-contained, every term of art is defined here in plain language.

**Servant** is the Haskell library kansoku uses to describe HTTP APIs as *types*. A route is a
type built from combinators joined by the `:>` operator; for example
`"metrics" :> "sessions" :> Get '[JSON] MetricResult` describes `GET /metrics/sessions` returning
a JSON `MetricResult`.

**`:<|>`** (pronounced "alt") is servant's operator meaning "this route *or* that route". An API
built from it is a *positional chain*: `RouteA :<|> RouteB :<|> RouteC`. The server must supply
handlers in exactly the same order and grouping: `handlerA :<|> handlerB :<|> handlerC`. Nothing
but position associates a handler with its route. When two routes in the chain have the same
Haskell type, swapping their handlers is undetectable to the compiler.

**`NamedRoutes`** is servant's alternative to a chain: the API is a Haskell *record*, one field
per route, parameterized by a type variable conventionally named `mode`. Each field joins its
name to its route type with the `:-` operator (from `Servant.API.Generic`). Servant instantiates
`mode` differently for different purposes: `AsApi` yields a description of the API, `AsServerT m`
yields a record of *handlers*, `AsClientT` yields a record of *client functions*. Because
handlers are supplied by field name, a route inserted mid-record cannot shift the others and a
handler cannot be attached to the wrong route by *miscounting*. Note carefully what this does and
does not buy: transposing two routes whose handlers have *different* types is a compile error
naming the offending field, but transposing two routes whose handlers have the *same* type
typechecks and serves exactly as the chain did — the record removes the positional failure mode,
not the same-typed one. This distinction is load-bearing for kansoku, where nine handlers share
one type; see the current-state discussion and Surprises & Discoveries. Serving a `NamedRoutes`
record uses a `Proxy` over `NamedRoutes R`.

**A vertical slice** means: every module belonging to one concept shares one module prefix named
for that concept, and the *layer* (its API/routes, its query compiler, its handler, its storage)
is the *last* component of the module path, never the first. So `Kansoku/Metrics/Api.hs`, not
`Kansoku/Api/Metrics.hs`. Packages stay split by layer (they are dependency boundaries); module
*paths inside* each package are concept-first.

**A concept** in kansoku is a stage of the analytics pipeline that owns a coherent slice of the
code. Kansoku is not a domain-driven design with consistency-boundary "aggregates"; its concepts
are: **Event** (the canonical event model and its validation), **Ingest** (the write-side HTTP
API and the pgmq queue producer), **Writer** (the queue consumer that batches into ClickHouse),
and **Metrics** (the query-side HTTP API, the metric definitions/registry, and the SQL query
compiler). Plus a shared **ClickHouse** storage substrate and assembly/infrastructure modules
that no single concept owns.

**pgmq** is a PostgreSQL-backed message queue (a Postgres extension with a Haskell binding). The
ingest handler enqueues validated events into it; the writer dequeues and writes them to
ClickHouse. It is relevant here only because the ingest and writer handlers thread a `Pool` (a
Postgres connection pool) and a `QueueName`; this plan does not change the queue.

**`MultiVerb`** is a servant combinator kansoku does *not* yet use. Today a route ends in a plain
verb like `Get '[JSON] MetricResult`, and a handler signals a 404 by *throwing* a `ServerError`
(`throwError err404`). That 404 appears nowhere in the type: not in the generated OpenAPI
document, not in the generated client's result type, and nothing forces the handler to be able
to produce it. With `MultiVerb`, the route instead ends in a type-level list enumerating every
status the operation can answer, and the handler returns a plain sum type with one constructor
per status. Errors become *values in the type* rather than exceptions thrown past it. Milestone 4
introduces this.

**`AsUnion`** is the servant type class that maps a handler's plain sum type onto a `MultiVerb`
response list positionally. This plan writes its instances *by hand* (never derived), because the
correspondence between each constructor and its response alternative is the load-bearing fact of
the design and must break loudly at compile time if the list changes.

**`ErrorFormatters`** is servant's hook for formatting errors raised by the *routing layer* —
before any handler runs — such as a malformed request body or an unmatched route. Supplying it in
the server context makes those pre-handler rejections emit the same error envelope as the
handler-produced ones, so a client sees one consistent error shape.

### The rules this plan implements

These rules are recorded canonically in the `haskell-jitsurei` repository at
`api/servant-routes.md`. Per the ExecPlan specification this plan is self-contained, so the three
rules it depends on are restated here in full:

1. **Define the API as a `NamedRoutes` record, never as a positional `:<|>` chain.** A record
   binds handler to route by name. `:<|>` remains correct for *mounting* records inside a host
   application, where the mounted alternatives have distinct types; it is never correct for
   enumerating the routes inside one API.

2. **Organize modules by concept, not by layer.** The layer is the leaf of the module path.
   Packages stay split by layer because packages are dependency boundaries; module trees inside
   each package are concept-first.

3. **Make every terminal verb a `MultiVerb`** whose response list declares the operation's error
   statuses, so errors are values in the type rather than exceptions thrown past it. Share one
   response list across the service so the fault-to-result conversion is total. Write the
   `AsUnion` instance by hand with an exhaustiveness witness.

4. **Generate the OpenAPI document from the served route types, never by hand, and check the
   artifact in.** `toOpenApi` derives the document from the *same* `Proxy` the server serves; a
   `kansoku-openapi` executable writes it to `docs/api/openapi.json` (aeson-pretty, sorted keys,
   trailing newline); CI regenerates and diffs. A document generated from a type the server does
   not serve is decorative. This rule is recorded canonically in
   `haskell-jitsurei/api/openapi-from-types.md`; Milestone 5 implements it.

### The current state, in detail

The metrics route type, `kansoku-api/src/Kansoku/Api/Metrics.hs`, defines eleven endpoints under
the `metrics` prefix. Read carefully, because the exact division matters:

- **Nine endpoints share the `MetricQuery` alias** (`from` and `to` required, `groupBy` and
  `timeGrain` optional, returning `MetricResult`): `events`, `page-views`, `sessions`,
  `acquisition`, `feature-adoption`, `conversion`, `users`, `organizations`, `custom`. These nine
  are all the *same Haskell type*. They are the misordering hazard.
- **Two endpoints have distinct types**: `funnel` adds a required `steps` query parameter, and
  `retention` adds an optional `days` query parameter. They are safe from transposition against
  the nine and against each other, because their types differ.

The matching handler chain, `kansoku-core/src/Kansoku/Metrics/Handler.hs`, `metricsServer`, wires
them positionally:

```haskell
metricsServer conn =
  metricHandler "events"
    :<|> metricHandler "page_views"
    :<|> sessionsHandler
    :<|> funnelHandler
    :<|> retentionHandler
    :<|> notImplemented "acquisition"
    :<|> notImplemented "feature_adoption"
    :<|> metricHandler "conversion_rate"
    :<|> metricHandler "active_users"
    :<|> notImplemented "organizations"
    :<|> notImplemented "custom"
```

Every handler in this chain has the type `Day -> Day -> Maybe Text -> Maybe TimeGrain -> Handler
MetricResult` *except* `sessionsHandler` (position 3, no `timeGrain` — actually the same shape),
`funnelHandler` (position 4, takes `Text` for steps), and `retentionHandler` (position 5, takes
`Maybe Text` for days). The nine `MetricQuery` handlers occupy positions 1, 2, 6, 7, 8, 9, 10, 11
and — because `sessions` also reduces to the `MetricQuery` shape — position 3 as well. Any two of
those same-typed positions can be swapped with no compiler complaint. The concrete example from
the audit: swap positions 9 (`users` → `metricHandler "active_users"`) and 11-region
(`organizations` → `notImplemented "organizations"`) and the build stays green while
`/metrics/users` starts answering as organizations and vice versa. Crucially, this is a property of
the handler *types*, not of the `:<|>` operator: converting `MetricsAPI` to a `NamedRoutes` record
does not change it. Those same nine handlers, assigned by field name in the Milestone 2 record,
remain interchangeable to the compiler — the same swap, written into the record's `users` and
`organizations` fields, still typechecks and serves (Surprises & Discoveries). The record ends the
*positional* accidents (miscounting, a mid-list insertion shifting every later handler); it does
not end the same-typed one. Only the Milestone 1 dispatch test does.

Handlers signal errors by throwing `ServerError`: `err404` (metric not found), `err400`
(invalid funnel steps / retention days), `err501` (the four `notImplemented` stubs), and `err503`
(a ClickHouse query failure, caught from `try @SomeException`). Each builds a JSON body by hand
via the `jsonError` helper. The `MetricResult` returned on success carries a `metric :: Text`
field naming the metric — this field is set by the handler from the metric definition, *not* by
the query, so it is present even against an empty ClickHouse.

The ingestion route type, `kansoku-api/src/Kansoku/Api/Ingest.hs`:

```haskell
type IngestAPI =
  "v1" :> "events" :> ReqBody '[JSON] AnalyticsEvent :> Verb 'POST 202 '[JSON] IngestAck
    :<|> "v1" :> "batch" :> ReqBody '[JSON] [AnalyticsEvent] :> Verb 'POST 202 '[JSON] BatchAck
```

Two endpoints with *distinct* types (`IngestAck` vs `BatchAck`), so the transposition hazard is
low here, but it is still a positional chain and its handler (`ingestServer = postEvent :<|>
postBatch`) and its client (`_postEvent :<|> postBatch = ServantClient.client (Proxy @IngestAPI)`
in `kansoku-client/src/Kansoku/Client.hs`) both destructure positionally. Ingest handlers signal
`err400` (validation failed) and `err503` (queue unavailable).

The umbrella, `kansoku-api/src/Kansoku/Api.hs`:

```haskell
type KansokuAPI = IngestAPI :<|> MetricsAPI
```

used only by `kansoku-core/src/Kansoku/OpenApi.hs`. As noted in Surprises & Discoveries, the
running server does not serve it; `kansoku-core/src/Kansoku/Server.hs` routes by hand.

### The module map (current)

In `kansoku-api/src`:

```text
Kansoku/Api.hs            -- umbrella KansokuAPI (layer-first)
Kansoku/Api/Ingest.hs     -- IngestAPI + IngestAck/BatchAck DTOs (layer-first)
Kansoku/Api/Metrics.hs    -- MetricsAPI + MetricResult/MetricPoint/TimeGrain DTOs (layer-first)
Kansoku/Event.hs          -- Event facade (concept-first; keep)
Kansoku/Event/Registry.hs
Kansoku/Event/Types.hs
Kansoku/Event/Validation.hs
Kansoku/Prelude.hs        -- shared prelude (keep)
```

In `kansoku-core/src`:

```text
Kansoku.hs                     -- umbrella (keep)
Kansoku/ClickHouse.hs          -- storage substrate (keep; cross-slice)
Kansoku/ClickHouse/EventRow.hs -- storage substrate (keep; cross-slice)
Kansoku/Config.hs              -- infra (keep)
Kansoku/Ingest/Handler.hs      -- concept-first already
Kansoku/Ingest/Producer.hs     -- concept-first already
Kansoku/Ingest/Queue.hs        -- concept-first already
Kansoku/Logging.hs             -- infra (keep)
Kansoku/Metrics/Definition.hs  -- concept-first already
Kansoku/Metrics/Handler.hs     -- concept-first already
Kansoku/Metrics/Registry.hs    -- concept-first already
Kansoku/OpenApi.hs             -- OpenAPI generator (RELOCATES to kansoku-api in Milestone 5)
Kansoku/Postgres.hs            -- infra (keep)
Kansoku/Query.hs               -- STRAY: metrics query compiler at top level
Kansoku/Runtime.hs             -- infra (keep)
Kansoku/Server.hs              -- assembly (keep)
Kansoku/Telemetry.hs           -- infra (keep)
Kansoku/Writer/Batch.hs        -- concept-first already
Kansoku/Writer/Run.hs          -- concept-first already
```

The only layer-first residue is the three modules `Kansoku/Api/Ingest.hs`,
`Kansoku/Api/Metrics.hs`, and the stray `Kansoku/Query.hs`.

### Build, run, and test commands

All commands run from the repository root
`/Users/shinzui/Keikaku/bokuno/kansoku-project/kansoku`, inside the nix dev shell (enter it with
`nix develop` if you are not already in it). The `justfile` provides the canonical recipes:

```bash
just build   # wraps: cabal build all
just test    # wraps: cabal test        (the kansoku-core test suite)
just run     # wraps: cabal run kansoku-server
just up      # process-compose up: starts postgres, clickhouse, create_schema
```

There are two test suites: `kansoku-core-test` (`kansoku-core/test/`, run by `just test` /
`cabal test`) and `kansoku-client-test` (`kansoku-client/test/`). Prefer `cabal test all` to run
both.

**Do the ClickHouse-dependent tests need a live database?** No — they degrade gracefully. The
ClickHouse-touching specs (`Kansoku.ClickHouseSpec`, `Kansoku.Writer.BatchSpec`) wrap their body
in a `withClickHouse` helper that tries to open a connection and, on failure, calls
`pendingWith "ClickHouse not reachable: ..."`. A pending example is reported as skipped, not
failed, so `cabal test all` passes green with no ClickHouse running. The specs central to this
refactor need no database at all: `Kansoku.QuerySpec` asserts on the *SQL strings* the compiler
produces (pure), and the new routing test (Milestone 1) uses sentinel handlers that never touch
ClickHouse. So every milestone's `cabal test all` acceptance runs without any live service.

**When is a live service required?** Only for the *behavioral* acceptance in Validation — curling
the running server's real metrics endpoints — because the real handlers open a ClickHouse
connection and return HTTP 503 if it is unreachable. The Validation section explains exactly how
to stand ClickHouse up (`just up`, then `just ch-migrate`, then `just ch-fixtures-ep6`) and notes
that even an *empty but reachable* ClickHouse suffices to prove the misordering fix, because the
discriminating `metric` field is set independent of the query result.


## Plan of Work

### Milestone 1 — Pin the routing behavior before touching anything

Scope: one new test module and the test-suite dependency additions it needs. No production code
changes. This milestone must land first, because it is the *only* guard that protects the
conversion from a same-typed transposition. The record conversion in Milestone 2 does not
type-check the nine `MetricQuery` routes against a swap — writing `users` and `organizations`
crossed still compiles and serves (Surprises & Discoveries) — so nothing but this runtime test
stands between a mis-wired record and production. It is a hard prerequisite of the conversion, not
a precaution around it, and it must assert that each of the nine same-typed endpoints returns *its
own* metric, so a swap of any two of them turns a test red.

The goal is a runtime test that stands up a servant application over the *current* `MetricsAPI`
and `IngestAPI` types, wired to *sentinel* handlers — handlers that ignore their inputs and
return a value that uniquely identifies which route was hit — then issues an HTTP request to each
of the thirteen paths (eleven metric, two ingest) and asserts the response identifies the correct
route. Because the sentinel handlers do no real work, no ClickHouse or Postgres is involved.

Create `kansoku-core/test/Kansoku/Metrics/RoutingSpec.hs`. Its shape:

- Build a value `sentinelMetricsServer :: Server MetricsAPI` whose handlers each return a
  `MetricResult` whose `metric` field is the *path literal* of the route (`"events"`,
  `"page-views"`, …, `"custom"`) and whose `points` is empty. For the `funnel` and `retention`
  handlers (which take an extra parameter) return `metric = "funnel"` / `"retention"` likewise.
  The assertions that matter most are the nine that share the `MetricQuery` type — `events`,
  `page-views`, `sessions`, `acquisition`, `feature-adoption`, `conversion`, `users`,
  `organizations`, `custom` — because those nine are the ones neither the `:<|>` chain nor the
  Milestone 2 record type-checks against a transposition. Every one of the nine must have its own
  distinct sentinel identity and its own assertion, so a swap of any two of them fails a test.
  Because you are writing this over the current `:<|>` chain, write the sentinel server as the
  same-shaped positional chain — *this is deliberate*: the test pins the intended mapping, and in
  Milestone 2 you will re-express this sentinel server as a record; if that re-expression
  mis-assigns a field (which the compiler will *not* catch for the nine same-typed fields), this
  test fails.
- Build `sentinelIngestServer :: Server IngestAPI` returning `IngestAck { accepted = 1, eventId =
  "events" }` for the single endpoint and `BatchAck { accepted = 2 }` for the batch endpoint, so
  the two are distinguishable.
- Serve them. The simplest robust approach: use `Network.Wai.Handler.Warp` with
  `Warp.testWithApplication` (the same mechanism `kansoku-client/test/Spec.hs` already uses) to
  get a live ephemeral port, and issue requests with `http-client`. Alternatively use
  `hspec-wai`; do not add it if `http-client` (already a `kansoku-client` dependency) plus warp
  suffices. Assert on the decoded JSON: for `GET /metrics/users?from=2026-06-01&to=2026-06-02`,
  the response body's `metric` field must equal `"users"`; for `/metrics/organizations` it must
  equal `"organizations"`; and so on for all eleven. For ingest, `POST /v1/events` must yield
  `eventId = "events"` and `POST /v1/batch` must yield `accepted = 2`.
- Include one *negative demonstration in a comment*: state, in prose in the module, that swapping
  the sentinel `users` and `organizations` handlers makes the `users` assertion observe
  `"organizations"` and fail. The implementer should try it once, observe the red, and revert —
  capturing the failing output into Surprises & Discoveries as evidence.

Wire the new module into `kansoku-core/test/Spec.hs` (add `import Kansoku.Metrics.RoutingSpec
qualified` and call `Kansoku.Metrics.RoutingSpec.spec`). Add it to the `other-modules` list of
the `kansoku-core-test` stanza in `kansoku-core/kansoku-core.cabal`, and add the test-suite
dependencies it needs: `servant-server` (to build a `Server` value and `serve`), `warp` and `wai`
(to run it), `http-client` and `http-types` (to call it). These are all already dependencies of
the `kansoku-core` library or the `kansoku-client` test suite, so they resolve without touching
`cabal.project`.

Acceptance: `cabal test all` passes with the new spec present and green. Deliberately transposing
two same-typed sentinel handlers turns the corresponding assertion red; revert and confirm green.

Commit message form (both trailers are mandatory on every commit in this plan):

```text
test(metrics): pin each metric path to its handler before the NamedRoutes conversion

Adds Kansoku.Metrics.RoutingSpec, a runtime routing guard over the current
:<|> MetricsAPI/IngestAPI, so the upcoming conversion and module moves cannot
silently reintroduce a same-typed misroute.

ExecPlan: docs/plans/9-convert-kansoku-to-namedroutes-vertical-slices-and-multiverb.md
Intention: intention_01kxr5jt2heyvt0n768ym9dwqd
```

### Milestone 2 — Convert the route types to `NamedRoutes`

Scope: the three route modules become records; the two servers become handler records; the SDK
client becomes `genericClient`; the server assembly collapses its hand-written dispatch into one
servant application. No modules move yet, no DTOs change, no `MultiVerb` yet. At the end,
`cabal build all && cabal test all` passes and the Milestone 1 routing test is unchanged and
green.

First, `kansoku-api/src/Kansoku/Api/Metrics.hs`. Replace the `MetricsAPI` type alias with a
record. Keep the `MetricQuery` alias — it is still useful as the shared *field* type. Be clear
about what that sharing costs: the nine fields typed `MetricQuery` are **not** type-checked against
a transposition just because they are bound by name. Writing `users = metricHandler "active_users"`
into the `organizations` field and vice versa still typechecks and serves, exactly as the chain
did (Surprises & Discoveries). Binding by name means the swap must be written out explicitly rather
than fallen into by miscounting — but the Milestone 1 dispatch test, not the record and not the
compiler, is what catches it. The record is still the right shape here; it just is not a safety net
for the nine:

```haskell
data MetricsRoutes mode = MetricsRoutes
  { events          :: mode :- "metrics" :> "events"          :> MetricQuery,
    pageViews       :: mode :- "metrics" :> "page-views"      :> MetricQuery,
    sessions        :: mode :- "metrics" :> "sessions"        :> MetricQuery,
    funnel          :: mode :- "metrics" :> "funnel"
                                :> QueryParam' '[Required] "from" Day
                                :> QueryParam' '[Required] "to" Day
                                :> QueryParam' '[Required] "steps" Text
                                :> Get '[JSON] MetricResult,
    retention       :: mode :- "metrics" :> "retention"
                                :> QueryParam' '[Required] "from" Day
                                :> QueryParam' '[Required] "to" Day
                                :> QueryParam "days" Text
                                :> Get '[JSON] MetricResult,
    acquisition     :: mode :- "metrics" :> "acquisition"     :> MetricQuery,
    featureAdoption :: mode :- "metrics" :> "feature-adoption" :> MetricQuery,
    conversion      :: mode :- "metrics" :> "conversion"      :> MetricQuery,
    users           :: mode :- "metrics" :> "users"           :> MetricQuery,
    organizations   :: mode :- "metrics" :> "organizations"   :> MetricQuery,
    custom          :: mode :- "metrics" :> "custom"          :> MetricQuery
  }
  deriving stock (Generic)
```

Add imports of `Servant.API.Generic (type (:-))` and keep `GHC.Generics (Generic)` (it comes via
the prelude re-export; import it explicitly if the record deriving needs it). Export
`MetricsRoutes (..)` from the module. Field order is **not** load-bearing here, and the plan says
so on evidence rather than assumption. Every metric path segment is a static literal (`"events"`,
`"users"`, …) — none is a `Capture` — so no literal is ever offered to a sibling capture's parser;
and even where a literal and a sibling `Capture` do compete, servant's router hoists the literal
above the capture independent of declaration order (this is the "Field Order Is Not Load-Bearing"
finding in the canonical `haskell-jitsurei/api/servant-routes.md`, established by meibo's
experiment: reordering the fields of a route record changed no route). Do not merely assume it for
kansoku: the Milestone 1 dispatch test pins each path to its own handler, so once the record is in
place, reorder the record's fields once, re-run `cabal test all`, confirm every metric path still
resolves to itself, and revert. Record the result in Surprises & Discoveries and state in a comment
that the order is not load-bearing and that the routing test verifies it.

Next, `kansoku-api/src/Kansoku/Api/Ingest.hs`:

```haskell
data IngestRoutes mode = IngestRoutes
  { postEvent :: mode :- "v1" :> "events" :> ReqBody '[JSON] AnalyticsEvent
                          :> Verb 'POST 202 '[JSON] IngestAck,
    postBatch :: mode :- "v1" :> "batch"  :> ReqBody '[JSON] [AnalyticsEvent]
                          :> Verb 'POST 202 '[JSON] BatchAck
  }
  deriving stock (Generic)
```

Then the umbrella, `kansoku-api/src/Kansoku/Api.hs`:

```haskell
data KansokuAPI mode = KansokuAPI
  { ingest  :: mode :- NamedRoutes IngestRoutes,
    metrics :: mode :- NamedRoutes MetricsRoutes
  }
  deriving stock (Generic)

kansokuAPI :: Proxy (NamedRoutes KansokuAPI)
kansokuAPI = Proxy
```

This is the one legitimate use of mounting: `ingest` and `metrics` mount two records with
*distinct types* (`NamedRoutes IngestRoutes` versus `NamedRoutes MetricsRoutes`), so here — unlike
the nine same-typed metric fields inside `MetricsRoutes` — swapping the two fields genuinely is a
compile error. The safety at this level comes from the differing types, not merely from the fields
being named. Export `KansokuAPI (..)` and `kansokuAPI`.

Now the servers. In `kansoku-core/src/Kansoku/Metrics/Handler.hs`, change `metricsServer` from a
`:<|>` chain returning `Server MetricsAPI` to a record returning `MetricsRoutes (AsServerT
Handler)`:

```haskell
metricsServer :: Connection -> MetricsRoutes (AsServerT Handler)
metricsServer conn =
  MetricsRoutes
    { events          = metricHandler "events",
      pageViews       = metricHandler "page_views",
      sessions        = sessionsHandler,
      funnel          = funnelHandler,
      retention       = retentionHandler,
      acquisition     = notImplemented "acquisition",
      featureAdoption = notImplemented "feature_adoption",
      conversion      = metricHandler "conversion_rate",
      users           = metricHandler "active_users",
      organizations   = notImplemented "organizations",
      custom          = notImplemented "custom"
    }
  where
    ... -- the handler definitions are unchanged
```

`AsServerT` comes from `Servant.Server.Generic`. The handler bodies (`metricHandler`,
`sessionsHandler`, `funnelHandler`, `retentionHandler`, `notImplemented`, `effToHandler`,
`jsonError`, `queryRequest`, …) are unchanged in this milestone. Do the same for
`ingestServer` in `kansoku-core/src/Kansoku/Ingest/Handler.hs`, returning
`IngestRoutes (AsServerT Handler)` with fields `postEvent` and `postBatch`.

The two `metricsApp`/`ingestApp` WAI wrappers that call `serve (Proxy @MetricsAPI)` /
`serve (Proxy @IngestAPI)` can stay as-is for now (they will serve the records via a
`NamedRoutes` proxy), but the cleaner target is to remove them in favor of one assembly. Do the
removal now: in `kansoku-core/src/Kansoku/Server.hs`, define a single server and app:

```haskell
kansokuServer :: Pool.Pool -> QueueName -> Connection -> KansokuAPI (AsServerT Handler)
kansokuServer pool queueName conn =
  KansokuAPI
    { ingest  = ingestServer pool queueName,
      metrics = metricsServer conn
    }

kansokuApp :: Pool.Pool -> QueueName -> Connection -> Application
kansokuApp pool queueName conn req respond =
  case pathInfo req of
    ["health"]       -> healthApp req respond
    ["openapi.json"] -> respond (responseLBS status200 [(hContentType, "application/json")] (Aeson.encode openApiDoc))
    _                -> serve (Proxy @(NamedRoutes KansokuAPI)) (kansokuServer pool queueName conn) req respond
```

The hand-written `"metrics" : _` branch and the separate `metricsApp`/`ingestApp` calls are gone;
servant is now the sole router for everything except health and the OpenAPI JSON. You may delete
`metricsApp` and `ingestApp` or keep them unexported; prefer deleting to avoid dead code. Update
the `kansoku-server` executable (`kansoku-server/app/Main.hs`) if it referenced the removed names
— it calls `kansokuApp`, whose signature is unchanged, so it likely needs no change; verify.

Now the SDK client, `kansoku-client/src/Kansoku/Client.hs`. Replace the positional destructuring

```haskell
_postEvent :<|> postBatch = ServantClient.client (Proxy @IngestAPI)
```

with a generic client record:

```haskell
ingestClient :: IngestRoutes (AsClientT ClientM)
ingestClient = genericClient
```

`AsClientT` and `genericClient` come from `Servant.Client.Generic`. Then the call site that used
`postBatch events` becomes `Kansoku.Api.Ingest.postBatch ingestClient events`. Beware the
documented pitfall: a `NamedRoutes` field's type is a `(:-)` type-family application that
`OverloadedRecordDot`'s `HasField` cannot see through, so `ingestClient.postBatch` will *not*
typecheck — use qualified selector application `postBatch ingestClient`. Leave a comment saying
so; the next reader will try dot syntax. (`kansoku-client` has `OverloadedLabels` but the field
access here is ordinary selector application, which is fine.)

Rebuild after each file; GHC's errors name the next site. Search for every consumer first:

```bash
grep -rn "MetricsAPI\|IngestAPI\|KansokuAPI\|MetricsRoutes\|IngestRoutes" --include='*.hs' . | grep -v dist-newstyle
```

Expect hits in the two handlers, `Kansoku/Server.hs`, `Kansoku/OpenApi.hs` (change
`toOpenApi (Proxy @KansokuAPI)` to `toOpenApi (Proxy @(NamedRoutes KansokuAPI))`), the SDK
client, and the Milestone 1 routing test (update it to build `sentinelMetricsServer ::
MetricsRoutes (AsServerT Handler)` and `sentinelIngestServer :: IngestRoutes (AsServerT Handler)`
records, served via the `NamedRoutes` proxies — the assertions are unchanged, and their passing
is the proof the record construction is correct).

Acceptance: `cabal build all && cabal test all` passes; the routing test is green; `git diff
--stat` shows no file renames (moves are Milestone 3). Confirm `grep -rn ':<|>' --include='*.hs'
kansoku-api/src kansoku-core/src/Kansoku/Server.hs kansoku-core/src/Kansoku/OpenApi.hs` returns
nothing (the metrics/ingest/umbrella surfaces and the assembly no longer chain routes).

Commit message form:

```text
refactor(api): MetricsAPI, IngestAPI, and KansokuAPI as NamedRoutes records

Replaces the positional :<|> chains with records so handlers bind to routes by
field name; collapses the server's hand-written pathInfo dispatch into a single
served NamedRoutes KansokuAPI; derives the SDK client with genericClient.

ExecPlan: docs/plans/9-convert-kansoku-to-namedroutes-vertical-slices-and-multiverb.md
Intention: intention_01kxr5jt2heyvt0n768ym9dwqd
```

### Milestone 3 — Move the layer-first modules into vertical slices

Scope: three file moves and their import fixes. No type changes, no behavior changes. Use
`git mv` so history follows the file.

The moves:

```text
kansoku-api/src/Kansoku/Api/Ingest.hs   -> kansoku-api/src/Kansoku/Ingest/Api.hs
kansoku-api/src/Kansoku/Api/Metrics.hs  -> kansoku-api/src/Kansoku/Metrics/Api.hs
kansoku-core/src/Kansoku/Query.hs       -> kansoku-core/src/Kansoku/Metrics/Query.hs
```

After each `git mv`, update the module header (`module Kansoku.Api.Ingest` → `module
Kansoku.Ingest.Api`, `module Kansoku.Api.Metrics` → `module Kansoku.Metrics.Api`, `module
Kansoku.Query` → `module Kansoku.Metrics.Query`). Update the `exposed-modules` lists in
`kansoku-api/kansoku-api.cabal` (rename `Kansoku.Api.Ingest` → `Kansoku.Ingest.Api` and
`Kansoku.Api.Metrics` → `Kansoku.Metrics.Api`) and `kansoku-core/kansoku-core.cabal` (rename
`Kansoku.Query` → `Kansoku.Metrics.Query`). The umbrella `Kansoku/Api.hs` (module `Kansoku.Api`,
holding the thin `KansokuAPI` record) stays where it is — it is the assembly point, and its two
fields now import `Kansoku.Ingest.Api (IngestRoutes)` and `Kansoku.Metrics.Api (MetricsRoutes)`.

Find and fix every import of the moved modules:

```bash
grep -rln "Kansoku.Api.Ingest\|Kansoku.Api.Metrics\|Kansoku.Query" --include='*.hs' . | grep -v dist-newstyle
```

Expect: `Kansoku/Api.hs`, `Kansoku/OpenApi.hs`, `Kansoku/Ingest/Handler.hs`,
`Kansoku/Metrics/Handler.hs`, `Kansoku/Metrics/Definition.hs` (imports `Kansoku.Api.Metrics
(TimeGrain)`), `Kansoku/Metrics/Registry.hs` (imports `Kansoku.Api.Metrics`), the SDK client
`Kansoku/Client.hs` (imports `Kansoku.Api.Ingest`), the routing test, and the query test
`kansoku-core/test/Kansoku/QuerySpec.hs` (imports `Kansoku.Query` and `Kansoku.Api.Metrics`).
Rewrite each import to the new module name. Do not change any code beyond module names.

Note the deliberate keeps, restated so the implementer does not "tidy" them: `Kansoku/Event/*`
and `Kansoku/Prelude.hs` stay in `kansoku-api`; `Kansoku/ClickHouse.hs` and
`Kansoku/ClickHouse/EventRow.hs` stay in `kansoku-core`. The Writer and the already-vertical
Ingest/Metrics handler/producer/queue/definition/registry modules do not move.

Acceptance: `cabal build all && cabal test all` passes, including the Milestone 1 routing test
unchanged. `git status` shows renames (`R`), not delete+add. The following exact-path probe passes
(the layer-first residue is gone), and the three destination paths exist:

```bash
test ! -e kansoku-api/src/Kansoku/Api/Ingest.hs
test ! -e kansoku-api/src/Kansoku/Api/Metrics.hs
test ! -e kansoku-core/src/Kansoku/Query.hs
test -e kansoku-api/src/Kansoku/Ingest/Api.hs
test -e kansoku-api/src/Kansoku/Metrics/Api.hs
test -e kansoku-core/src/Kansoku/Metrics/Query.hs
```

Commit message form:

```text
refactor(modules): slice Ingest and Metrics APIs and the metrics query compiler

Moves Kansoku/Api/Ingest.hs -> Kansoku/Ingest/Api.hs, Kansoku/Api/Metrics.hs ->
Kansoku/Metrics/Api.hs, and Kansoku/Query.hs -> Kansoku/Metrics/Query.hs so each
concept owns its routes, DTOs, and query compiler under one module prefix.

ExecPlan: docs/plans/9-convert-kansoku-to-namedroutes-vertical-slices-and-multiverb.md
Intention: intention_01kxr5jt2heyvt0n768ym9dwqd
```

### Milestone 4 — Adopt `MultiVerb` and the shared error tail

Scope: introduce the response machinery in `kansoku-api`, make every route a `MultiVerb`, rewrite
every handler to *return* a typed result instead of throwing `ServerError`, and install
`ErrorFormatters` so pre-handler rejections carry the same envelope. This is the largest
per-handler change; it comes last because the routes are now named and sliced, so the edits are
localized.

First confirm the tooling. `MultiVerb`, `Respond`, `RespondEmpty`, and `AsUnion` live in
`Servant.API.MultiVerb`. The implementation audit on 2026-07-18 verified that Kansoku resolves
the current released Servant 0.20.3.0 cohort and that the pinned `servant-openapi-hs` 4.1.0 fork
enables its MultiVerb OpenAPI instances for Servant 0.20.3 or newer. Keep that coherent cohort;
do not add a broader `>=0.20` fallback bound or a compatibility workaround.

Create `kansoku-api/src/Kansoku/Api/Response.hs` (this is shared, cross-slice infrastructure — the
one error envelope every operation uses — so it belongs under the assembly-level `Kansoku/Api/`
prefix, not inside a single slice, analogous to how a cross-slice module is kept out of any one
concept's tree). Model it on the reference implementation in
`en/en-servant/src/En/Servant/API.hs`:

```haskell
-- | The one error-body shape. `code` is stable and machine-readable; clients branch on it,
-- never on the prose `message`. `retryable` distinguishes "fix your request" from "try again".
data ErrorEnvelopeWire = ErrorEnvelopeWire
  { code :: !Text,
    message :: !Text,
    retryable :: !Bool
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | The shared error tail, parameterized by the success status/description/payload. Two success
-- aliases share one error suffix: metrics answer 200, ingestion answers 202.
type OkResponses (desc :: Symbol) a =
  '[ Respond 200 desc a,
     Respond 400 "Malformed request" ErrorEnvelopeWire,
     Respond 404 "Not found" ErrorEnvelopeWire,
     Respond 503 "Storage unavailable" ErrorEnvelopeWire
   ]

type AcceptedResponses (desc :: Symbol) a =
  '[ Respond 202 desc a,
     Respond 400 "Malformed request" ErrorEnvelopeWire,
     Respond 404 "Not found" ErrorEnvelopeWire,
     Respond 503 "Storage unavailable" ErrorEnvelopeWire
   ]

-- | What every handler returns. One constructor per distinct status.
data KansokuResult a
  = KansokuOk a
  | KansokuBadRequest !ErrorEnvelopeWire   -- 400
  | KansokuNotFound !ErrorEnvelopeWire     -- 404
  | KansokuUnavailable !ErrorEnvelopeWire  -- 503
  deriving stock (Generic, Eq, Show)
```

Write the `AsUnion` instances by hand — one for the 200 tail, one for the 202 tail — each mapping
`KansokuResult a` onto the response list positionally, with the final uninhabited clause as the
exhaustiveness witness (if the list grows, the clause stops compiling, which is the point):

```haskell
instance
  AsUnion
    '[ Respond 200 desc a,
       Respond 400 "Malformed request" ErrorEnvelopeWire,
       Respond 404 "Not found" ErrorEnvelopeWire,
       Respond 503 "Storage unavailable" ErrorEnvelopeWire
     ]
    (KansokuResult a)
  where
  toUnion = \case
    KansokuOk value      -> Z (I value)
    KansokuBadRequest e  -> S (Z (I e))
    KansokuNotFound e    -> S (S (Z (I e)))
    KansokuUnavailable e -> S (S (S (Z (I e))))
  fromUnion = \case
    Z (I value)            -> KansokuOk value
    S (Z (I e))            -> KansokuBadRequest e
    S (S (Z (I e)))        -> KansokuNotFound e
    S (S (S (Z (I e))))    -> KansokuUnavailable e
    S (S (S (S impossible))) -> case impossible of {}
```

Write the same instance for the 202 tail (`Respond 202 desc a` in the head position). `Z`, `S`,
and `I` come from `Servant.API.MultiVerb`/`Data.SOP`; import them as the reference does.

Add a total fault-to-result helper so handler bodies map their existing error conditions to
constructors instead of building `ServerError`s:

```haskell
-- 503 is the only status for which retrying an unchanged request can succeed, so it is the
-- only one with retryable = True. A failed ClickHouse or queue dependency is a 503, not a 500:
-- a dependency of the service failed, not the service.
badRequest, notFound, unavailable :: Text -> Text -> ErrorEnvelopeWire
badRequest code msg  = ErrorEnvelopeWire code msg False
notFound code msg    = ErrorEnvelopeWire code msg False
unavailable code msg = ErrorEnvelopeWire code msg True
```

Now change the route field types. In `kansoku-api/src/Kansoku/Metrics/Api.hs`, replace each
`... :> Get '[JSON] MetricResult` with `... :> MultiVerb 'GET '[JSON] (OkResponses "…"
MetricResult) (KansokuResult MetricResult)`. The `MetricQuery` alias becomes:

```haskell
type MetricQuery =
  QueryParam' '[Required] "from" Day
    :> QueryParam' '[Required] "to" Day
    :> QueryParam "groupBy" Text
    :> QueryParam "timeGrain" TimeGrain
    :> MultiVerb 'GET '[JSON] (OkResponses "Metric result" MetricResult) (KansokuResult MetricResult)
```

and `funnel`/`retention` end in the same `MultiVerb 'GET …` tail. In
`kansoku-api/src/Kansoku/Ingest/Api.hs`, replace `Verb 'POST 202 '[JSON] IngestAck` with
`MultiVerb 'POST '[JSON] (AcceptedResponses "Event accepted" IngestAck) (KansokuResult IngestAck)`
and likewise for the batch endpoint with `BatchAck`.

The derived ingestion client now returns `ClientM (KansokuResult BatchAck)`. Update
`kansoku-client/src/Kansoku/Client.hs` so its retry loop preserves MultiVerb's two failure
channels: outer `ServantClient.ClientError` values are delivery/transport failures; inner
`KansokuBadRequest`/`KansokuNotFound`/`KansokuUnavailable` values are application responses.
Add `DeliveryRejected ErrorEnvelopeWire` beside `DeliveryFailed`, retry transport failures and
retryable `KansokuUnavailable` values up to `maxRetries`, and do not retry 400/404 envelopes. The
client tests must return real envelopes for their simulated 400/503 responses and prove both the
retryable and non-retryable paths.

Now rewrite the handlers to return `KansokuResult` instead of throwing. In
`kansoku-core/src/Kansoku/Metrics/Handler.hs`:

- Every handler's return type changes from `Handler MetricResult` to `Handler (KansokuResult
  MetricResult)`.
- `metricHandler`: `Nothing -> pure (KansokuNotFound (notFound "metric_not_found" ("no such
  metric: " <> key)))`; the success path returns `KansokuOk <$> …`.
- `funnelHandler`/`retentionHandler`: the invalid-input branch returns `pure (KansokuBadRequest
  (badRequest "invalid_funnel_steps" …))` / `"invalid_retention_days"`.
- `notImplemented`: returns `pure (KansokuNotFound (notFound "not_implemented" ("metric endpoint
  is stubbed in the MVP: " <> name)))` — this is the deliberate 501→404 change from the Decision
  Log; the machine-readable `code` is `"not_implemented"` so the endpoint is still
  distinguishable.
- `effToHandler`: instead of `throwError (jsonError err503 …)`, return `KansokuUnavailable
  (unavailable "clickhouse_unavailable" …)` on the `Left`, and wrap the success in `KansokuOk` (or
  keep `effToHandler` producing the raw value and wrap at each call site — choose one and be
  consistent). Delete the now-unused `jsonError` and the `err400/err404/err501/err503`,
  `throwError`, `ServerError` imports.

In `kansoku-core/src/Kansoku/Ingest/Handler.hs`: `postEvent`/`postBatch` return `Handler
(KansokuResult IngestAck)` / `(KansokuResult BatchAck)`; the `effToHandler` there maps the pgmq
error to `KansokuUnavailable (unavailable "queue_unavailable" …)` and the validation error list
to `KansokuBadRequest (badRequest "validation_failed" …)`, wrapping success in `KansokuOk`.

Servant needs the `AsUnion` instance in scope where the server is built; since the instances live
in `Kansoku.Api.Response` and the handlers import it, that is satisfied. Update
`kansoku-core/src/Kansoku/Server.hs` to serve with `ErrorFormatters` so malformed bodies and
unmatched routes emit `ErrorEnvelopeWire` too:

```haskell
serveWithContext (Proxy @(NamedRoutes KansokuAPI)) (envelopeFormatters :. EmptyContext) (kansokuServer pool queueName conn)
```

Define `envelopeFormatters :: ErrorFormatters` in an infrastructure module (a small
`Kansoku/Api/Response.hs` companion or inline in `Server.hs`) that renders the same JSON shape as
`ErrorEnvelopeWire` for the `bodyParserErrorFormatter` and `notFoundErrorFormatter`. Note the two
gaps servant cannot route through `ErrorFormatters` — HTTP 405 (method not allowed) and 415
(unsupported media type) return an empty body; this is acceptable and worth a one-line comment.
Because both ingest endpoints are `POST` carrying a body, there is no `DELETE`-with-body concern
here.

Update the Milestone 1 routing test's status expectations to the new reality: the four stub
endpoints (`acquisition`, `feature-adoption`, `organizations`, `custom`) now return HTTP 404 with
`code = "not_implemented"` rather than 501, and the successful sentinel responses are wrapped in
the 200/202 alternative. The *path→identity* assertions are unchanged in spirit — assert the 404
envelope's `message` (or a `metric`-naming field you include) still names the correct stub, so the
misrouting guard survives the MultiVerb change. Update `Kansoku.OpenApiSpec` if it asserts on the
absence of error responses (it will now see 400/404/503 documented per operation — that is the
improvement; adjust the assertion to expect them).

Acceptance: `cabal build all && cabal test all` passes. `grep -rn 'throwError\|ServerError'
kansoku-core/src/Kansoku/Metrics/Handler.hs kansoku-core/src/Kansoku/Ingest/Handler.hs` returns
nothing (handlers no longer throw). The generated OpenAPI document now lists 400/404/503 for each
operation — confirm by starting the server and fetching `/openapi.json` (see Validation).

Commit message form:

```text
refactor(api): make every route a MultiVerb with a shared error tail

Introduces Kansoku.Api.Response (ErrorEnvelopeWire, KansokuResult, hand-written
AsUnion with exhaustiveness witness); handlers return typed results instead of
throwing ServerError; installs ErrorFormatters so pre-handler rejections carry
the same envelope. The four stub endpoints move from 501 to 404 code=not_implemented.

ExecPlan: docs/plans/9-convert-kansoku-to-namedroutes-vertical-slices-and-multiverb.md
Intention: intention_01kxr5jt2heyvt0n768ym9dwqd
```

### Milestone 5 — Generate the OpenAPI document from the served type (the recipe)

Scope: relocate the OpenAPI generator into `kansoku-api`, derive the document from the served
`Proxy (NamedRoutes KansokuAPI)`, assign stable `operationId`s, emit the artifact from an
executable, check it in, gate it in CI, and add the four conformance tests. This milestone comes
after MultiVerb (Milestone 4) because two of its tests depend on the error responses being in the
type: "every operation declares its error responses" needs the shared 400/404/503 tail, and the
document's paths only become the *served* contract after Milestone 2's fold.

**First, confirm the toolchain — do not assume.** `cabal.project` must pin the `shinzui` forks and
not Hackage:

```bash
grep -nE 'openapi-hs|servant-openapi-hs|openapi3|servant-openapi3' cabal.project
```

Expect the two local `shinzui` fork packages `openapi-hs` and `servant-openapi-hs` (as of this
writing, `openapi-hs` 4.1.0 and `servant-openapi-hs` 4.1.0), and **no** `openapi3` /
`servant-openapi3`. If Hackage `openapi3`/`servant-openapi3` ever appear, stop: on those packages
the 400/404/503 responses Milestone 4 added are silently dropped from the document (no `HasOpenApi`
instance for `MultiVerb`), and the "every operation declares its error responses" test below is
precisely what would catch that regression. Record the confirmed pins in Surprises & Discoveries.

**Relocate the generator to `kansoku-api`.** Move `kansoku-core/src/Kansoku/OpenApi.hs` to
`kansoku-api/src/Kansoku/Api/OpenApi.hs` with `git mv`, rename the module header to
`Kansoku.Api.OpenApi`, and rename the exported value `openApiDoc` to `kansokuOpenApi` (matching the
recipe's `<service>OpenApi` convention and meibo's `meiboOpenApi`). The DTO `ToSchema` and
`ToParamSchema` orphan instances move with it — they describe DTOs that live in `kansoku-api`, so
this confines them to the package whose types they belong to, under the existing
`{-# OPTIONS_GHC -Wno-orphans #-}`. Keep `toOpenApi (Proxy @(NamedRoutes KansokuAPI))` (Milestone 2
already changed the proxy) so the document is derived from the exact proxy the server serves.

Adjust the cabals:

- `kansoku-api/kansoku-api.cabal`: add `Kansoku.Api.OpenApi` to `exposed-modules`; add
  `openapi-hs` and `servant-openapi-hs` to the library `build-depends`.
- `kansoku-core/kansoku-core.cabal`: remove `Kansoku.OpenApi` from `exposed-modules`; drop
  `openapi-hs` and `servant-openapi-hs` from the library `build-depends` (nothing in the core
  library imports `Data.OpenApi`/`Servant.OpenApi` any more).
- `kansoku-core/src/Kansoku/Server.hs`: change the import from `Kansoku.OpenApi (openApiDoc)` to
  `Kansoku.Api.OpenApi (kansokuOpenApi)`, and the `/openapi.json` branch's
  `Aeson.encode openApiDoc` to `Aeson.encode kansokuOpenApi`.

**Assign stable `operationId`s.** Client generators turn `operationId` into a method name; absent
one they invent it from the path and it churns. Add a `withOperationIds` pass that sets each from
method + path deterministically, and apply it in `kansokuOpenApi`:

```haskell
-- Deterministic operationIds: getMetricsUsers, postV1Events, etc. Set only where absent,
-- so an explicit override is never clobbered.
withOperationIds :: O.OpenApi -> O.OpenApi
withOperationIds =
  O.paths
    %~ imap
      ( \path ->
          (O.get . _Just . O.operationId %~ orSet ("get" <> camel path))
            . (O.post . _Just . O.operationId %~ orSet ("post" <> camel path))
      )
  where
    orSet v = Just . fromMaybe v
    camel = ... -- title-case each path segment and concatenate; drop captures' braces
```

kansoku has only `GET` (metrics) and `POST` (ingest), so the two lenses above suffice; add
`put`/`delete` only if a verb is ever added. State in a comment that the ids are derived, not
authored, so a path rename intentionally changes the id.

**Emit the artifact from an executable, not a test.** Add `kansoku-api/app/OpenApi.hs`, mirroring
`meibo-api/app/OpenApi.hs`:

```haskell
module Main (main) where

import Data.Aeson.Encode.Pretty (Config (..), Indent (Spaces), defConfig, encodePretty')
import Data.ByteString.Lazy qualified as BSL
import Kansoku.Api.OpenApi (kansokuOpenApi)
import System.Directory (createDirectoryIfMissing)

main :: IO ()
main = do
  createDirectoryIfMissing True "docs/api"
  BSL.writeFile "docs/api/openapi.json" (encodePretty' config kansokuOpenApi <> "\n")
  putStrLn "wrote docs/api/openapi.json"
  where
    config = defConfig {confIndent = Spaces 2, confCompare = compare, confTrailingNewline = False}
```

Sorted keys (`confCompare = compare`) plus the explicit trailing newline make the artifact
byte-stable and diffable, so a reviewer sees a contract change rather than a hash-order shuffle.
Add the executable stanza to `kansoku-api.cabal`:

```cabal
-- Writes docs/api/openapi.json. An executable, not a test, so the artifact is produced
-- deterministically rather than as a side effect of the suite.
executable kansoku-openapi
  import:         common
  main-is:        OpenApi.hs
  hs-source-dirs: app
  build-depends:
    , aeson-pretty
    , base          >=4.21 && <5
    , bytestring
    , directory
    , kansoku-api
```

**Check the artifact in and gate it in CI.** Run `cabal run kansoku-openapi` once and commit the
resulting `docs/api/openapi.json`. Add two `justfile` recipes — one to regenerate, one to verify:

```make
# Regenerate the checked-in OpenAPI document from the served route types.
openapi:
    cabal run kansoku-openapi

# Fail if the checked-in document is stale (CI runs this).
openapi-check:
    cabal run kansoku-openapi
    git diff --exit-code docs/api/openapi.json
```

kansoku has no CI workflow yet (`.github/workflows/` is absent). Add `just openapi-check` to
whatever CI is introduced; until then it is a pre-commit/local gate. A non-empty diff means someone
changed the API and did not regenerate — exactly the drift the rule exists to catch.

**Add the conformance tests.** Rewrite `kansoku-core/test/Kansoku/OpenApiSpec.hs` (it is the
natural home: the served==documented test needs `Kansoku.Server`, which lives in `kansoku-core`,
and the suite already gained warp/wai/http-client/http-types in Milestone 1). Change its import
from `Kansoku.OpenApi (openApiDoc)` to `Kansoku.Api.OpenApi (kansokuOpenApi)`. Keep the two useful
existing probes (reports OpenAPI 3.1; `EventSource`/`TimeGrain` render as lowercase wire tags) and
add these, all **pure of ClickHouse** — no live database anywhere in this spec:

1. **Exact path set.** Assert `sort (documentedPaths kansokuOpenApi) == expectedServedPaths`, where
   `expectedServedPaths` is the thirteen-path literal (`/v1/events`, `/v1/batch`, and the eleven
   `/metrics/*`). Adding a record field without updating the literal, or vice versa, fails.

2. **Every operation declares its error responses.** For every `(path, method, operation)` triple,
   assert its `responses` keys are exactly one success status (`200` for metrics, `202` for
   ingest) plus the shared error tail `["400", "404", "503"]`. This is the test that gives the
   `MultiVerb` convention its teeth and the test that would catch a silent switch to Hackage
   `servant-openapi3` (on which every error response vanishes at once).

3. **Every DTO's `ToJSON` validates against its `ToSchema`.** For each wire DTO —
   `AnalyticsEvent`, `IngestAck`, `BatchAck`, `MetricPoint`, `MetricResult`, `TimeGrain`, the id
   newtypes, and the Milestone-4 `ErrorEnvelopeWire` — build a sample value and assert
   `validateToJSON sample == []`. A field renamed on one side only is otherwise invisible until a
   client's generated code fails to decode.

4. **The served path set equals the documented path set** — the acceptance unique to this service,
   the regression guard that proves the fold from Milestone 2 happened and stays. Three
   assertions, all pure:
   - `documentedPaths kansokuOpenApi == expectedServedPaths` (the document side; shared with test 1).
   - The **servant-routed** side: stand up the `KansokuAPI` record over the Milestone-1 **sentinel**
     servers — assemble a `sentinelKansokuServer :: KansokuAPI (AsServerT Handler)` from the
     routing test's `sentinelMetricsServer`/`sentinelIngestServer` and serve it via
     `serve (Proxy @(NamedRoutes KansokuAPI)) sentinelKansokuServer` under
     `Warp.testWithApplication` — sentinels touch no ClickHouse — and assert every path in
     `expectedServedPaths` is *routed* (a request reaches a sentinel, i.e. does not get servant's
     routing 404) while a path outside it (e.g. `/v1/definitely-missing`) *does* 404. This ties the
     documented set to what servant actually routes, both over the one `KansokuAPI` proxy.
   - The **WAI allowlist**: `/health`, `/ready`, and `/openapi.json` are served but deliberately
     *not* in the document (see the Decision Log). Assert they are absent from `documentedPaths`,
     and — standing up the WAI wrapper over the sentinel servant app and an always-ready probe
     (see below) — that `/health` returns `200` `"OK"`, `/ready` returns `200` with
     `status = "ready"`, and `/openapi.json` returns `200` with the document, so the non-servant
     surface is pinned to exactly those three. A *new* hand-rolled route added to `kansokuApp` is then either
     documented (it went through the record) or fails this assertion.

   To exercise the WAI wrapper without a live `Connection`, factor `kansokuApp` so its wrapper takes
   the inner servant `Application` as an argument:

   ```haskell
   -- The WAI wrapper: operational/meta routes at the WAI level, everything else delegated to
   -- servant. Taking the probe and inner app as parameters keeps this testable without databases.
   waiWrapper :: ReadyProbe -> Application -> Application
   waiWrapper probe inner req respond =
     case pathInfo req of
       ["health"]       -> healthApp req respond
       ["ready"]        -> readyApp probe req respond
       ["openapi.json"] -> respond (responseLBS status200 [(hContentType, "application/json")] (Aeson.encode kansokuOpenApi))
       _                -> inner req respond

   kansokuApp :: ReadyProbe -> Pool.Pool -> QueueName -> QueryPool -> Application
   kansokuApp probe pool queueName queryPool =
     waiWrapper probe (serve kansokuAPI (kansokuServer pool queueName queryPool))
   ```

   The test builds `waiWrapper alwaysReadyProbe (serve kansokuAPI sentinelKansokuServer)`.

Wire the (unchanged-named) `Kansoku.OpenApiSpec` into `test/Spec.hs` as before. The four stub
endpoints' Milestone-4 change from HTTP 501 to HTTP 404 `code=not_implemented` needs **no** special
handling here: `404` is already in the shared error tail, so the document lists it for every metric
operation regardless of whether the handler is stubbed, and test 2 asserts exactly that tail. No
operation ever typed a `501`, so none appears in the document — the conformance test and the
document agree by construction.

Acceptance: `cabal build all && cabal test all` passes; `cabal run kansoku-openapi` then
`git diff --exit-code docs/api/openapi.json` is clean (artifact is checked in and up to date); the
four conformance tests are green; `grep -rn 'Kansoku.OpenApi\b' --include='*.hs' . | grep -v
dist-newstyle` finds only the relocated `Kansoku.Api.OpenApi`.

Commit message form:

```text
feat(api): generate the OpenAPI document from the served NamedRoutes type

Relocates the generator into kansoku-api as Kansoku.Api.OpenApi (derived from the
served Proxy (NamedRoutes KansokuAPI)); adds stable operationIds and a kansoku-openapi
executable writing the checked-in docs/api/openapi.json; adds conformance tests for
the exact path set, per-operation error responses, DTO ToJSON/ToSchema agreement, and
the served-path-set == documented-path-set guard.

ExecPlan: docs/plans/9-convert-kansoku-to-namedroutes-vertical-slices-and-multiverb.md
Intention: intention_01kxr5jt2heyvt0n768ym9dwqd
```

### Milestone 6 — Amend the plans of record

Several checked-in ExecPlans specify, in their code blocks, the `:<|>` shapes this plan removes.
Leaving them asserting a shape the code no longer has would mislead the next reader. Per the
ExecPlan revision protocol, append a dated revision note to the bottom of each and update its
now-stale code blocks in place (do not rewrite the plan's history or its Progress ticks; just fix
the shapes and add the note naming this plan).

The affected plans and what to fix in each:

- `docs/plans/4-ingestion-api-with-pgmq-queue-and-batched-clickhouse-writer.md` — its Milestone 1
  code block declares `type IngestAPI = … :<|> …` and `server = postEvent :<|> postBatch`. Update
  to the `IngestRoutes` record and record-server forms.
- `docs/plans/6-semantic-metrics-layer-and-typed-query-api.md` — the primary one. It declares
  `MetricsAPI` as the eleven-endpoint `:<|>` chain, `MetricQuery`, `type KansokuAPI = IngestAPI
  :<|> MetricsAPI`, and mounts `MetricsAPI` "by combining it with `:<|>`". Update to the
  `MetricsRoutes` record, the `KansokuAPI` record, and the single served application. Note the
  `MultiVerb` response tail now wraps each verb.
- `docs/plans/7-haskell-server-sdk.md` — repeatedly shows `postEvent :<|> postBatch = client
  (Proxy @IngestAPI)`. Update to `ingestClient = genericClient` and qualified selector calls.
- `docs/plans/8-openapi-schema-generation-and-api-documentation.md` — shows `type KansokuAPI =
  IngestAPI :<|> MetricsAPI` and `Proxy @KansokuAPI`. Update to the record and `Proxy
  @(NamedRoutes KansokuAPI)`. Also update it to reflect Milestone 5's changes: the generator now
  lives in `kansoku-api` as `Kansoku.Api.OpenApi` (value `kansokuOpenApi`), not in `kansoku-core`
  as `Kansoku.OpenApi`; the document is emitted to a checked-in `docs/api/openapi.json` by the
  `kansoku-openapi` executable and gated by `git diff --exit-code`; and the document is verified by
  the four conformance tests (exact path set, per-operation error responses, DTO
  `ToJSON`/`ToSchema` agreement, served==documented). If plan 8 asserted that error responses are
  absent from the document, invert it — they are now present, per operation, which is the point.

Acceptance: none of these four plans contains a `:<|>` in a route-type, handler-assembly, or
client-derivation code block, and each carries a dated revision note naming plan 9.

Commit message form:

```text
docs(plans): update plans 4/6/7/8 to the NamedRoutes + MultiVerb shapes

ExecPlan: docs/plans/9-convert-kansoku-to-namedroutes-vertical-slices-and-multiverb.md
Intention: intention_01kxr5jt2heyvt0n768ym9dwqd
```


## Concrete Steps

Work from the repository root inside the nix dev shell.

```bash
cd /Users/shinzui/Keikaku/bokuno/kansoku-project/kansoku
cabal build all    # baseline: must succeed before you start
cabal test all     # baseline: must pass before you start
```

Milestone 1 (routing guard first):

```bash
# Write kansoku-core/test/Kansoku/Metrics/RoutingSpec.hs and register it in
# kansoku-core/test/Spec.hs and the kansoku-core.cabal test stanza.
cabal test all
git add -A && git commit    # message form in Milestone 1
```

Milestone 2 (NamedRoutes). Find consumers, then edit types then servers then client:

```bash
grep -rn "MetricsAPI\|IngestAPI\|KansokuAPI" --include='*.hs' . | grep -v dist-newstyle
# Edit kansoku-api/src/Kansoku/Api/Metrics.hs, .../Ingest.hs, .../Api.hs;
# then kansoku-core .../Metrics/Handler.hs, .../Ingest/Handler.hs, Server.hs, OpenApi.hs;
# then kansoku-client/src/Kansoku/Client.hs; then the routing test.
cabal build all && cabal test all
git add -A && git commit    # message form in Milestone 2
```

Milestone 3 (moves) uses `git mv` so history follows:

```bash
git mv kansoku-api/src/Kansoku/Api/Ingest.hs  kansoku-api/src/Kansoku/Ingest/Api.hs
git mv kansoku-api/src/Kansoku/Api/Metrics.hs kansoku-api/src/Kansoku/Metrics/Api.hs
git mv kansoku-core/src/Kansoku/Query.hs      kansoku-core/src/Kansoku/Metrics/Query.hs
# Fix module headers, both .cabal exposed-modules lists, and all imports.
cabal build all && cabal test all
git add -A && git commit    # message form in Milestone 3
```

Milestone 4 (MultiVerb):

```bash
# Add kansoku-api/src/Kansoku/Api/Response.hs (+ exposed-modules entry).
# Rewrite the two Api modules' verbs and the two handlers' bodies; install ErrorFormatters.
cabal build all && cabal test all
git add -A && git commit    # message form in Milestone 4
```

Milestone 5 (OpenAPI recipe):

```bash
grep -nE 'openapi-hs|servant-openapi-hs|openapi3|servant-openapi3' cabal.project  # confirm forks
git mv kansoku-core/src/Kansoku/OpenApi.hs kansoku-api/src/Kansoku/Api/OpenApi.hs
# Rename module + value (kansokuOpenApi), add operationIds; fix both .cabal files and Server.hs.
# Add kansoku-api/app/OpenApi.hs + the kansoku-openapi executable stanza.
# Rewrite kansoku-core/test/Kansoku/OpenApiSpec.hs with the four conformance tests.
cabal build all && cabal test all
cabal run kansoku-openapi                      # writes docs/api/openapi.json
git add docs/api/openapi.json                  # check the artifact in
git diff --exit-code docs/api/openapi.json     # must be clean
git add -A && git commit    # message form in Milestone 5
```

Milestone 6 (docs):

```bash
# Amend docs/plans/4, 6, 7, 8; add revision notes.
git add -A && git commit    # message form in Milestone 6
```

Commit each milestone separately. Never combine a route-type change with a file move or a
status-code change in one commit; a reviewer cannot read that diff.


## Validation and Acceptance

Beyond `cabal build all && cabal test all` at every milestone, the decisive acceptance is
behavioral: prove the running server answers each of the nine `MetricQuery` endpoints with *its
own* metric identity, never a neighbour's. This is what proves the misordering hazard from the
Purpose is actually closed.

Stand up the dependencies. ClickHouse must be reachable or the metric handlers answer HTTP 503:

```bash
just up            # starts postgres + clickhouse via process-compose (leave running)
just ch-migrate    # applies db/clickhouse/migrations/*.sql (creates analytics.* tables + rollups)
just ch-fixtures-ep6   # loads EP-6 metric fixtures (events on 2026-06-01..2026-06-03)
```

In another shell, run the server:

```bash
just run           # cabal run kansoku-server; listens on :8080 by default (KANSOKU_SERVER_PORT)
```

Now curl each of the nine shared-type endpoints and assert the `metric` field in the response
names the metric that endpoint is supposed to answer. The five *implemented* ones return HTTP 200
with a `metric` field set from the metric definition; the four *stubbed* ones return HTTP 404 (or,
before Milestone 4, HTTP 501) whose body names the stub. The exact expected identities:

```bash
BASE='http://localhost:8080'
R='from=2026-06-01&to=2026-06-04'

curl -s "$BASE/metrics/events?$R"          | grep -o '"metric":"[^"]*"'   # -> "metric":"events"
curl -s "$BASE/metrics/page-views?$R"      | grep -o '"metric":"[^"]*"'   # -> "metric":"page_views"
curl -s "$BASE/metrics/sessions?$R"        | grep -o '"metric":"[^"]*"'   # -> "metric":"sessions"
curl -s "$BASE/metrics/conversion?$R"      | grep -o '"metric":"[^"]*"'   # -> "metric":"conversion_rate"
curl -s "$BASE/metrics/users?$R"           | grep -o '"metric":"[^"]*"'   # -> "metric":"active_users"
```

The critical pair — the one named in the Purpose — is `users` versus `organizations`. They share
the `MetricQuery` type and were interchangeable in the old chain:

```bash
curl -s -o /dev/null -w '%{http_code}\n' "$BASE/metrics/users?$R"          # -> 200
curl -s "$BASE/metrics/users?$R" | grep -o '"metric":"active_users"'       # must match

curl -s -o /dev/null -w '%{http_code}\n' "$BASE/metrics/organizations?$R"  # -> 404 (was 501)
curl -s "$BASE/metrics/organizations?$R" | grep -o 'not_implemented'       # must match
```

If `/metrics/users` ever returns `"metric":"organizations"` or a 404 stub body, or
`/metrics/organizations` returns `"metric":"active_users"`, the handlers are transposed — the
exact bug this plan exists to guard against. Do not expect the `NamedRoutes` record to have made
this impossible: because `users` and `organizations` share the `MetricQuery` type, transposing them
in the server record is **not** a compile error — it typechecks, builds, and serves, exactly as the
chain did (Surprises & Discoveries). This transcript, together with the Milestone 1 routing test,
is the dispatch guard, and it is the *only* thing that catches the swap. Run it in earnest, not as
a formality: for the nine same-typed endpoints it is doing work the compiler cannot.

Do the same for the remaining stubs, each naming itself:

```bash
curl -s "$BASE/metrics/acquisition?$R"      | grep -o 'acquisition'
curl -s "$BASE/metrics/feature-adoption?$R" | grep -o 'feature_adoption'
curl -s "$BASE/metrics/custom?$R"           | grep -o 'custom'
```

Note on data: the EP-6 fixtures make `points` non-empty for the implemented metrics, but the
misordering proof does *not* depend on the data — the discriminating `metric` field is set by the
handler from the metric definition, independent of the ClickHouse result, so even an empty but
reachable ClickHouse yields the correct `metric` per endpoint. The fixtures are loaded so the
transcript looks realistic and so the two distinct-typed endpoints can also be exercised:

```bash
curl -s "$BASE/metrics/funnel?from=2026-06-01&to=2026-06-04&steps=signup_started,signup_completed" \
  | grep -o '"metric":"funnel"'
curl -s "$BASE/metrics/retention?from=2026-06-01&to=2026-06-04&days=1,7" \
  | grep -o '"metric":"retention"'
```

Exercise ingestion to prove the second sub-record serves and that its two distinct endpoints are
not swapped:

```bash
curl -s -X POST "$BASE/v1/events" -H 'content-type: application/json' \
  -d '{"eventId":"evt_val_1","eventName":"page_view","source":"web","occurredAt":"2026-06-01T09:00:00Z","receivedAt":"2026-06-01T09:00:00Z"}'
# -> {"accepted":1,"eventId":"evt_val_1"}   (postEvent, HTTP 202)

curl -s -X POST "$BASE/v1/batch" -H 'content-type: application/json' \
  -d '[{"eventId":"evt_val_2","eventName":"page_view","source":"web","occurredAt":"2026-06-01T09:00:00Z","receivedAt":"2026-06-01T09:00:00Z"}]'
# -> {"accepted":1}   (postBatch, HTTP 202)
```

After Milestone 4, confirm the error contract is now in the type by inspecting the generated
OpenAPI document, which is produced in-process from the same `KansokuAPI` record:

```bash
curl -s "$BASE/openapi.json" | grep -o '"503"' | head -1   # -> "503"  (status now documented)
```

After Milestone 5, the document is also a checked-in artifact and is proven equal to the served
surface without any running server or ClickHouse:

```bash
cabal run kansoku-openapi                     # regenerate docs/api/openapi.json
git diff --exit-code docs/api/openapi.json    # -> clean; a diff means the API changed un-regenerated
cabal test all                                # the four conformance tests run pure (no ClickHouse)
```

The conformance suite asserts: the documented path set equals the thirteen-path served literal;
every operation declares the shared 400/404/503 tail plus one success status; every DTO's `ToJSON`
validates against its `ToSchema`; and — the guard unique to this service — the servant-routed path
set (probed over sentinel handlers, no ClickHouse) equals the documented path set, with `/health`
`/ready`, and `/openapi.json` pinned as the only WAI-level escapes. That last test is what makes the
served-vs-documented drift impossible to reintroduce silently.

A malformed body should now come back as the shared envelope, not a bare servant string:

```bash
curl -s -X POST "$BASE/v1/events" -H 'content-type: application/json' -d '{ not json' \
  | grep -o '"code":"[^"]*"'   # -> a code field from ErrorEnvelopeWire, via ErrorFormatters
```

Finally, the structural acceptance:

```bash
grep -rn ':<|>' --include='*.hs' kansoku-api/src kansoku-core/src | grep -v dist-newstyle
# Expected: no output. No route surface enumerates routes with :<|> any more.

find kansoku-api/src kansoku-core/src -name '*.hs' | grep -iE 'Api/(Ingest|Metrics)|/Query\.hs$'
# Expected: no output. The layer-first residue is gone.

test -f kansoku-api/src/Kansoku/Api/OpenApi.hs && ! test -f kansoku-core/src/Kansoku/OpenApi.hs && echo ok
# Expected: ok. The generator lives in kansoku-api, deriving from the served type.

test -f docs/api/openapi.json && echo ok
# Expected: ok. The document is a checked-in artifact.
```


## Idempotence and Recovery

Milestones 1, 2, 4, and 6 are ordinary edits: re-running the build is safe and repeated edits
converge. If a milestone's build breaks halfway, the working tree is recoverable with `git
checkout -- .` (discard uncommitted changes) or `git reset --hard HEAD` (return to the last
committed milestone). Commit after each milestone so there is always a clean point to return to.

Milestone 5 is a `git mv` (the generator) plus edits plus a regenerated artifact. The move is
idempotent in the same way as Milestone 3's (a repeat fails loudly rather than corrupting).
`cabal run kansoku-openapi` is deterministic — sorted keys and a fixed trailing newline mean
re-running it produces a byte-identical `docs/api/openapi.json`, so regeneration converges and the
`git diff --exit-code` gate is stable. If the artifact and the types ever disagree, the fix is
always to regenerate, never to hand-edit the JSON: it is a build product, and a hand edit is lost
at the next `cabal run kansoku-openapi`.

Milestone 3 is file moves. `git mv` is idempotent in the useful sense: a repeated run fails
loudly ("bad source, destination already exists") rather than corrupting anything. If a move goes
wrong mid-way, `git reset --hard HEAD` returns to the pre-move commit.

No database migration or destructive data operation is part of this plan. `just ch-migrate` and
the fixture loaders are additive and safe to re-run: the migrations use `CREATE … IF NOT EXISTS`
and the fixtures insert into a `ReplacingMergeTree` (`analytics.events_raw`) whose duplicate rows
collapse on merge, so re-loading them does not accumulate. The Postgres `kansoku` database is
created idempotently by `just create-database`.

The riskiest step is the Milestone 2 server rewrite, because a transposed field in
`metricsServer`'s record reproduces exactly the bug this plan guards against — the record makes it
a type error only where field types *differ*, and the nine `MetricQuery` fields share a type, so a
`users`/`organizations` swap in the record construction would still typecheck (this is the
falsified-premise finding in Surprises & Discoveries, confirmed by meibo's experiment). The
Milestone 1 routing test is precisely the guard for this: it asserts each path reaches the field
that names it, so a swapped record construction turns it red. This is why the test is written first
and must stay green through Milestones 2, 3, and 4 — it is a hard prerequisite of the conversion,
not an optional check around it.


## Interfaces and Dependencies

One already-resolved transitive package becomes a direct library dependency: `kansoku-api`
declares `sop-core`, because the hand-written `AsUnion` instances import `Data.SOP` directly.
The other required packages — `servant`, `servant-server`, and `servant-client` — were already
present:

- `servant` supplies `NamedRoutes`, `Servant.API.Generic (type (:-))`, and
  `Servant.API.MultiVerb (MultiVerb, Respond, RespondEmpty, AsUnion)`.
- `sop-core` supplies `Data.SOP (I, NS)` and therefore the `I`, `Z`, and `S` constructors used by
  the exhaustive union mapping. The resolved package remains 0.5.0.2; no new bound or pin is added.
- `servant-server` supplies `Servant.Server.Generic (AsServerT)`, `serve`, `serveWithContext`,
  and `ErrorFormatters`.
- `servant-client` supplies `Servant.Client.Generic (AsClientT, genericClient)`.

The `kansoku-core-test` suite gains, in Milestone 1, test-only dependencies already present
elsewhere in the project: `servant-server`, `warp`, `wai`, `http-client`, `http-types`. No
Servant bound change is needed: the resolved 0.20.3.0 release provides MultiVerb and matches
the pinned OpenAPI fork's compatibility guard.

Milestone 5 moves the OpenAPI dependency, and adds one build-time dependency:

- `kansoku-api` library gains `openapi-hs` and `servant-openapi-hs` (relocated from
  `kansoku-core`) — the OpenAPI-3.1 `shinzui` forks, already pinned in `cabal.project`; the
  generator imports `Data.OpenApi` and `Servant.OpenApi` from them.
- `kansoku-core` library **drops** `openapi-hs` and `servant-openapi-hs`; after the relocation
  nothing in the core library imports them (`Server.hs` now imports the finished
  `kansokuOpenApi :: OpenApi` value from `kansoku-api`).
- The new `kansoku-openapi` executable (in `kansoku-api`) depends on `aeson-pretty` and
  `directory` in addition to `base`, `bytestring`, and `kansoku-api`. `aeson-pretty` is the only
  genuinely new dependency in the project; it is already in the package set (meibo uses it for the
  identical executable).
- `kansoku-core-test` keeps `openapi-hs` (its conformance tests call `validateToJSON` and read the
  document) and reuses the Milestone-1 warp/wai/http-client stack for the served==documented probe.

Because `kansoku-client` depends on `kansoku-api`, the relocation adds `openapi-hs` /
`servant-openapi-hs` to the client's transitive closure. This is accepted (see the Decision Log):
the OpenAPI forks are a pure, light library, not the heavy `kansoku-core` runtime the package
split exists to keep out of the client.

At the end of Milestone 2 these must exist:

```haskell
-- kansoku-api/src/Kansoku/Api/Metrics.hs
data MetricsRoutes mode

-- kansoku-api/src/Kansoku/Api/Ingest.hs
data IngestRoutes mode

-- kansoku-api/src/Kansoku/Api.hs
data KansokuAPI mode
kansokuAPI :: Proxy (NamedRoutes KansokuAPI)

-- kansoku-core/src/Kansoku/Metrics/Handler.hs
metricsServer :: Connection -> MetricsRoutes (AsServerT Handler)

-- kansoku-core/src/Kansoku/Ingest/Handler.hs
ingestServer :: Pool.Pool -> QueueName -> IngestRoutes (AsServerT Handler)

-- kansoku-core/src/Kansoku/Server.hs
kansokuServer :: Pool.Pool -> QueueName -> Connection -> KansokuAPI (AsServerT Handler)

-- kansoku-client/src/Kansoku/Client.hs
ingestClient :: IngestRoutes (AsClientT ClientM)
```

At the end of Milestone 3, `Kansoku.Api.Ingest`, `Kansoku.Api.Metrics`, and `Kansoku.Query` no
longer exist; `Kansoku.Ingest.Api`, `Kansoku.Metrics.Api`, and `Kansoku.Metrics.Query` exist in
their place, with `Kansoku.Api` (the umbrella `KansokuAPI` record) unchanged.

At the end of Milestone 4 these must exist:

```haskell
-- kansoku-api/src/Kansoku/Api/Response.hs
data ErrorEnvelopeWire
data KansokuResult a
type OkResponses (desc :: Symbol) a
type AcceptedResponses (desc :: Symbol) a
-- with hand-written AsUnion instances for both the 200 and 202 tails.
```

and every field of `MetricsRoutes` and `IngestRoutes` ends in a `MultiVerb`, and no handler in
`Kansoku.Metrics.Handler` or `Kansoku.Ingest.Handler` calls `throwError` or constructs a
`ServerError`.

At the end of Milestone 5 these must exist:

```haskell
-- kansoku-api/src/Kansoku/Api/OpenApi.hs (relocated from kansoku-core/src/Kansoku/OpenApi.hs)
kansokuOpenApi :: OpenApi   -- toOpenApi (Proxy @(NamedRoutes KansokuAPI)), with operationIds

-- kansoku-api/app/OpenApi.hs
main :: IO ()               -- the kansoku-openapi executable; writes docs/api/openapi.json

-- kansoku-core/src/Kansoku/Server.hs
waiWrapper :: ReadyProbe -> Application -> Application -- /health + /ready + /openapi.json, else inner
```

and `Kansoku.OpenApi` (in `kansoku-core`) no longer exists; `docs/api/openapi.json` is checked in
and byte-identical to `cabal run kansoku-openapi`'s output; and `kansoku-core/test/Kansoku/OpenApiSpec.hs`
holds the four conformance tests, all pure of ClickHouse.


## Revision Notes

- 2026-07-09 — Added the OpenAPI-from-types recipe as a first-class concern after a served-vs-
  documented audit found the plan's deepest defect was not only the nine interchangeable metrics
  handlers but that kansoku *publishes* an OpenAPI document (`toOpenApi (Proxy @KansokuAPI)`)
  describing a servant type the server never serves — it routes by hand on WAI `pathInfo` — so the
  published contract and the answered routes were joined by nothing but convention (the recipe's
  named anti-pattern, "Don't Generate From a Different Type Than You Serve"). Milestone 2's fold
  into one served `NamedRoutes KansokuAPI` is what makes the document the real contract; this
  revision makes that guarantee testable. Changes: rewrote Purpose to name both defects and the
  single fold that closes them; added Decision Log entries (headline defect; recipe adoption +
  generator relocation to `kansoku-api`; `/health` and `/openapi.json` stay outside the servant
  type; forks already pinned, no change); recorded the bug-hunt result (`/health`, `/openapi.json`
  served-but-undocumented today; none documented-but-unserved; the alignment is unenforced) and the
  forks-pinned finding in Surprises & Discoveries; added rule 4 and a `cabal.project` forks note to
  Context; inserted **Milestone 5** (relocate generator to `Kansoku.Api.OpenApi`, stable
  `operationId`s, a `kansoku-openapi` executable writing a checked-in `docs/api/openapi.json` with
  aeson-pretty/sorted-keys/trailing-newline, a `git diff --exit-code` CI gate, and four ClickHouse-
  free conformance tests: exact path set, per-operation error responses, DTO `ToJSON`/`ToSchema`
  agreement, and the served==documented guard); renumbered the former Milestone 5 (amend plans of
  record) to **Milestone 6** and extended its plan-8 amendment to cover the new executable and
  tests; and updated Concrete Steps, Validation, Idempotence, and Interfaces accordingly.
  Verified against the codebase: kansoku already pins the `shinzui` forks (`openapi-hs` 4.1.0,
  `servant-openapi-hs` 4.1.0), not Hackage.

- 2026-07-10 — Corrected a load-bearing false claim after it was falsified by experiment. The plan
  had asserted, in many places, that converting the positional `:<|>` chain to a `NamedRoutes`
  record makes a transposition of two same-typed handlers a compile/field-name error that GHC would
  catch. It does not. The sibling meibo project (`docs/plans/7-adopt-namedroutes-and-vertical-slices.md`,
  Surprises & Discoveries §§1–3) converted to `NamedRoutes`, swapped its two genuinely same-typed
  handlers (`byHandle`/`byCredential`) in the server record, and `cabal build` succeeded; it also
  confirmed servant hoists literal path segments above sibling captures regardless of record field
  order, so field order is not load-bearing. The record removes only the *positional* failure mode
  (miscounting; a mid-list insertion shifting later handlers), not the same-typed one. Why this
  matters most for kansoku: nine of its eleven metric endpoints share the `MetricQuery` type, so
  neither the chain nor the record is type-checked against a transposition across those nine — which
  makes the runtime dispatch test the *only* guard and, therefore, load-bearing rather than a
  nicety. What changed, per the revision protocol, across all affected sections: **Purpose** was
  rewritten to (a) stop claiming the record makes the swap a compile error, (b) restate the
  misordering argument honestly and keep it strong (nothing static can guard nine same-typed
  handlers, so the dispatch test is the guard), and (c) reorder the two defects so the
  served-vs-documented drift — a real hazard nothing catches — leads as the strongest single
  justification. **Progress** Milestone 1 was relabelled the centrepiece and a hard prerequisite.
  **Surprises & Discoveries** gained two entries (the falsification, citing meibo's experiment as
  evidence; and the field-order corollary, with an instruction to *verify* order-independence in
  kansoku rather than assume it). **Decision Log** gained an entry making the dispatch test a hard
  prerequisite of the conversion with total coverage over the nine, and the served-vs-documented
  "headline defect" entry was reordered to lead. **Plan of Work** Milestones 1 and 2 were corrected
  (the "record does not make same-typed fields dangerous" line; the sentinel test must cover all
  nine; the field-order comment now says verify, not assume; the umbrella's safety attributed to
  distinct types, not naming). **Concrete Steps** were unaffected (they already order Milestone 1
  first). **Validation** was corrected to stop calling the transcript "impossible to reproduce"
  because the swap compiles, framing it and the routing test as the dispatch guard. **Idempotence**
  (already correct on this point) was aligned and cross-referenced. **Interfaces** were unaffected.
  The canonical `haskell-jitsurei/api/servant-routes.md` was corrected in the same effort ("Positional
  chains silently misroute", "Same-Typed Routes Need a Dispatch Test", "Field Order Is Not
  Load-Bearing").

- 2026-07-18 — Began implementation under MasterPlan 2. Aligned the child frontmatter and
  commit-message examples with the parent intention, and corrected the dependency guidance after
  Mori source inspection plus Hackage/upstream-tag verification showed that Kansoku already
  resolves the current Servant 0.20.3.0 and OpenAPI-fork 4.1.0 cohort. No dependency bound or
  compatibility workaround is required.

- 2026-07-18, Milestone 2 — Reconciled this plan with completed EP-10 and EP-11. The server
  assembly examples and Milestone-5 conformance design now preserve `/ready`, use `QueryPool`, and
  treat `/health`, `/ready`, and `/openapi.json` as the exact WAI-level operational/meta allowlist.
  Also recorded the direct `servant-client-core` dependency required by `genericClient` and the
  successful Kansoku field-order experiment.

- 2026-07-18, Milestone 3 — Completed the three history-preserving vertical-slice moves and updated
  every package export and import. Corrected the structural acceptance probe after execution showed
  that its broad `/Query\.hs$` alternative also matched the intended destination; the plan now checks
  exact obsolete and destination paths separately.

- 2026-07-18, Milestone 4 — Added the shared typed response union, converted all thirteen routes
  and their generated client to MultiVerb, replaced handler-thrown statuses with result values,
  and installed/tested the pre-handler error envelope formatters. Expanded the execution detail
  after Mori/source inspection showed that `Data.SOP` requires an explicit `sop-core` dependency
  and that the SDK must preserve MultiVerb's outer transport versus inner application-result
  channels. The client now tests retryable 503 and non-retryable 400 behavior explicitly.
