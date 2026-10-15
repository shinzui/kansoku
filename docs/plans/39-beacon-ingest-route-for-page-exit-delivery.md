---
id: 39
slug: beacon-ingest-route-for-page-exit-delivery
title: "Beacon ingest route for page-exit delivery"
kind: exec-plan
created_at: 2026-10-15T14:22:40Z
intention: "intention_01m4zwwdrjesytazp5tb39fe3n"
master_plan: "docs/masterplans/5-act-on-rev-1-close-silent-loss-paths-add-metric-filters-and-enrich-web-analytics.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-15T14:22:40Z
---

# Beacon ingest route for page-exit delivery

This ExecPlan is a living document. Update its living sections and durable ADRs as work
proceeds. It is a child of
`docs/masterplans/5-act-on-rev-1-close-silent-loss-paths-add-metric-filters-and-enrich-web-analytics.md`
and acts on finding A3 of
`docs/reviews/2026-10-15-architecture-and-feature-set-against-comparable-products.md`,
promoted into scope on 2026-10-15 (MasterPlan Decision Log).


## Purpose / Big Picture

The events that happen on the way out of a page will stop being the ones most likely to be
lost. A visitor who clicks "Start free trial" and is sent to the app on another origin, who
completes signup and is redirected, who clicks an outbound link, or who closes the tab, has
the last few seconds of events still buffered in the SDK; today they go out through a
keepalive fetch that needs a CORS preflight and a custom header, and whatever does not make it
is parked in sessionStorage that the next origin cannot read. After this change the server
offers `POST /v1/beacon`, a route the browser's `navigator.sendBeacon` can reach with no
preflight and no headers, carrying the write key inside the body. The SDK will use it for the
exit flush only. Session duration and bounce rate (EP-34) become measurable for single-page
visits because a page-leave event finally has a transport designed for unload.


## Progress

- [ ] M1: `POST /v1/beacon` accepts a `text/plain` or `application/json` body holding `{"writeKey": …, "batch": […]}` from a write key, runs the batch path's validation, limits and counters, and returns the same 202 shape; service tokens, unknown keys and malformed envelopes are rejected with problems.
- [ ] M2: The transport is documented for SDK authors, OpenAPI and the Haskell client carry the operation, and a browser demo in the kansoku-ts examples delivers a page-exit batch through the route with no preflight observed.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: A dedicated route with the credential in a JSON envelope, never a query-string
  credential on the existing batch route.
  Rationale: `sendBeacon` cannot set headers and only CORS-safelisted content types avoid a
  preflight; a URL credential would be written to proxy and CDN logs. Write keys are public by
  design, so the body placement adds no exposure beyond what the page's JavaScript already
  carries, but the route must refuse service tokens so a secret can never travel this way.
  Date: 2026-10-15
- Decision: The route exists for the exit flush only; the SDK keeps batching with responses for
  everything else.
  Rationale: Browsers discard beacon responses, so per-event rejections and 413s on this route
  are invisible to the client; EP-29's server counters are the only record of them.
  Date: 2026-10-15


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

The ingest routes are a Servant NamedRoutes record in
`kansoku-api/src/Kansoku/Ingest/Api.hs`: `postEvent` and `postBatch`, both guarded by
`IngestAuth` (an `AuthProtect` tag whose handler, `ingestAuthHandler` in
`kansoku-core/src/Kansoku/Auth/Handler.hs`, reads `Authorization: Bearer` or `X-Api-Key`
and looks the hash up with `lookupApiKey` in `kansoku-core/src/Kansoku/Auth/Store.hs`),
taking `ReqBody '[JSON]` and answering through the shared `MultiVerb` response algebra
([ADR 8](../adr/0008-rfc9457-problem-details-and-generated-client-media.md)). The batch
handler in `kansoku-core/src/Kansoku/Ingest/Handler.hs` stamps the account and receive time,
partitions accepted and rejected events, and enqueues. Body and batch limits and the CORS
policy (origins from `KANSOKU_CORS_ORIGINS`, methods GET and POST, request headers
Content-Type, X-Api-Key and Authorization, max-age 3600) are applied in
`kansoku-core/src/Kansoku/Server.hs` around 194 to 199 and recorded in
[ADR 1](../adr/0001-sdk-grade-ingest-contract-boundaries.md). Credential transport rules are
in [ADR 3](../adr/0003-api-key-authentication-and-account-scoped-analytics.md); this plan adds
a single documented exception for one route.

`navigator.sendBeacon(url, data)` is the browser API that queues a POST to be delivered even
after the document unloads. It sets no custom headers, and if `data` is a `Blob` with a
content type outside the CORS-safelisted set (`text/plain`,
`application/x-www-form-urlencoded`, `multipart/form-data`) the browser must preflight, which
it cannot do for a beacon, so the request is dropped. Sending the JSON as a `text/plain` blob
is the convention Segment's and PostHog's SDKs use. The SDK's current exit behaviour (keepalive
fetch capped at 60 KiB, per-tab sessionStorage mirror) is documented in
`mori://shinzui/kansoku-ts` at `docs/guides/delivery-and-privacy.md`. No cross-repository
ADR applies.


## Plan of Work

### M1: The route

Add `BeaconEnvelope { writeKey :: Text, batch :: [AnalyticsEvent] }` to
`kansoku-api/src/Kansoku/Ingest/Api.hs` with JSON instances, and a `PlainTextJSON` content
type whose `MimeUnrender` parses the body as JSON regardless of the `text/plain` label. Add
`postBeacon :: mode :- "v1" :> "beacon" :> ReqBody '[PlainTextJSON, JSON] BeaconEnvelope :> MultiVerb …`
with the same `BatchAck` success and the shared error tail, deliberately without `IngestAuth`.
In the handler, look the envelope's key up with `lookupApiKey`; answer 401 for unknown or
revoked, 403 for a service token (the only route where a service token is refused on ingest),
then call the existing batch partition and enqueue path with the resolved principal so limits,
validation, account stamping and the EP-29 counters apply unchanged. Extend EP-29's
`kansoku_ingest_events_total` with a `transport` label (`single`, `batch`, `beacon`) if EP-29
has landed; otherwise add a `kansoku_ingest_beacon_requests_total` counter and reconcile when
it does. The body-size and batch-length middleware already cover `/v1/*`. Confirm the access
log and spans never capture the body, which already holds for every route.

### M2: Contract and demo

Regenerate OpenAPI (`just openapi`) with the envelope schema and both media types, and
regenerate the client. Write a "Page-exit delivery" section in `docs/guides/send-events.md`
that gives the envelope, the `text/plain` rule, the no-response caveat, and the 64 KiB quota.
In the kansoku-ts examples (`examples/vanilla-vite`), add a small demonstration that sends a
beacon envelope on `pagehide` using the SDK's queued events, record in this plan that the
browser's network panel shows no OPTIONS request, and leave the production SDK change to that
repository's own plan.


## Concrete Steps

```bash
cabal build all --enable-tests
cabal test kansoku-core --test-options='--match "Beacon"'
just openapi && just openapi-check
```

Manual check with the server running and a write key in `KEY`:

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/v1/beacon \
  -H 'Content-Type: text/plain' \
  --data-binary "{\"writeKey\":\"$KEY\",\"batch\":[{\"eventId\":\"beacon-1\",\"eventName\":\"page_leave\",\"source\":\"web\",\"occurredAt\":\"2026-07-20T12:00:00Z\",\"receivedAt\":\"2026-07-20T12:00:00Z\",\"properties\":{},\"context\":{}}]}"
```

Expected `202`; the same request with a service token returns `403`, and with a header-only
credential and no `writeKey` field returns `400`.


## Validation and Acceptance

1. A valid envelope with `text/plain` and with `application/json` both return 202 with
   `accepted` and `rejected` matching the batch route for the same events.
2. Unknown key 401, revoked key 401, service token 403, missing `writeKey` 400, over-limit
   batch 413, all as problem documents; none of these bodies appear in access logs.
3. A browser request from an allowed origin with a `text/plain` blob produces no preflight
   (recorded from the demo), and a disallowed origin is still refused by CORS.
4. Counters move for beacon-delivered events, labelled as beacon.
5. OpenAPI conformance tests cover the operation and its media types.


## Idempotence and Recovery

Additive route; no schema change. If the route must be withdrawn, removing it returns the
SDK to keepalive-only delivery with no data migration.


## Interfaces and Dependencies

Soft dependency on `docs/plans/29-correct-client-timestamp-skew-and-count-ingest-rejections.md`
for the counter label. Claims the `/v1/beacon` path, the `BeaconEnvelope` wire type and the
`PlainTextJSON` content type. The SDK change is tracked in `mori://shinzui/kansoku-ts`.
Update ADR 3 with the body-credential exception and its write-key-only rule, and ADR 1 with
the route's place in the CORS and limit policy.
