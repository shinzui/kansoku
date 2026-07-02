---
id: 8
slug: openapi-schema-generation-and-api-documentation
title: "OpenAPI schema generation and API documentation"
kind: exec-plan
created_at: 2026-07-01T16:34:23Z
intention: "intention_01kwf425fxenc904ear54cr2n7"
master_plan: "docs/masterplans/1-kansoku-analytics-service-mvp.md"
---

# OpenAPI schema generation and API documentation

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Kansoku (観測, "observation") is a self-hostable analytics service. It already accepts
analytics events over HTTP (`POST /v1/events` for a single event and `POST /v1/batch` for an
array) and answers typed metric queries over HTTP (`GET /metrics/*`). Those endpoints are
declared in Haskell as *servant API types* — a way of describing an HTTP API as a Haskell
type so the compiler can check requests, responses, and JSON bodies. Today the only complete,
authoritative description of that HTTP contract is the Haskell source. Anyone who is not
reading the Haskell — a person writing external documentation, a teammate building a
TypeScript client, an API-testing tool — has nothing machine-readable to work from.

After this change, the running `kansoku-server` binary serves a single file at
`GET /openapi.json`. That file is an **OpenAPI document**: a standardized JSON description of
an HTTP API (which paths exist, which HTTP methods they accept, what JSON the request and
response bodies contain). "OpenAPI 3.1" is the version of that standard we emit. The document
is generated directly from the same servant API types the server actually runs, so it can
never drift from the real endpoints. Concretely, after this plan a developer can run the
server and execute:

```bash
curl -s http://localhost:8080/openapi.json | jq '.openapi, (.paths | keys)'
```

and see the version string `"3.1.0"` followed by the list of paths including `/v1/events`,
`/v1/batch`, and the `/metrics/*` endpoints, with the `AnalyticsEvent` request body described
under `components.schemas`. That JSON is the input that a later, out-of-scope effort will feed
to `openapi-typescript` to generate the deferred `kansoku-js` / TypeScript SDK. Delivering the
JSON is the required outcome of this plan; a bundled human-friendly documentation web page
(Swagger UI / Redoc) is an explicitly optional final milestone.

This work is EP-8, in Phase 4 (Client surface) of the MasterPlan
`docs/masterplans/1-kansoku-analytics-service-mvp.md`.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Milestone 1 — Add `openapi-hs` and `servant-openapi-hs` as local packages in
  `cabal.project`; add `build-depends` on both to the `kansoku` library stanza; confirm the
  project still resolves (`cabal build --dry-run` or a real build).
- [x] Milestone 1 — Ensure the combined servant API type `Kansoku.Api.KansokuAPI` exists in
  `api/Kansoku/Api.hs` (assemble it from `IngestAPI` and `MetricsAPI`, defining a placeholder
  `MetricsAPI` if EP-6 has not landed yet).
- [x] Milestone 1 — Add `ToSchema` instances for `AnalyticsEvent`, `EventSource`, `IngestAck`,
  `BatchAck`, the metric request/response types, and (if the placeholder is in play)
  `MetricsPlaceholderResponse` — all Generic-defaulted empty-body instances in
  `src/Kansoku/OpenApi.hs`.
- [x] Milestone 1 — Implement `Kansoku.OpenApi.openApiDoc :: OpenApi` and enrich it with
  title/version/description/tags metadata.
- [x] Milestone 1 — Write a unit test that encodes `openApiDoc` to JSON and asserts the key
  paths and the `AnalyticsEvent` component are present, adding `openapi-hs` to the
  `test-suite` stanza's `build-depends`; `cabal test` passes.
- [x] Milestone 2 — Add the `GET /openapi.json` route to the server and wire a handler that
  returns `openApiDoc`; the server starts and the route responds.
- [x] Milestone 2 — Verify with `curl` + `jq` that the served document is a valid OpenAPI 3.1
  doc containing the expected paths and schema.
- [ ] Milestone 3 (optional, deferred) — Serve a static Swagger-UI/Redoc HTML page at `GET /docs`
  pointed at `/openapi.json`; open it in a browser and confirm the endpoints render.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Discovery (2026-07-02, implementation): EP-6 had landed before EP-8 began, so no placeholder
  metrics API was needed. `Kansoku.Api.KansokuAPI` already combines the real `IngestAPI` and
  `MetricsAPI`, and `/openapi.json` includes the full declared `/metrics/*` surface.
- Discovery (2026-07-02, implementation): the current server dispatch is a small WAI
  `pathInfo` router rather than a unified servant `serve` tree. EP-8 still derives
  `openApiDoc` from the shared servant `KansokuAPI`, but exposes it by adding a WAI branch for
  `["openapi.json"]` in `Kansoku.Server.kansokuApp`.
- Discovery (2026-07-02, implementation): `nix build .#default` needed explicit overrides for
  `openapi-hs` and `servant-openapi-hs` in `nix/haskell.nix`. The local
  `servant-openapi-hs` checkout is one commit ahead of `origin/master` only for a
  `.seihou/manifest.json` change, so the Nix override pins the fetchable upstream commit with
  identical Haskell source.
- Discovery (2026-07-02, implementation): Nix's Git flake source did not include new untracked
  files. Staging `src/Kansoku/OpenApi.hs` and `test/Kansoku/OpenApiSpec.hs` made the files
  visible to `nix build .#default`.


## Decision Log

Record every decision made while working on the plan.

- Decision: Use the author's own `openapi-hs` (module namespace `Data.OpenApi.*`) as the
  OpenAPI 3.1 data model and `servant-openapi-hs` (`Servant.OpenApi`) to derive the document
  from the servant API type, rather than any Hackage package.
  Rationale: These are the author's maintained libraries, they explicitly target GHC 9.12.4 /
  9.14.1 (matching this repository's pin), and using them is the stated purpose of EP-8. The
  entry point is confirmed from source: `toOpenApi :: HasOpenApi api => Proxy api -> OpenApi`
  in `Servant.OpenApi` (declared in `src/Servant/OpenApi/Internal.hs` as
  `class HasOpenApi api where toOpenApi :: Proxy api -> OpenApi`).
  Date: 2026-07-01

- Decision: Serve the OpenAPI document from the existing WAI router at `GET /openapi.json`,
  encoding `openApiDoc` with the `ToJSON OpenApi` instance that `openapi-hs` provides
  (`instance ToJSON OpenApi` in `openapi-hs/src/Data/OpenApi/Internal.hs`), rather than
  serializing to a file and serving a static asset.
  Rationale: The current server already dispatches `health`, ingestion, and metrics through a
  small WAI `pathInfo` router, so adding `["openapi.json"]` there is the narrowest change. The
  document is still generated in-process from the shared servant `KansokuAPI` and cannot go
  stale relative to the checked API type.
  Date: 2026-07-01

- Decision: Provide the per-type schemas with `Generic`-derived `ToSchema` instances (the
  `ToSchema` class from `openapi-hs`, `Data.OpenApi`), not hand-written schemas.
  Rationale: `openapi-hs`'s `ToSchema` has a `default declareNamedSchema` for any
  `Generic` type (confirmed: `class Typeable a => ToSchema a` with a default signature in
  `openapi-hs/src/Data/OpenApi/Internal/Schema.hs:143`), so `instance ToSchema AnalyticsEvent`
  with an empty body suffices as long as `AnalyticsEvent` derives `Generic`. This keeps the
  schema in lockstep with the record definition. Where the Generic-derived JSON shape does not
  match `AnalyticsEvent`'s hand-written `ToJSON` (e.g. field-name mangling), the instance will
  be given explicit `SchemaOptions` — decided at implementation time and recorded here.
  Date: 2026-07-01

- Decision: The placeholder `MetricsPlaceholderResponse` (declared in `Kansoku.Api.Metrics`,
  inside the `kansoku-api` sub-library) does *not* derive `O.ToSchema` on its declaration; its
  instance is an empty-body orphan `instance O.ToSchema MetricsPlaceholderResponse` in
  `Kansoku.OpenApi` (main library), alongside the other foreign-type instances.
  Rationale: a `deriving anyclass (O.ToSchema)` clause on a declaration in the sub-library
  would force `openapi-hs` into the sub-library's `build-depends`, violating the sub-library's
  servant-only dependency invariant that this plan itself relies on. The orphan is confined to
  `Kansoku.OpenApi`, the module whose whole job is to attach OpenAPI schemas to types it does
  not own.
  Date: 2026-07-01

- Decision: Treat the human documentation UI (Swagger UI / Redoc) as an optional Milestone 3,
  not a required deliverable.
  Rationale: The MasterPlan and EP-8 scope name the machine-readable JSON as the must-have and
  the UI as nice-to-have. Serving a bundled HTML page requires either vendoring static assets
  or a CDN reference and is orthogonal to the contract itself, so it is isolated to a
  clearly-labeled optional milestone that can be skipped without affecting acceptance.
  Date: 2026-07-01


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

EP-8 is complete for the required machine-readable API contract. `Kansoku.OpenApi.openApiDoc`
is generated from the shared `KansokuAPI` with `servant-openapi-hs`, the server exposes it at
`GET /openapi.json`, and the unit test checks OpenAPI 3.1, ingestion and metrics paths, and
the `AnalyticsEvent` component schema. The optional Swagger UI / Redoc page was intentionally
deferred; the JSON contract is the MVP deliverable.

Validation evidence from 2026-07-02:

- `cabal build all` passed.
- `cabal test all` passed; Kansoku's ClickHouse-dependent examples were pending only because
  the local stack was not running during that test invocation.
- `nix fmt` passed.
- `nix build .#default` passed after adding Nix overrides for the OpenAPI packages and staging
  the new source files.
- Live smoke test with `kansoku-server` on port `18081` passed:
  `curl -fsS http://127.0.0.1:18081/openapi.json | jq -e '.openapi | startswith("3.1")'`,
  the paths check for `/v1/events`, `/v1/batch`, and `/metrics*`, and the
  `components.schemas.AnalyticsEvent` check all returned `true`; `/health` returned `OK`.


## Context and Orientation

This section assumes you know nothing about this repository. Read it fully before editing.

**The repository.** The working tree is a Haskell project built with Nix. The Haskell package
is named `kansoku` and is described by the Cabal file `kansoku.cabal` at the repository root.
"Cabal" is Haskell's build description format; a `.cabal` file lists *stanzas* — a `library`
stanza (reusable modules), one or more `executable` stanzas (runnable binaries), and
`test-suite` stanzas. The build is driven either by `cabal` directly or by `nix build`. A
sibling file `cabal.project` at the repository root lists where to find packages that are not
on Hackage (Haskell's public package index); it has a `packages:` field naming local
directories and may have `source-repository-package` stanzas for git dependencies.

**Servant API types.** "servant" is a Haskell library for describing HTTP APIs *at the type
level*. An API is written as a type built from combinators: a string literal like `"v1"` is a
path segment, `:>` joins segments, `ReqBody '[JSON] X` means "the request body is `X` encoded
as JSON", `Post '[JSON] Y` / `Get '[JSON] Y` means "this is a POST/GET returning `Y` as JSON",
and `:<|>` joins two endpoints into a larger API. For example
`"v1" :> "events" :> ReqBody '[JSON] AnalyticsEvent :> Post '[JSON] IngestAck` describes
`POST /v1/events`. A `Proxy` is a zero-data value that carries a type so functions can inspect
it: `Proxy :: Proxy KansokuAPI` (or, with the `TypeApplications` extension, `Proxy @KansokuAPI`)
means "here is the `KansokuAPI` type, at the value level".

**The shared internal sub-library `kansoku:kansoku-api`.** The MasterPlan establishes a
Cabal *sub-library* (an internal library component inside `kansoku.cabal`, named
`kansoku-api`) that holds three things and nothing else: (1) the shared custom prelude
`Kansoku.Prelude` (established by EP-1; every module in the project imports it, and it
re-exports `Text`, `Generic`, the aeson names, `time`, `NonEmpty`, and the `Control.Lens`
operators); (2) the event model — the modules `Kansoku.Event`, `Kansoku.Event.Registry`,
`Kansoku.Event.Validation` — and (3) the servant API *type declarations only*, with no request
handlers and no web server. Those API-type modules are:

- `Kansoku.Api.Ingest`, owned by EP-4, exposing
  `type IngestAPI = "v1" :> "events" :> ReqBody '[JSON] AnalyticsEvent :> Post '[JSON] IngestAck
  :<|> "v1" :> "batch" :> ReqBody '[JSON] [AnalyticsEvent] :> Post '[JSON] BatchAck`.
  EP-4 defines two acknowledgement records in `Kansoku.Api.Ingest`: `IngestAck` for the
  single-event endpoint and `BatchAck` for the batch endpoint (these are the real response
  DTO names; earlier drafts of this plan called them `IngestResponse`).
- `Kansoku.Api.Metrics`, owned by EP-6, exposing `type MetricsAPI = ...` covering the
  `GET /metrics/*` endpoints. Per EP-6's scope decision of 2026-07-01, the `MetricsAPI` type
  declares all eleven metrics routes; seven have real handlers (events, page-views, sessions,
  funnel, retention, conversion, users) and four are stubbed to return HTTP 501 Not Implemented
  (acquisition, feature-adoption, organizations, custom). For this plan the distinction is
  irrelevant: `toOpenApi` walks the API *type*, so all eleven `/metrics/*` paths appear in the
  generated document regardless of handler status.
- `Kansoku.Api`, exposing the combined `type KansokuAPI = IngestAPI :<|> MetricsAPI`.

The crucial property: `kansoku-api` depends only on `servant` (the API *combinators*, not the
server), plus `aeson`, `base`, `text`, `time`, `containers`, `uuid`, and — because it hosts
`Kansoku.Prelude` — `generic-lens` and `lens`. It does **not** depend on `servant-server` or
`warp` (the web server). The heavy `kansoku` library implements the
actual handlers and serves them; EP-7's SDK derives a `servant-client` from the same types; and
**this** plan (EP-8) feeds `KansokuAPI` into `servant-openapi-hs` to produce the OpenAPI
document. That is the whole reason the API types were factored into a lightweight sub-library:
several independent consumers share one type.

**Dependency status you must handle.** EP-8 hard-depends on EP-4 (which owns
`Kansoku.Api.Ingest`) and EP-6 (which owns `Kansoku.Api.Metrics`). When you begin, EP-4 is
expected to have landed, so `Kansoku.Api.Ingest` and its `IngestAPI` exist. EP-6 may or may not
have landed. Therefore this plan is written to *assemble* the combined `KansokuAPI` itself: if
`Kansoku.Api` with a complete `KansokuAPI = IngestAPI :<|> MetricsAPI` already exists, use it as
is; if `Kansoku.Api.Metrics` does not yet exist, define a minimal placeholder `MetricsAPI` (see
Plan of Work, Milestone 1) so the document still builds and serves the ingestion paths, and
record in the Decision Log that the metrics paths are a placeholder to be replaced when EP-6
lands. This keeps EP-8 independently verifiable.

**The two author libraries this plan is built on (read them before editing).** Both live under
`/Users/shinzui/Keikaku/bokuno/openapi-hs-project/`:

- `openapi-hs` at `/Users/shinzui/Keikaku/bokuno/openapi-hs-project/openapi-hs`. This is the
  OpenAPI 3.1 *data model*: the Haskell types that represent an OpenAPI document, plus their
  JSON encoders/decoders. Its module namespace is `Data.OpenApi.*` (it is a fork of the
  `openapi3` package that keeps the same namespace). The top-level umbrella module is
  `Data.OpenApi`. The document type is `OpenApi` (defined in
  `src/Data/OpenApi/Internal.hs:86` as `data OpenApi = OpenApi { ... }`). It encodes to JSON
  via `instance ToJSON OpenApi` (`src/Data/OpenApi/Internal.hs:1457`) and its `openapi`
  version field defaults to `3.1.0` (the code pins the valid range `[3,1,0] … [3,1,1]`, see
  `lowerOpenApiSpecVersion` / `upperOpenApiSpecVersion` at `src/Data/OpenApi/Internal.hs:123`).
  The per-type schema class is `ToSchema` (re-exported from `Data.OpenApi`, defined in
  `src/Data/OpenApi/Internal/Schema.hs:143` as `class Typeable a => ToSchema a where
  declareNamedSchema :: Proxy a -> Declare (Definitions Schema) NamedSchema`) and it carries a
  `default declareNamedSchema` for any `Generic` type, so `instance ToSchema Foo` with an empty
  body works when `Foo` derives `Generic`. For enriching the document with metadata,
  `Data.OpenApi` re-exports lens accessors used like `doc & info . title .~ "…"` and
  `doc & info . version .~ "…"` and `doc & info . description ?~ "…"` and `doc & servers .~ […]`,
  and the helper `applyTags :: [Tag] -> OpenApi -> OpenApi` with the constructor
  `Tag :: Text -> Maybe Text -> Maybe ExternalDocs -> Tag` (the third field is
  `Maybe ExternalDocs`; there is no separate `TagExternalDocs` type) (see
  `src/Data/OpenApi/Operation.hs:165` and `src/Data/OpenApi/Internal.hs:998`). The one guide
  doc is `MIGRATION_3.0_TO_3.1.md` in that repository.

- `servant-openapi-hs` at
  `/Users/shinzui/Keikaku/bokuno/openapi-hs-project/servant-openapi-hs`. This *derives* an
  OpenAPI document from a servant API type. Its umbrella module is `Servant.OpenApi`. The
  exact entry point, confirmed from source (`src/Servant/OpenApi/Internal.hs:79`), is:

  ```haskell
  class HasOpenApi api where
    toOpenApi :: Proxy api -> OpenApi
  ```

  There is an instance of `HasOpenApi` for every servant combinator, so any well-formed
  servant API type is automatically an instance. To turn per-type request/response records
  into schemas, `toOpenApi` requires a `ToSchema` instance (from `openapi-hs`) for each type
  that appears in a `ReqBody` or a response, and a `ToParamSchema` instance for each type used
  in a path capture or query parameter. A complete, runnable example ships as the
  `gen-openapi` executable at
  `/Users/shinzui/Keikaku/bokuno/openapi-hs-project/servant-openapi-hs/app/GenOpenApi.hs`; it
  builds a document with `toOpenApi (Proxy :: Proxy TodoAPI)` and enriches it exactly as this
  plan will (`& O.info . O.title .~ …`, `& O.applyTags [O.Tag "todos" (Just "…") Nothing]`).
  Read that file — it is the template for `Kansoku.OpenApi`.

Both libraries build with GHC 9.12.4 / 9.14.1, matching this repository's GHC pin. Neither is on
Hackage, so both must be added to `cabal.project` as local `packages:` entries (see Milestone 1
and Interfaces). Do not attempt to fetch them from Hackage.

**What already exists that you extend.** From EP-1, the `kansoku-server` executable exists (its
`main` lives under `app/` and starts a warp HTTP server on a port from `Kansoku.Config`,
defaulting to 8080) and it already serves at least a health endpoint and, once EP-4/EP-6 are in,
the ingestion and metrics endpoints via servant's `serve`. This plan adds one route to that
server's top-level API and one handler.

**Coding standards (read before writing any Haskell).** All Haskell in this repository follows
the shared house style documented under
`/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/core/` (`standards.md`, `custom-prelude.md`,
`record-patterns.md`, `multiline-strings.md`). The points that shape the sketches below: every
cabal stanza uses the GHC2024 language edition and a shared `common` stanza (`import: common`)
enabling `DeriveAnyClass`, `DuplicateRecordFields`, `OverloadedLabels`, `OverloadedStrings`, and
`MultilineStrings`, so `Kansoku.OpenApi` and any placeholder module inherit those (no per-file
`{-# LANGUAGE TypeApplications #-}` is needed — GHC2024 provides it). Every module opens with
`import Kansoku.Prelude` — the custom prelude established by EP-1 and re-exported from the
`kansoku:kansoku-api` sub-library, which supplies `Proxy`, `Text`, `Generic`, the aeson names,
`time`, and the `Control.Lens` operators — instead of restating those imports. Qualified imports
are postpositive (`import Data.OpenApi qualified as O`). Records use strict `!` fields, carry no
field prefixes, and derive explicitly (`deriving stock (Generic, Eq, Show)` plus
`deriving anyclass (FromJSON, ToJSON, O.ToSchema)` for types this plan owns). Any embedded JSON
or text fixture in a Haskell literal is written with the `"""..."""` `MultilineStrings` form
rather than escaped one-line strings.


## Plan of Work

The work proceeds in two required milestones and one optional milestone. Each is independently
verifiable.

### Milestone 1 — Build the OpenAPI document from the servant API type, unit-tested

Scope: at the end of this milestone the code compiles, the two author libraries are wired into
the build, and a pure value `Kansoku.OpenApi.openApiDoc :: OpenApi` exists and is proven correct
by a unit test that encodes it to JSON and checks that the important paths and schemas are
present. No HTTP serving yet.

First, wire the dependencies. Edit `cabal.project` at the repository root: add the two library
directories to the `packages:` stanza so Cabal builds them from source. The exact directory
paths, confirmed with `mori registry show`, are
`/Users/shinzui/Keikaku/bokuno/openapi-hs-project/openapi-hs` and
`/Users/shinzui/Keikaku/bokuno/openapi-hs-project/servant-openapi-hs` (both are single-package
repositories whose Cabal file sits at the repository root, i.e. component path `./`). Then edit
`kansoku.cabal`: to the `library` stanza's `build-depends`, add `openapi-hs` and
`servant-openapi-hs`. The `servant` dependency is already present via `kansoku-api`. Because
`toOpenApi` operates on the API *type*, the new module can live in the main `kansoku` library
(it does not need `servant-server`); place it there.

Second, make sure the combined API type exists. Open `src/Kansoku/Api.hs`. If it already exports
`type KansokuAPI = IngestAPI :<|> MetricsAPI` (EP-6 landed), you are done — skip to the next
paragraph. If `Kansoku.Api.Metrics` does not exist yet, add a minimal placeholder so the
document still builds: in `src/Kansoku/Api/Metrics.hs` define
`type MetricsAPI = "metrics" :> "events" :> Get '[JSON] MetricsPlaceholderResponse` (a single
representative endpoint) with a tiny `MetricsPlaceholderResponse` record written in the house
style — `import Kansoku.Prelude`, a strict `!` field, and explicit deriving:

```haskell
data MetricsPlaceholderResponse = MetricsPlaceholderResponse
  { status :: !Text
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)
```

Deliberately, this declaration does **not** derive `O.ToSchema`: it lives in the `kansoku-api`
sub-library, whose build-depends must stay servant-only (no `openapi-hs`), so deriving
`O.ToSchema` here would drag `openapi-hs` into the sub-library and violate that invariant —
instead its schema instance is the empty-body orphan
`instance O.ToSchema MetricsPlaceholderResponse` in `Kansoku.OpenApi` (main library), exactly
like the other foreign-type instances below. Then in `src/Kansoku/Api.hs` define
`type KansokuAPI = IngestAPI :<|> MetricsAPI`. Record in the Decision Log that the metrics
portion is a placeholder to be replaced by EP-6's real `MetricsAPI`. This keeps EP-8 buildable
and demonstrable regardless of EP-6's status; when EP-6 lands, deleting the placeholder and
importing the real `Kansoku.Api.Metrics` is the only change needed.

Third, create the new module `src/Kansoku/OpenApi.hs` (module `Kansoku.OpenApi`). Model it on
`app/GenOpenApi.hs` from `servant-openapi-hs`. It must:

- Import the shared prelude and the OpenApi machinery. `Kansoku.OpenApi` begins with
  `import Kansoku.Prelude` (established by EP-1, re-exported from `kansoku:kansoku-api`), which
  supplies `Proxy`, `Text`, `Generic`, the aeson names, and the `Control.Lens` enrichment
  operators `&`/`.~`/`?~` — so none of those need a separate import. Then add the two module-
  specific imports using postpositive `qualified` syntax:

  ```haskell
  import Kansoku.Prelude
  import Kansoku.Api (KansokuAPI)
  import Kansoku.Event (AnalyticsEvent, EventSource (..))
  import Data.OpenApi qualified as O
  import Servant.OpenApi (toOpenApi)
  ```

  (`lens` reaches this module transitively through `Kansoku.Prelude`; if the compiler reports it
  is not directly visible, add `lens` to `build-depends`.)
- Provide the `ToSchema` instances the document needs. `openapi-hs`'s `ToSchema` carries a
  `default declareNamedSchema` for any `Generic` type, so the instances are Generic-defaulted.
  There are two cases, decided by *which component declares the type*:

  - For a record **declared in the main `kansoku` library** (which does depend on `openapi-hs`),
    attach the instance with an explicit `deriving anyclass (O.ToSchema)` clause on the data
    declaration — the same explicit-deriving style the house standards require for
    `FromJSON`/`ToJSON` (`DeriveAnyClass` is on in the `common` stanza). At the time of writing
    EP-8 declares no such record; this case exists so future main-library DTOs follow the house
    style.

  - For **every type declared in the `kansoku-api` sub-library** — the foreign types EP-8 must
    not edit (EP-2's `AnalyticsEvent` and `EventSource`, EP-4's `IngestAck` and `BatchAck`,
    EP-6's metric request/response records) *and* this plan's own placeholder
    `MetricsPlaceholderResponse` — supply an empty-body standalone (orphan) instance in
    `Kansoku.OpenApi` instead: `instance O.ToSchema AnalyticsEvent`,
    `instance O.ToSchema EventSource`, `instance O.ToSchema IngestAck`,
    `instance O.ToSchema BatchAck`, one per metric record used by `KansokuAPI`, and
    `instance O.ToSchema MetricsPlaceholderResponse` when the placeholder is in play. The
    placeholder is included here even though EP-8 owns it, because a `deriving` clause on its
    declaration would force `openapi-hs` into the sub-library's `build-depends` and break the
    sub-library's servant-only invariant. These instances are still Generic-defaulted (the
    types already derive `Generic` for their aeson instances); the empty body just accepts the
    default.

  If any type is used in a path capture or query parameter, also give it
  `instance O.ToParamSchema T`. Import the event types from `Kansoku.Event` and the response
  types from their owning modules.
- Define the document:

  ```haskell
  openApiDoc :: O.OpenApi
  openApiDoc = toOpenApi (Proxy @KansokuAPI)
    & O.info . O.title       .~ "Kansoku Analytics API"
    & O.info . O.version     .~ "1.0.0"
    & O.info . O.description ?~ "HTTP ingestion and typed metrics query API for the Kansoku analytics service."
    & O.applyTags
        [ O.Tag "ingestion" (Just "Event ingestion endpoints") Nothing
        , O.Tag "metrics"   (Just "Typed metric query endpoints") Nothing
        ]
  ```

  `Proxy @KansokuAPI` (the `TypeApplications` form) works without a per-file pragma because
  GHC2024 — the language edition set in the shared `common` cabal stanza — already enables
  `TypeApplications`; `Proxy` and the `&`/`.~`/`?~` operators come from `Kansoku.Prelude`. Keep
  the metadata strings accurate; they are what external consumers see.

Fourth, if the Generic-derived schema for `AnalyticsEvent` does not match its hand-written JSON
field names (for example if `Kansoku.Event` uses an aeson `fieldLabelModifier` to drop a record
prefix or camel-case a field), give the `ToSchema` instance matching `SchemaOptions` so the
schema's property names equal the JSON keys. `openapi-hs` exposes `Data.OpenApi.SchemaOptions`
and `genericDeclareNamedSchema` for this; consult `src/Data/OpenApi/SchemaOptions.hs` and mirror
whatever `Options` the `ToJSON`/`FromJSON` instances use. Record any such adjustment in
Surprises & Discoveries with the before/after property names as evidence.

Fifth, add a unit test. This repository's test-suite wiring is established by EP-1; add a new
test module (for example `test/Kansoku/OpenApiSpec.hs`, matching the existing test layout —
check `kansoku.cabal`'s `test-suite` stanza and follow its `hs-source-dirs` and discovery
convention). The test encodes the document and asserts structure. Use `aeson` to encode and
either `aeson`'s `Value` navigation or `lens-aeson` to inspect. The test-suite stanza needs its
own `build-depends` edits — a test module only sees packages listed in its own stanza, so the
main-library edits above are not enough: add `lens-aeson` if you navigate the JSON with it, and
add `openapi-hs` if the test names any `Data.OpenApi` type directly (for example a type
annotation on `openApiDoc`); `aeson` and the `kansoku` library are already in the test-suite's
`build-depends` from EP-1. The assertions:

- `O.toJSON openApiDoc` (or `Data.Aeson.toJSON openApiDoc`) has a top-level `"openapi"` string
  beginning with `"3.1"`.
- Its `"paths"` object has keys `"/v1/events"`, `"/v1/batch"`, and at least one `"/metrics/..."`
  key.
- Its `"components"."schemas"` object has a key `"AnalyticsEvent"`.

Acceptance for Milestone 1: `cabal build` succeeds (both author libraries compile as local
packages) and `cabal test` runs the new test green. Commands and expected output are in
Concrete Steps.

### Milestone 2 — Serve GET /openapi.json and verify with curl/jq

Scope: at the end of this milestone the running `kansoku-server` answers `GET /openapi.json`
with the document from Milestone 1, verified over HTTP.

Find the module that assembles the server's top-level servant API and calls servant's `serve`
(from EP-1/EP-4; likely `app/Main.hs` or a `Kansoku.Server` module — locate it by searching for
`serve ` and `Application`). The server currently serves some `type API = …` (health +
ingestion + metrics). Extend it: define
`type OpenApiAPI = "openapi.json" :> Get '[JSON] O.OpenApi` and add it to the server's combined
API type with `:<|>` (order does not matter for routing). Because `O.OpenApi` has a `ToJSON`
instance, servant's `JSON` content type renders it directly; no extra instance is needed. Add
the matching handler: a value of the handler type that simply returns `Kansoku.OpenApi.openApiDoc`
(in servant a `Get '[JSON] X` handler has type `Handler X`, so the handler is
`pure Kansoku.OpenApi.openApiDoc` or `return openApiDoc`). Keep the handler list aligned with
the API type — servant requires the handler tuple joined by `:<|>` to match the API type's shape
exactly, so add the new handler in the same position you added the route.

Acceptance for Milestone 2: start the server, then `curl -s http://localhost:8080/openapi.json |
jq .` prints a valid OpenAPI 3.1 document; targeted `jq` queries show the expected paths and the
`AnalyticsEvent` schema. Commands and expected transcript are in Concrete Steps and Validation.

### Milestone 3 (optional) — Human documentation UI

Scope: serve a browser-viewable API documentation page that reads `/openapi.json`. This is
nice-to-have; skipping it does not affect acceptance of the plan.

The simplest approach that adds no build-time asset pipeline is to serve a tiny static HTML page
that loads a documentation renderer from a CDN and points it at `/openapi.json`. Add a route
`type DocsAPI = "docs" :> Get '[HTML] Text` (using servant's `HTML` content type from
`servant-blaze` or a hand-rolled `HTML` type, or more simply serve it via servant's `Raw` static
file handler). The HTML body is a few lines that embed Redoc:

```html
<!doctype html>
<html>
  <head><title>Kansoku API</title></head>
  <body>
    <redoc spec-url="/openapi.json"></redoc>
    <script src="https://cdn.redocly.com/redoc/latest/bundles/redoc.standalone.js"></script>
  </body>
</html>
```

Because this pulls a script from a CDN, it only renders where the browser has internet access;
note that limitation in the Decision Log if you implement it. If offline rendering is required,
vendor `redoc.standalone.js` under a `static/` directory and serve it with servant's `Raw`
handler instead, and record that choice. Acceptance: open `http://localhost:8080/docs` in a
browser and see the three ingestion/metrics endpoints rendered with their schemas.


## Concrete Steps

All commands run from the repository root
`/Users/shinzui/Keikaku/bokuno/kansoku-project/kansoku` unless stated otherwise.

Step 1 — read the two author libraries so you are working from their real APIs, not memory:

```bash
mori registry show shinzui/openapi-hs --full
mori registry show shinzui/servant-openapi-hs --full
sed -n '78,82p' /Users/shinzui/Keikaku/bokuno/openapi-hs-project/servant-openapi-hs/src/Servant/OpenApi/Internal.hs
cat /Users/shinzui/Keikaku/bokuno/openapi-hs-project/servant-openapi-hs/app/GenOpenApi.hs
```

You should see `class HasOpenApi api where` / `toOpenApi :: Proxy api -> OpenApi` in the `sed`
output, and a complete enrichment example in `GenOpenApi.hs`.

Step 2 — edit `cabal.project` to add both packages. After editing, the `packages:` list must
include the two directories. Confirm they are seen:

```bash
grep -n "openapi-hs\|servant-openapi-hs\|packages" cabal.project
```

Expected: lines showing both
`/Users/shinzui/Keikaku/bokuno/openapi-hs-project/openapi-hs` and
`/Users/shinzui/Keikaku/bokuno/openapi-hs-project/servant-openapi-hs` under `packages:`.

Step 3 — edit `kansoku.cabal` to add `openapi-hs`, `servant-openapi-hs` (and `lens` if needed)
to the `library` stanza `build-depends`, and add `Kansoku.OpenApi` to its `exposed-modules`.
Also edit the `test-suite` stanza's `build-depends` for the Milestone 1 test: add `lens-aeson`
(and `openapi-hs` if the test names `Data.OpenApi` types directly). Do **not** add `openapi-hs`
to the `kansoku-api` sub-library stanza under any circumstances (see Interfaces and
Dependencies). Confirm:

```bash
grep -n "openapi-hs\|servant-openapi-hs\|Kansoku.OpenApi" kansoku.cabal
```

Step 4 — create `src/Kansoku/OpenApi.hs` and (if EP-6 has not landed) the placeholder
`src/Kansoku/Api/Metrics.hs` and combined `src/Kansoku/Api.hs`, as described in Milestone 1.

Step 5 — build:

```bash
cabal build
```

Expected tail on success (versions/paths will vary):

```text
[ N of M] Compiling Kansoku.OpenApi   ( src/Kansoku/OpenApi.hs, ... )
Linking ...
```

A common first failure is a missing `ToSchema` or `ToParamSchema` instance; the compiler names
the exact type, e.g. `No instance for (Data.OpenApi.ToSchema IngestAck)`. Add the empty
Generic-derived instance for that type in `Kansoku.OpenApi` and rebuild. Repeat until it links.

Step 6 — run the unit test:

```bash
cabal test
```

Expected (exact wording depends on the test framework EP-1 chose, e.g. hspec):

```text
Kansoku.OpenApi
  openApiDoc
    reports OpenAPI version 3.1.x   [✔]
    includes /v1/events, /v1/batch, and a /metrics path   [✔]
    includes the AnalyticsEvent component schema   [✔]

Finished in ... seconds
3 examples, 0 failures
```

Step 7 (Milestone 2) — add the `GET /openapi.json` route and handler, rebuild, then start the
server. Use the project's normal run command (from EP-1); typically:

```bash
cabal run kansoku-server
```

In another terminal, verify:

```bash
curl -s http://localhost:8080/openapi.json | jq '.openapi'
curl -s http://localhost:8080/openapi.json | jq '.paths | keys'
curl -s http://localhost:8080/openapi.json | jq '.components.schemas | keys'
```

Expected output (order of keys may vary):

```json
"3.1.0"
```

```json
[
  "/metrics/events",
  "/v1/batch",
  "/v1/events"
]
```

```json
[
  "AnalyticsEvent",
  "BatchAck",
  "EventSource",
  "IngestAck"
]
```

(The schema-key list is illustrative of the real DTO names — `IngestAck` and `BatchAck` are
EP-4's actual response records; the full set will also include the EP-6 metric records, or
`MetricsPlaceholderResponse` while the placeholder `MetricsAPI` is in play.)

If the port differs from 8080, read it from `Kansoku.Config` or the server's startup log line
and substitute it in the URLs.

Step 8 (optional, Milestone 3) — add the `/docs` route, rebuild, run the server, and open
`http://localhost:8080/docs` in a browser to confirm the endpoints render.


## Validation and Acceptance

The plan is accepted when both required milestones pass.

Milestone 1 is accepted when, from the repository root, `cabal build` succeeds and `cabal test`
reports the `Kansoku.OpenApi` unit test green. This proves the document is generated from the
real `KansokuAPI` type and structurally contains the ingestion paths, at least one metrics path,
and the `AnalyticsEvent` schema — beyond mere compilation, the test decodes the encoded JSON and
inspects it.

Milestone 2 is accepted when, with `kansoku-server` running, the following holds:

```bash
curl -s http://localhost:8080/openapi.json | jq -e '.openapi | startswith("3.1")' >/dev/null && echo VERSION_OK
curl -s http://localhost:8080/openapi.json | jq -e '.paths | has("/v1/events") and has("/v1/batch")' >/dev/null && echo INGEST_PATHS_OK
curl -s http://localhost:8080/openapi.json | jq -e '.paths | keys | any(startswith("/metrics"))' >/dev/null && echo METRICS_PATH_OK
curl -s http://localhost:8080/openapi.json | jq -e '.components.schemas | has("AnalyticsEvent")' >/dev/null && echo SCHEMA_OK
```

Expected:

```text
VERSION_OK
INGEST_PATHS_OK
METRICS_PATH_OK
SCHEMA_OK
```

When the placeholder `MetricsAPI` is in play (EP-6's real `Kansoku.Api.Metrics` not yet wired
in), passing these checks makes EP-8's acceptance *provisional*: the plan is only fully
complete once EP-6's real `MetricsAPI` replaces the placeholder and `/openapi.json`
regenerates with the real metrics paths.

Optionally, run an external OpenAPI linter to confirm the document is valid against the 3.1
standard (this is the same authoritative check `servant-openapi-hs`'s own README uses):

```bash
curl -s http://localhost:8080/openapi.json > /tmp/kansoku-openapi.json
nix run nixpkgs#vacuum-go -- lint -d /tmp/kansoku-openapi.json
```

Expected: the linter reports no errors (warnings about missing optional descriptions are
acceptable and can be addressed later by enriching operation metadata as `GenOpenApi.hs` does
with `operationId`s).

Future use to keep in mind (not part of acceptance): this same `openapi.json` is the input for
`openapi-typescript`, which the deferred `kansoku-js` / TypeScript SDK effort will run to
generate typed client bindings — for example
`npx openapi-typescript http://localhost:8080/openapi.json -o kansoku.d.ts`. That command is out
of scope here; it is recorded so the intent of the document is clear.

Milestone 3 (optional) is accepted when `http://localhost:8080/docs` renders the endpoints in a
browser.


## Idempotence and Recovery

Every editing step is additive and safe to repeat. Re-running `cabal build` and `cabal test` has
no side effects. Editing `cabal.project` and `kansoku.cabal` is idempotent as long as you do not
duplicate the same package or dependency line; before adding, grep for the entry (Steps 2 and 3)
and only add if absent. The new `src/Kansoku/OpenApi.hs` is a fresh file; re-creating it
overwrites cleanly. Starting the server is safe to repeat; stop a previous instance first
(Ctrl-C, or find it with `lsof -i :8080` and kill that PID) to avoid a "port already in use"
error. If a build fails midway on a missing `ToSchema`/`ToParamSchema` instance, the fix is
always additive — add the named empty Generic instance and rebuild — so there is no partial
state to roll back. If the placeholder `MetricsAPI` was added and EP-6 later lands with the real
one, delete the placeholder module and the placeholder `KansokuAPI` line, import the real
`Kansoku.Api.Metrics`, rebuild, and the same tests validate the richer document.


## Interfaces and Dependencies

**Libraries used and why.**

- `openapi-hs` (path `/Users/shinzui/Keikaku/bokuno/openapi-hs-project/openapi-hs`, module
  namespace `Data.OpenApi.*`): supplies the `OpenApi` document type, its `ToJSON`/`FromJSON`
  instances (so it serializes to and from JSON), the `ToSchema` class for per-type schemas, and
  the enrichment lenses/helpers (`info . title`, `info . version`, `info . description`,
  `servers`, `applyTags`, the `Tag` constructor, `SchemaOptions`). It is the data model the
  document is made of.
- `servant-openapi-hs` (path
  `/Users/shinzui/Keikaku/bokuno/openapi-hs-project/servant-openapi-hs`, module `Servant.OpenApi`):
  supplies `toOpenApi`, which walks the servant API type and produces the `OpenApi` value. This
  is the bridge from "servant type" to "OpenAPI document".
- `servant` (already a dependency via `kansoku-api`): the API combinators the types are built
  from.

Neither `openapi-hs` nor `servant-openapi-hs` is on Hackage; both are added to `cabal.project`
as local `packages:` entries. Confirmed component paths (each repository's Cabal file is at its
root, so the component path is `./`):

```text
packages:
  .
  /Users/shinzui/Keikaku/bokuno/openapi-hs-project/openapi-hs
  /Users/shinzui/Keikaku/bokuno/openapi-hs-project/servant-openapi-hs
```

(The leading `.` is the `kansoku` package itself; preserve any existing entries and append the
two new lines.)

**`kansoku.cabal` edits.** In the `library` stanza, add to `build-depends`:

```text
    , openapi-hs
    , servant-openapi-hs
    , lens
```

(`lens` only if the compiler reports the `&`/`.~`/`?~` operators or the OpenApi lenses are not
already in scope transitively.) Add to that stanza's `exposed-modules`:

```text
    Kansoku.OpenApi
```

If a placeholder metrics API is needed, also add `Kansoku.Api` and `Kansoku.Api.Metrics` to
`exposed-modules` of the `kansoku-api` sub-library stanza (they belong there per the MasterPlan,
alongside `Kansoku.Api.Ingest`), not to the main library. Do **not** add `openapi-hs` to the
sub-library's `build-depends`: the placeholder record derives only stock
`(Generic, Eq, Show)` and anyclass `(FromJSON, ToJSON)`, and its `ToSchema` instance lives in
`Kansoku.OpenApi` as an orphan, precisely so the sub-library keeps its servant-only dependency
footprint (the invariant stated in Context and Orientation).

**Test-suite stanza edits.** The Milestone 1 unit test compiles in the `test-suite` stanza,
which has its own `build-depends`; main-library edits do not reach it. Add `lens-aeson` there
(for JSON navigation), and add `openapi-hs` as well if the test refers to any `Data.OpenApi`
type directly rather than only to the encoded `Value`. `aeson` and the `kansoku` library are
already test-suite dependencies from EP-1.

**Module and signatures that must exist at the end of Milestone 1.**

- `Kansoku.Api` (in the `kansoku-api` sub-library) exporting
  `type KansokuAPI = IngestAPI :<|> MetricsAPI`.
- `src/Kansoku/OpenApi.hs`, module `Kansoku.OpenApi`, exporting:

  ```haskell
  openApiDoc :: Data.OpenApi.OpenApi
  ```

  built as `toOpenApi (Proxy @KansokuAPI)` enriched with title/version/description/tags.

- The schema instances (all Generic-defaulted). Only a record declared in the main `kansoku`
  library may carry the instance via an explicit `deriving anyclass (O.ToSchema)` clause on its
  declaration (house style; `DeriveAnyClass` is on in the `common` stanza). Every type declared
  in the `kansoku-api` sub-library — the foreign types owned by EP-2/EP-4/EP-6 *and* this
  plan's own placeholder `MetricsPlaceholderResponse` — gets an empty-body standalone (orphan)
  instance in `Kansoku.OpenApi` instead, because the sub-library must not depend on
  `openapi-hs`:

  ```haskell
  -- Types declared in the kansoku-api sub-library — empty-body standalone
  -- instances in Kansoku.OpenApi (the sub-library must stay servant-only):
  instance O.ToSchema AnalyticsEvent
  instance O.ToSchema EventSource
  instance O.ToSchema IngestAck
  instance O.ToSchema BatchAck
  -- plus one ToSchema per EP-6 metric request/response record in KansokuAPI,
  -- and, while the placeholder MetricsAPI is in play:
  instance O.ToSchema MetricsPlaceholderResponse
  -- plus ToParamSchema for any path-capture / query-param type
  ```

- The entry point relied upon, quoted from `servant-openapi-hs`
  (`src/Servant/OpenApi/Internal.hs:79`):

  ```haskell
  class HasOpenApi api where
    toOpenApi :: Proxy api -> OpenApi
  ```

**Route and handler that must exist at the end of Milestone 2.** In the server-assembly module:

```haskell
type OpenApiAPI = "openapi.json" :> Get '[JSON] Data.OpenApi.OpenApi
-- added to the server's combined API type with :<|>, with a handler:
--   pure Kansoku.OpenApi.openApiDoc  ::  Servant.Handler Data.OpenApi.OpenApi
```

**Commit conventions.** Use Conventional Commits and commit directly to the current branch (do
not create a feature branch). Every commit for this plan must carry these trailers verbatim:

```text
feat(openapi): generate and serve OpenAPI 3.1 document from KansokuAPI

MasterPlan: docs/masterplans/1-kansoku-analytics-service-mvp.md
ExecPlan: docs/plans/8-openapi-schema-generation-and-api-documentation.md
Intention: intention_01kwf425fxenc904ear54cr2n7
```

(The subject line above is illustrative; write an accurate subject per commit — e.g.
`test(openapi): assert paths and AnalyticsEvent schema present` — but always include the three
trailer lines exactly as shown.)


## Revision Note

- 2026-07-01 (revision): **Adopted the shared `haskell-jitsurei/core` coding standards
  throughout the plan's Haskell sketches.** No design changed — the
  `toOpenApi (Proxy @KansokuAPI)` generation approach, the `openapi-hs` / `servant-openapi-hs`
  choice, the `GET /openapi.json` servant route, and the `kansoku:kansoku-api` structure are all
  exactly as before; only the *code style* of the embedded Haskell was brought into compliance
  with `/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/core/` (`standards.md`,
  `custom-prelude.md`, `record-patterns.md`, `multiline-strings.md`).

  What changed: `Kansoku.OpenApi`'s import list now leads with `import Kansoku.Prelude`
  (re-exported from `kansoku:kansoku-api`, established by EP-1), drops the separate
  `Data.Proxy`/`Control.Lens` imports it supersedes, and uses postpositive `qualified` syntax
  (`import Data.OpenApi qualified as O`); `openApiDoc` now builds from `toOpenApi (Proxy @KansokuAPI)`
  (the `TypeApplications` form, always available under GHC2024) instead of the
  `Proxy :: Proxy KansokuAPI` annotation, and the "if the module enables TypeApplications" caveat
  was removed. The `ToSchema` guidance now distinguishes the two cases the standards imply: types
  EP-8 owns (the placeholder `MetricsPlaceholderResponse`, now shown as a strict-field record
  with `deriving stock (Generic, Eq, Show)` / `deriving anyclass (FromJSON, ToJSON, O.ToSchema)`)
  attach the instance via explicit `deriving anyclass`, while types owned by other plans
  (`AnalyticsEvent`, `EventSource`, the ingestion response) keep empty-body standalone Generic
  instances because EP-8 must not edit their declarations. The Context and Orientation section
  gained a "Coding standards" paragraph pointing at `haskell-jitsurei/core/` and EP-1's
  `Kansoku.Prelude` + `common` stanza, and the `kansoku:kansoku-api` description now records that
  the sub-library also exposes `Kansoku.Prelude` (and therefore depends on `generic-lens`/`lens`).

  Why: consistency with the rest of the codebase. The house style (GHC2024, the `common`
  extension set including `MultilineStrings`, a single custom prelude, prefix-free strict records
  with explicit deriving, and `deriving anyclass` for Generic-defaulted classes like `ToSchema`)
  is mandatory for every Haskell package here, so the OpenAPI sketches must model it to guide a
  novice implementer toward conforming code.

- 2026-07-01 (revision, pre-implementation validation pass): **Corrected seven findings from a
  validation pass that checked this plan's claims against the real `openapi-hs` /
  `servant-openapi-hs` sources and the landed EP-4/EP-6 work.** No milestone was renumbered and
  the overall design (generate `OpenApi` from `KansokuAPI` with `toOpenApi`, serve it at
  `GET /openapi.json`) is unchanged.

  What changed and why:

  1. **Placeholder `ToSchema` moved out of the sub-library (major).** The earlier sketch had
     `MetricsPlaceholderResponse` derive `O.ToSchema` on its declaration inside the
     `kansoku-api` sub-library, which would force `openapi-hs` into the sub-library's
     `build-depends` and violate the servant-only invariant this very plan states. The
     placeholder now derives only stock `(Generic, Eq, Show)` + anyclass `(FromJSON, ToJSON)`,
     and its schema instance is an empty-body orphan
     `instance O.ToSchema MetricsPlaceholderResponse` in `Kansoku.OpenApi`, exactly like the
     other foreign-type instances. The Milestone 1 sketch, the two-case `ToSchema` guidance,
     the Interfaces sketch, and the cabal-edit instructions were all updated, and a Decision
     Log entry records the rationale.
  2. **Real EP-4 DTO names.** EP-4 defines `IngestAck` (single-event) and `BatchAck` (batch) in
     `Kansoku.Api.Ingest`; the plan previously used a hypothetical `IngestResponse` throughout.
     The `IngestAPI` sketch, the servant intro example, the Step 5 error-message example, and
     the Step 7 expected schema keys now use the real names, with the schema-key list marked as
     illustrative.
  3. **Constructor signature fix.** The `Tag` constructor's third field is `Maybe ExternalDocs`;
     the previously stated `TagExternalDocs` type does not exist in `openapi-hs`.
  4. **Source line references corrected** against the real files: `data OpenApi` is
     `Internal.hs:86` (was 87), the version pin is `Internal.hs:123` (was 124), and `applyTags`
     is `Operation.hs:165` (was 166).
  5. **Test-suite stanza edits made explicit.** The Milestone 1 test uses `lens-aeson` (and
     possibly `Data.OpenApi` types), but only main-library cabal edits were enumerated; the
     plan now spells out adding `lens-aeson` (and `openapi-hs` if needed) to the `test-suite`
     stanza's `build-depends` in Milestone 1, Step 3, and Interfaces, with corresponding
     Progress-item updates.
  6. **Provisional acceptance noted.** Validation and Acceptance now states that when the
     placeholder `MetricsAPI` is in play, EP-8's acceptance is provisional until EP-6's real
     `MetricsAPI` replaces it and `/openapi.json` regenerates with the real metrics paths.
  7. **EP-6 context aligned with its 2026-07-01 scope decision.** The `Kansoku.Api.Metrics`
     description now records that seven metrics endpoints are implemented (events, page-views,
     sessions, funnel, retention, conversion, users) and four are stubbed at HTTP 501
     (acquisition, feature-adoption, organizations, custom), while the `MetricsAPI` servant
     type still declares all eleven routes — so the generated document is unaffected by the
     handler-status split.
