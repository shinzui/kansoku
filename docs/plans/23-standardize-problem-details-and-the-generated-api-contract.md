---
id: 23
slug: standardize-problem-details-and-the-generated-api-contract
title: "Standardize problem details and the generated API contract"
kind: exec-plan
created_at: 2026-10-15T03:10:58Z
intention: "intention_01m4yrkpeve8c8aktyqnqdftv0"
master_plan: "docs/masterplans/4-align-kansoku-with-relevant-haskell-jitsurei-practices.md"
provenance:
  created_by:
    model: "gpt-6.1-sol"
    harness: "codex-cli"
    at: 2026-10-15T03:10:58Z
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-15T03:29:26Z
      verdict: "comments"
      note: "Contract migration is coherent; clarify that about:blank titles use the HTTP status phrase rather than distinct per-code titles."
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-15T03:32:46Z
      mode: "implement"
      note: "Implement the RFC 9457 contract and released OpenAPI cohort; about:blank titles use status phrases."
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-15T03:37:31Z
      mode: "update"
      note: "Clarify status-phrase titles for about:blank and matching catalog/schema acceptance."
---

# Standardize problem details and the generated API contract

This ExecPlan is a living document. Keep its progress, discoveries, decisions and outcomes
current. Update durable ADRs in the same implementation change.


## Purpose / Big Picture

Every JSON API error will identify its status and stable code under `application/problem+json`.
Clients will decode these errors consistently, and the generated OpenAPI document will describe
the bodies actually returned, including authentication failures. A generated Haskell client
round trip and public HTTP assertions will demonstrate the change.


## Progress

- [ ] M1: Compatible released OpenAPI packages build in Cabal and Nix, and a generated client decodes a representative typed problem response.
- [x] (2026-10-15) M2: Handler, authentication, parser, request-limit and routing failures use the common problem contract. Real HTTP checks cover 400/401/403/404/405/406/413/415/500/503, CORS, chunked limits, cancellation and schema agreement; 157 generated error responses have problem media and schema references.
- [x] (2026-10-15) M3: SDK retry and partial-batch behavior pass (14 examples, one optional live-server pending); generated artifacts and migration guides agree. Event contracts remain byte-for-byte unchanged. ADR-1/ADR-3 and accepted ADR-8 record the contract; strict ADR validation passes.


## Surprises & Discoveries

The generated client needs both endpoint-level admission of JSON/problem JSON and explicit
per-response encoders. A real Warp round trip now decodes typed 400 and 202 alternatives;
auth 401/403 are explicitly decoded from `FailureResponse` bodies rather than described as
typed handler results.

Raising the Hackage index-state to the locally verified 2026-10-14T22:38:45Z permits the
released 5.0.0/5.1.0 pair. Nix `callHackageDirect` needs unpacked source hashes, obtained with
`nix-prefetch-url --unpack`, rather than archive byte hashes. Existing explicit runtime pins
are preserved.

The SDK previously retried every Servant client error, including pre-handler 401s. Permanent
4xx and decode/content-type failures now stop immediately; connection errors and retryable
server failures retain bounded backoff. Deterministic tests prove the 401 attempt count is one.
Live database and configured-server checks remain optional/pending in this child's test run;
full executable/storage acceptance belongs to EP-28.


## Decision Log

On 2026-10-15, choose an atomic server/API/client contract migration, preserving existing code
strings and status meanings. Do not retain a second legacy response dialect. Existing successful
payloads, partial batch acknowledgements and credential semantics remain unchanged.

On 2026-10-15, require a generated-client round trip before broad conversion. Route-level media
admission and per-response encoding are separate parts of Servant's contract.

On 2026-10-15, clarify the reviewed title policy: about:blank uses the HTTP status phrase,
while stable extension codes retain the service-specific distinction between failures.


## Outcomes & Retrospective

The RFC 9457 migration, leaf authentication, explicit response media, complete generated error
schemas, SDK retry fixes and migration guides are implemented. The Cabal build and deterministic
core/client checks pass. Nix server/client acceptance is still running; M1 remains open until
both outputs build. Durable decisions have been distilled into ADR-8 and the affected ADR-1/ADR-3.
The current user scope is EP-23 only; other child plans are not implementation work in this turn.


## Context and Orientation

Work from the repository root. `kansoku-api/src/Kansoku/Api/Response.hs` defines the old
`ErrorEnvelopeWire`, `KansokuResult`, response lists and handwritten `AsUnion` mappings.
A response list associates each result alternative with an HTTP status. `MultiVerb` is Servant's
mechanism for describing several such responses in one route. `kansoku-api/src/Kansoku/Api.hs`,
`kansoku-api/src/Kansoku/Ingest/Api.hs` and `kansoku-api/src/Kansoku/Metrics/Api.hs` define the actual served route types.
`kansoku-core/src/Kansoku/Server.hs` installs error formatters and body limits;
`kansoku-core/src/Kansoku/Auth/Handler.hs` throws 401, 403 and 503 envelopes before handlers.
`kansoku-api/src/Kansoku/Api/OpenApi.hs` currently documents auth statuses without body content.
The checked-in `docs/api/openapi.json` has 18 operations, 17 schema-less 401 responses and
15 schema-less 403 responses at the audited revision.

`kansoku-client/src/Kansoku/Client.hs` handles batch delivery and retry decisions;
`kansoku-client/src/Kansoku/Client/Metrics.hs` exposes typed metric clients. Tests include
`kansoku-core/test/Kansoku/OpenApiSpec.hs`, `kansoku-core/test/Kansoku/Metrics/RoutingSpec.hs`, authentication,
CORS and limits specs, and `kansoku-client/test/Spec.hs`.

Local ADRs [ADR 1](../adr/0001-sdk-grade-ingest-contract-boundaries.md) and
[ADR 3](../adr/0003-api-key-authentication-and-account-scoped-analytics.md) require partial 202
batches, permanent oversized-request failures, browser-readable errors, immediate revocation,
header precedence and account isolation. Preserve those semantics while changing the envelope.
[ADR 2](../adr/0002-pipeline-observability-readiness-and-writer-recovery.md) keeps status probes and
Prometheus separate from public analytics. Probes are status reports, exempt from problem details.

Governing references are `mori://shinzui/haskell-jitsurei/docs/api-rfc9457-problem-details`,
`mori://shinzui/haskell-jitsurei/docs/api-servant-routes`, and
`mori://shinzui/haskell-jitsurei/docs/api-openapi-from-types`. The resolved precedent
`mori://shinzui/kotei/okf/adrs/concepts/ADR-1` explains generated-client content negotiation:
route admission includes JSON and ProblemJSON; individual successes explicitly use JSON.


## Plan of Work

### M1: Establish the media contract on the released cohort

Replace the 4.1.0 OpenAPI pair in `cabal.project` and `flake.module.nix` with released
`openapi-hs` 5.0.0 and `servant-openapi-hs` 5.1.0, verified against Hackage preferred-version
endpoints and upstream tags on 2026-10-15. Raise the index-state to a verified timestamp covering
these releases; keep every other runtime pin unchanged unless resolution requires a documented
compatibility adjustment. Inspect the Mori-discovered sources at `mori://shinzui/openapi-hs`
and `mori://shinzui/servant-openapi-hs`, especially their changelogs: 5.1 fixes per-response
media types and 5.0 replaces insertion-ordered container imports with compatibility modules.
Recheck registry and tags if implementation is delayed. Use real fetched hashes, never placeholders.

Introduce `ProblemDetails` and `ProblemJSON` in `Kansoku.Api.Response`, with fields on the wire
exactly `type`, `title`, `status`, `detail`, `code`, `retryable`. Use `about:blank` for type
and the recommended HTTP status phrase for title, as specified by
[RFC 9457 section 4.2.1](https://www.rfc-editor.org/rfc/rfc9457.html#section-4.2.1).
For example, all 400 codes share `Bad Request`, and all 404 codes share `Not Found`.
Keep code-specific meaning in `code` and `detail`; titles remain stable per code because each
catalog code has one status. Use one shared codec/schema field mapping for the reserved name `type`.
Keep `KansokuResult` as the public result algebra with problem payloads. Admit both content types
on failing routes, use `RespondAs JSON` for successes and `RespondAs ProblemJSON` for failures,
and retain explicit `AsUnion` mappings with the empty-case witness. Prove a generated
`genericClient` call against a real Warp listener returns the typed 400 constructor; it must not
fail with UnsupportedContentType or DecodeFailure. This is the early integration gate.

### M2: Convert every JSON failure producer

Inventory codes in API/core sources and centralize their status, title and retry policy in one
catalog next to the response type. Convert ingest/metrics handlers, authentication rendering,
Servant parser/not-found formatters, and the size-limit middleware. Preserve WWW-Authenticate
on 401 and CORS headers on ingest errors. Render empty framework 405, 406 and 415 responses as
problems at one narrow response boundary, preserving status-specific headers and not consuming
or rewriting existing response bodies. Unexpected synchronous exceptions become a generic 500
problem at one exception boundary inside future access logging; asynchronous cancellation must
propagate. Keep the 500 cause private in application logs, not in detail.

Move ingest and metrics authentication onto each protected leaf route, rather than wrapping the
whole subrecord in `Kansoku.Api`. Adapt named server/client construction to the resulting
per-operation auth arguments. Keep `/v1/schemas` public. Document auth 401/403 response content
and headers in the custom HasOpenApi instances using the same problem schema and catalog.
The route type, custom auth documentation and runtime now cover complementary failure sources.

### M3: Preserve clients and publish the new contract

Update SDK decoding and tests so typed permanent problems are dropped and retryable 503s retain
existing retry/backoff behavior. Batch 202 rejections remain acknowledgement data, not problem
documents. Replace old field assertions throughout core/client specs. Require error schema and
media-type assertions for every non-exempt response, actual 401/403 wire/schema conformance,
codec-key tests, stable code/title/status agreement, and indistinguishable unknown/revoked
credentials. Regenerate OpenAPI from the served proxy and update the guides, examples and affected
ADRs. Explain this wire/source change in `docs/guides/haskell-sdk.md` and
`docs/guides/send-events.md`; retain no implicit dual decoder unless actual consumers require it
and that necessity is recorded before changing acceptance.


## Concrete Steps

Run commands from the repository root, inside `nix develop`. First discover dependencies:

```bash
mori registry search openapi
mori registry show shinzui/openapi-hs --full
mori registry docs shinzui/openapi-hs
mori registry show shinzui/servant-openapi-hs --full
curl -fsSL https://hackage.haskell.org/package/openapi-hs/preferred.json
curl -fsSL https://hackage.haskell.org/package/servant-openapi-hs/preferred.json
```

After implementation, execute:

```bash
cabal build all --enable-tests
cabal test kansoku-core-test --test-options='--match Kansoku.Api.OpenApi.kansokuOpenApi' --test-show-details=direct
cabal test kansoku-client-test --test-show-details=direct
just openapi
just contracts
nix build .#kansoku-server .#kansoku-client
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
```

Expected results are zero build/test failures, a documented problem schema and problem content
on all API errors, unchanged event contracts, and successful Nix builds on the same dependency
cohort. A missing offline cache is an environment prerequisite to fix, not passing evidence.


## Validation and Acceptance

Pin 400 malformed bodies/queries, 401 missing/invalid/revoked credentials, 403 write-key metric
reads, 404 unknown routes/placeholders, 413 length and chunked-body limits, framework 405/406/415,
503 auth/queue/query outages, and sanitized unexpected 500. Test only appropriate status/route
pairs; do not manufacture unreachable handler faults. Assert HTTP status equals problem.status,
code remains stable, retryable is correct, and Content-Type is application/problem+json.
Assert different codes with the same status share its status-phrase title, including malformed
request and query-validation failures; examples and generated schemas must agree with the catalog.
Generated clients must decode typed success and error results. Auth rejections occur before
MultiVerb handlers and may remain Servant ClientError failures; tests must explicitly decode
those bodies and verify their documented schema instead of falsely claiming typed auth results.
An Accept header listing JSON and problem JSON must work end to end.

Conformance tests must still prove exact public paths, unique operation IDs, operation security,
DTO schema agreement and sentinel dispatch. Ingest CORS tests must read the new error body.
Do not require external databases for deterministic formatter and client round trips; full
storage acceptance belongs to the final integration child.


## Idempotence and Recovery

Generators are deterministic and repeatable. Do not hand-edit generated JSON. Keep server,
client, schemas, guides and dependency edits in coherent commits so rollback restores one
contract. Database schema and stored events do not change. Follow the profiled ADR workflow,
including log/index updates, when recording the accepted migration.


## Interfaces and Dependencies

No hard child prerequisite. This plan defines `Kansoku.Api.Response.ProblemDetails`,
`ProblemJSON`, the problem catalog and the revised response aliases for all later work.
Health remains an explicit exemption. Query limits may add codes later without changing the
shape. Keep package/API dependencies on published releases; cross-repository references use
canonical Mori URIs. Commits carry MasterPlan, ExecPlan and Intention trailers matching frontmatter.
