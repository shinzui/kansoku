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

EP-8 is complete for the required machine-readable API contract. `Kansoku.Api.OpenApi.kansokuOpenApi`
is generated from `kansokuAPI :: Proxy (NamedRoutes KansokuAPI)` with `servant-openapi-hs`.
`kansoku-openapi` writes the deterministic checked artifact `docs/api/openapi.json`, and
`just openapi-check` regenerates it and runs `git diff --exit-code`. The WAI wrapper exposes the
same value at `GET /openapi.json`. The conformance suite pins exact served/documented paths and
operation IDs, 200/202 plus 400/404/503 responses, DTO JSON/schema agreement, and the WAI-only
operational allowlist. The optional Swagger UI / Redoc page remains deferred.

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

**Servant API types.** "servant" describes HTTP APIs at the type level. NamedRoutes attaches
each route to a record field through `mode :- route`, so server, client, tests, and OpenAPI all
reuse endpoint names instead of positional tuples. `MultiVerb` gives every analytics route an
explicit success response followed by the shared 400/404/503 error tail. A `Proxy` carries
such a type at the value level; the generator consumes the exact served value
`kansokuAPI :: Proxy (NamedRoutes KansokuAPI)`.

**The shared internal sub-library `kansoku:kansoku-api`.** The MasterPlan establishes a
Cabal *sub-library* (an internal library component inside `kansoku.cabal`, named
`kansoku-api`) that holds three things and nothing else: (1) the shared custom prelude
`Kansoku.Prelude` (established by EP-1; every module in the project imports it, and it
re-exports `Text`, `Generic`, the aeson names, `time`, `NonEmpty`, and the `Control.Lens`
operators); (2) the event model — the modules `Kansoku.Event`, `Kansoku.Event.Registry`,
`Kansoku.Event.Validation` — and (3) the servant API *type declarations only*, with no request
handlers and no web server. Those API modules are:

- `Kansoku.Ingest.Api`, exposing `IngestRoutes mode`, `IngestAck`, and `BatchAck`.
- `Kansoku.Metrics.Api`, exposing `MetricsRoutes mode`, `MetricQuery`, and the metric DTOs.
- `Kansoku.Api.Response`, owning `KansokuResult`, `ErrorEnvelopeWire`, and the reusable
  success-plus-error response lists.
- `Kansoku.Api`, exposing the umbrella `KansokuAPI mode` record and
  `kansokuAPI :: Proxy (NamedRoutes KansokuAPI)`.

The crucial property: `kansoku-api` has no `servant-server` or `warp` dependency. It owns the
route records and the OpenAPI generator, so it depends on the Servant API/MultiVerb/OpenAPI
libraries plus DTO dependencies. `kansoku-core` implements the handlers, EP-7's SDK derives a
generic client from the same records, and this plan feeds the exact umbrella proxy to
`servant-openapi-hs`. Several independent consumers therefore share one route type.

**Dependency status.** EP-4 and EP-6 have landed, and EP-9 normalized their contracts as
`Kansoku.Ingest.Api.IngestRoutes`, `Kansoku.Metrics.Api.MetricsRoutes`, and the umbrella
`Kansoku.Api.KansokuAPI`. Generate only from `kansokuAPI`; no fallback or placeholder contract
is permitted because it could diverge from the served route set.

**The two author libraries this plan is built on (read them through Mori before editing).**

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
  Read that file — it is the template for `Kansoku.Api.OpenApi`.

The released `openapi-hs` and `servant-openapi-hs` version used here is `4.1.0`; the local Mori
corpus provides their source and documentation, while `cabal.project` pins the registry pair.

**What already exists that you extend.** From EP-1, the `kansoku-server` executable exists (its
`main` lives under `app/` and starts a warp HTTP server on a port from `Kansoku.Config`,
defaulting to 8080) and it already serves at least a health endpoint and, once EP-4/EP-6 are in,
the ingestion and metrics endpoints via one Servant application. This plan adds one WAI wrapper
branch for the operational OpenAPI document; it does not add an analytics route or handler.

**Coding standards (read before writing any Haskell).** All Haskell in this repository follows
the shared house style documented under
`/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/core/` (`standards.md`, `custom-prelude.md`,
`record-patterns.md`, `multiline-strings.md`). The points that shape the sketches below: every
cabal stanza uses the GHC2024 language edition and a shared `common` stanza (`import: common`)
enabling `DeriveAnyClass`, `DuplicateRecordFields`, `OverloadedLabels`, `OverloadedStrings`, and
`MultilineStrings`, so `Kansoku.Api.OpenApi` inherits those (no per-file
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

Scope: at the end of this milestone the code compiles, the author libraries are wired into the
API package, `Kansoku.Api.OpenApi.kansokuOpenApi :: OpenApi` exists, the artifact executable and
staleness gate are present, and the four conformance categories pass. No HTTP serving yet.

First, wire `openapi-hs` and `servant-openapi-hs` into the `kansoku-api` package, which owns the
route records and can generate their contract without depending on server code. The repository
pins the compatible released pair at `4.1.0` in `cabal.project`; `kansoku-api.cabal` lists both
libraries in its own `build-depends`.

Second, confirm the combined API is the exact NamedRoutes record served by the server:

```haskell
data KansokuAPI mode = KansokuAPI
  { ingest :: mode :- NamedRoutes IngestRoutes
  , metrics :: mode :- NamedRoutes MetricsRoutes
  }
  deriving stock (Generic)

kansokuAPI :: Proxy (NamedRoutes KansokuAPI)
kansokuAPI = Proxy
```

Third, place the generator in `kansoku-api/src/Kansoku/Api/OpenApi.hs`, module
`Kansoku.Api.OpenApi`. Add the `ToSchema` instances for every wire DTO and `ToParamSchema` for
`TimeGrain`, mirroring the actual JSON enum/newtype representations. Generate from `kansokuAPI`
directly and assign deterministic operation IDs from method plus path:

```haskell
module Kansoku.Api.OpenApi (kansokuOpenApi) where

import Data.OpenApi qualified as O
import Kansoku.Api (kansokuAPI)
import Kansoku.Prelude
import Servant.OpenApi (toOpenApi)

kansokuOpenApi :: O.OpenApi
kansokuOpenApi =
  toOpenApi kansokuAPI
    & O.info . O.title .~ "Kansoku Analytics API"
    & O.info . O.version .~ "1.0.0"
    & O.info . O.description
      ?~ "HTTP ingestion and typed metrics query API for the Kansoku analytics service."
    & O.applyTags
      [ O.Tag "ingestion" (Just "Event ingestion endpoints") Nothing
      , O.Tag "metrics" (Just "Typed metric query endpoints") Nothing
      ]
    & withOperationIds
```

Because the generator consumes `kansokuAPI`, changing the served umbrella changes the document
and the conformance tests together. There is no placeholder metrics API and no second proxy.

Fourth, if the Generic-derived schema for `AnalyticsEvent` does not match its hand-written JSON
field names (for example if `Kansoku.Event` uses an aeson `fieldLabelModifier` to drop a record
prefix or camel-case a field), give the `ToSchema` instance matching `SchemaOptions` so the
schema's property names equal the JSON keys. `openapi-hs` exposes `Data.OpenApi.SchemaOptions`
and `genericDeclareNamedSchema` for this; consult `src/Data/OpenApi/SchemaOptions.hs` and mirror
whatever `Options` the `ToJSON`/`FromJSON` instances use. Record any such adjustment in
Surprises & Discoveries with the before/after property names as evidence.

Fifth, extend `kansoku-core/test/Kansoku/OpenApiSpec.hs` with four conformance categories:

- The documented paths are exactly the thirteen analytics paths served by the sentinel
  `KansokuAPI` record, and every operation has a stable method/path-derived operation ID.
- Every operation has exactly one success status (`200` for metrics, `202` for ingestion) plus
  `400`, `404`, and `503`, all using the shared response algebra.
- Representative JSON values for every wire DTO validate against their generated schemas.
- The WAI wrapper allowlist is exactly `/health`, `/ready`, and `/openapi.json`; those paths are
  not in the Servant document, while every documented path routes through the sentinel server.

Sixth, add the `kansoku-openapi` executable in `kansoku-api/app/OpenApi.hs`. It pretty-encodes
`kansokuOpenApi` deterministically to `docs/api/openapi.json` with a trailing newline. Add:

```just
openapi:
    cabal run kansoku-openapi

openapi-check:
    cabal run kansoku-openapi
    git diff --exit-code docs/api/openapi.json
```

Acceptance for Milestone 1: `cabal build all`, `cabal test all`, and `just openapi-check` pass;
running the generator twice yields byte-identical `docs/api/openapi.json`.

### Milestone 2 — Serve GET /openapi.json and verify with curl/jq

Scope: at the end of this milestone the running `kansoku-server` answers `GET /openapi.json`
with the document from Milestone 1, verified over HTTP.

Keep operational metadata outside the analytics NamedRoutes contract. In
`Kansoku.Server.waiWrapper`, answer `/openapi.json` from the same generator value before
delegating all other paths to the single Servant application:

```haskell
waiWrapper :: ReadyProbe -> Application -> Application
waiWrapper probe inner req respond =
  case pathInfo req of
    ["health"] -> healthApp req respond
    ["ready"] -> readyApp probe req respond
    ["openapi.json"] ->
      respond
        (responseLBS status200 [(hContentType, "application/json")] (Aeson.encode kansokuOpenApi))
    _ -> inner req respond
```

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

Step 1 — locate and read the two author libraries through Mori so you are working from their
real APIs, not memory:

```bash
mori registry show shinzui/openapi-hs --full
mori registry show shinzui/servant-openapi-hs --full
mori registry docs shinzui/openapi-hs
mori registry docs shinzui/servant-openapi-hs
```

Read the returned source paths for the `HasOpenApi` instances for NamedRoutes and MultiVerb and
the `toOpenApi :: Proxy api -> OpenApi` entry point.

Step 2 — confirm the released pair and API package wiring:

```bash
rg -n "openapi-hs|servant-openapi-hs" cabal.project kansoku-api/kansoku-api.cabal
```

Expected: `cabal.project` constrains both to `4.1.0`; `kansoku-api.cabal` lists both libraries,
exposes `Kansoku.Api.OpenApi`, and declares `kansoku-openapi`.

Step 3 — confirm the generator consumes the served proxy and the server uses the same value:

```bash
rg -n "kansokuAPI|kansokuOpenApi|openapi.json" \
  kansoku-api/src/Kansoku/Api.hs \
  kansoku-api/src/Kansoku/Api/OpenApi.hs \
  kansoku-core/src/Kansoku/Server.hs
```

Step 4 — build, test, and run the deterministic artifact gate:

```bash
cabal build all
cabal test all
just openapi-check
```

Expected: the conformance test reports the exact path/operation-ID, response-tail, DTO schema,
and WAI allowlist categories green; `git diff --exit-code docs/api/openapi.json` exits zero.

Step 5 — prove regeneration is deterministic by hashing two successive outputs:

```bash
just openapi
shasum -a 256 docs/api/openapi.json
just openapi
shasum -a 256 docs/api/openapi.json
```

Expected: identical SHA-256 values.

Step 6 (Milestone 2) — keep the `/openapi.json` WAI branch, rebuild, then start the server:

```bash
cabal run kansoku-server
```

In another terminal, verify:

```bash
curl -s http://localhost:8080/openapi.json | jq '.openapi'
curl -s http://localhost:8080/openapi.json | jq '.paths | keys'
curl -s http://localhost:8080/openapi.json | jq '.components.schemas | keys'
```

Expected output starts with:

```json
"3.1.0"
```

The paths list contains exactly the thirteen analytics routes, and the schema list includes the
event, ingestion, metric, enum/newtype, and shared error-envelope schemas pinned by the test.

If the port differs from 8080, read it from `Kansoku.Config` or the server's startup log line
and substitute it in the URLs.

Step 7 (optional, Milestone 3) — add the `/docs` route, rebuild, run the server, and open
`http://localhost:8080/docs` in a browser to confirm the endpoints render.


## Validation and Acceptance

The plan is accepted when both required milestones pass.

Milestone 1 is accepted when `cabal build all`, `cabal test all`, and `just openapi-check` pass,
two successive generations have the same SHA-256, and the four conformance categories are green:
exact served/documented paths plus operation IDs; exact success plus 400/404/503 responses;
DTO JSON/schema agreement; and the WAI-only operational allowlist.

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

Re-running `cabal build all`, `cabal test all`, and `just openapi` is safe. The generator
deterministically overwrites only `docs/api/openapi.json`; `just openapi-check` exposes drift
through a read-only Git diff check. Starting the server is safe to repeat after stopping any
process already holding its port. A missing schema or conformance failure names the contract
surface that must be corrected; regenerate and rerun the gate after the fix.


## Interfaces and Dependencies

**Libraries used and why.**

- `openapi-hs` (module namespace `Data.OpenApi.*`): supplies the `OpenApi` document type, its `ToJSON`/`FromJSON`
  instances (so it serializes to and from JSON), the `ToSchema` class for per-type schemas, and
  the enrichment lenses/helpers (`info . title`, `info . version`, `info . description`,
  `servers`, `applyTags`, the `Tag` constructor, `SchemaOptions`). It is the data model the
  document is made of.
- `servant-openapi-hs` (module `Servant.OpenApi`):
  supplies `toOpenApi`, which walks the servant API type and produces the `OpenApi` value. This
  is the bridge from "servant type" to "OpenAPI document".
- `servant` (already a dependency via `kansoku-api`): the API combinators the types are built
  from.

The compatible released pair is pinned in `cabal.project`:

```text
constraints:
  openapi-hs ==4.1.0,
  servant-openapi-hs ==4.1.0
```

**`kansoku-api.cabal` edits.** The API library owns the generator. Its `library` stanza exposes
`Kansoku.Api.OpenApi` and depends on:

```text
    , openapi-hs
    , servant-openapi-hs
    , lens
```

The same package declares the deterministic artifact executable:

```text
executable kansoku-openapi
  main-is: OpenApi.hs
  hs-source-dirs: app
  build-depends: aeson-pretty, base, bytestring, directory, kansoku-api
```

**Module and signatures that must exist at the end of Milestone 1.**

- `Kansoku.Api` exporting the record and exact proxy:

  ```haskell
  data KansokuAPI mode = KansokuAPI
    { ingest :: mode :- NamedRoutes IngestRoutes
    , metrics :: mode :- NamedRoutes MetricsRoutes
    }

  kansokuAPI :: Proxy (NamedRoutes KansokuAPI)
  ```

- `kansoku-api/src/Kansoku/Api/OpenApi.hs`, exporting:

  ```haskell
  kansokuOpenApi :: Data.OpenApi.OpenApi
  ```

  built as `toOpenApi kansokuAPI`, enriched with metadata, tags, and stable operation IDs.

- The schema instances cover the event ID newtypes, `AnalyticsEvent`, `EventSource`, ingestion
  acks, metric DTOs, `TimeGrain`, and `ErrorEnvelopeWire`; `TimeGrain` also has `ToParamSchema`.

  ```haskell
  instance O.ToSchema AnalyticsEvent
  instance O.ToSchema EventSource
  instance O.ToSchema IngestAck
  instance O.ToSchema BatchAck
  instance O.ToSchema MetricPoint
  instance O.ToSchema MetricResult
  instance O.ToSchema ErrorEnvelopeWire
  instance O.ToSchema TimeGrain
  instance O.ToParamSchema TimeGrain
  ```

- The entry point relied upon, quoted from `servant-openapi-hs`
  (`src/Servant/OpenApi/Internal.hs:79`):

  ```haskell
  class HasOpenApi api where
    toOpenApi :: Proxy api -> OpenApi
  ```

**WAI route that must exist at the end of Milestone 2.** In `Kansoku.Server.waiWrapper`:

```haskell
["openapi.json"] ->
  respond (responseLBS status200 [(hContentType, "application/json")] (Aeson.encode kansokuOpenApi))
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

- 2026-07-18 — **Plan 9 alignment.** Updated the live generator contract to
  `kansokuAPI :: Proxy (NamedRoutes KansokuAPI)` and `Kansoku.Api.OpenApi.kansokuOpenApi`;
  documented the deterministic `kansoku-openapi` artifact executable, `just openapi-check`,
  the four conformance categories, and WAI-only `/openapi.json` serving. Historical Progress
  entries remain unchanged.
