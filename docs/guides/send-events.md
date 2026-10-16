---
type: Guide
title: "Send events"
description: "Send authenticated single, batch or beacon events with governed schemas, identity signals, immutable event IDs and correct retry handling."
docId: DOC-11
tags: ["ingestion", "events", "schemas", "identity"]
generated:
  by: process:codex
  at: "2026-10-16T03:45:04Z"
---

# Send events

Kansoku accepts one event at `POST /v1/events` or an array at `POST /v1/batch`. Both routes
require a write key (`ksk_w_…`) or service token (`ksk_s_…`) in either header:

```http
Authorization: Bearer ksk_w_…
```

```http
X-Api-Key: ksk_w_…
```

If both are present, `Authorization` takes precedence, including when it is malformed. Missing,
unknown, or revoked credentials return HTTP 401. Credentials are account-scoped: Kansoku
overwrites the event's optional `accountId` with the authenticated account.

## Browser exit beacon

`POST /v1/beacon` accepts UTF-8 JSON with either `text/plain` (optional UTF-8 charset)
or `application/json`. The envelope is `{"writeKey":"ksk_w_…","batch":[…]}`.
Only public write keys are permitted. Unknown/revoked keys return 401; a valid service token
returns 403. Missing/invalid body keys, duplicate envelope keys (including escaped spellings),
or any `Authorization`/`X-Api-Key` header return 400. Header credentials never replace the body key.
The decoder bounds keys to 256 printable, non-space ASCII characters and reports generic errors.

```javascript
const body = JSON.stringify({ writeKey, batch: events });
const queued = navigator.sendBeacon(
  `${baseUrl}/v1/beacon`,
  new Blob([body], { type: "text/plain;charset=UTF-8" }),
);
```

No credential belongs in a URL. `text/plain` avoids a CORS preflight; configured origin
allowlists still reject disallowed simple POSTs before any ingest side effect. Missing Origin
is allowed for nonbrowser producers. Origin is forgeable and does not replace the public key.
The same byte/count limits, per-key rate bucket, immutable acceptance ledger, normalization,
enrichment, partial 202 acknowledgement and 429 `Retry-After` apply to all three ingest routes.
Only individual invalid events enter quarantine; the credential envelope is discarded.

`queued === true` means browser queue admission, with no readable HTTP result. It cannot tell
you whether the server accepted, rejected, throttled or even received the events. Keep pending
event IDs for an acknowledged retry; identical retries are safe. False or a missing API may
fall back to keepalive fetch, subject to the browser's shared in-flight quota. Budget the
complete serialized UTF-8 envelope conservatively below 60 KiB across outstanding exit calls;
splitting cannot grant another independent allowance. A page-leave event is best effort and
cannot guarantee a complete duration measurement.

## Event shape

The machine-readable field reference is the `AnalyticsEvent` schema in
[the OpenAPI document](../api/openapi.json). Every event requires:

- `eventId`: a non-empty producer-generated idempotency key;
- `eventName`: a non-empty event name;
- `source`: `web`, `app`, `service`, `worker`, `email`, or `agent`;
- `occurredAt` and `receivedAt`: JSON UTC timestamps;
- `properties` and `context`: JSON objects, including `{}` when empty.

Kansoku replaces `receivedAt` with its clock at ingest. Past occurrences remain unchanged.
For a future occurrence, optional `sentAt` corrects clock skew when `sentAt >= occurredAt`:
the stored occurrence is `receivedAt - (sentAt - occurredAt)`. Otherwise a future offset up to
`KANSOKU_INGEST_FUTURE_TOLERANCE_SEC` (86400 seconds by default) is clamped to server time.
Larger offsets are rejected; zero disables clamping. `sentAt` is consumed at ingest and is not
stored in the event queue or ClickHouse. Resulting timestamps must be in the conservative UTC
range `[1970-01-01T00:00:00Z, 2100-01-01T00:00:00Z)`; persistence keeps millisecond precision. The remaining optional fields describe source service, user and
session identity, URL and campaign attribution, event causation, source-stream position, and
schema version. Unknown JSON fields are currently ignored, but producers should not rely on
them being stored.

This complete payload declares a known versioned event:

```json
{
  "eventId": "01j2y8m8f5q6c3v4b7n9p0r2st",
  "eventName": "page_view",
  "schemaVersion": 1,
  "source": "web",
  "sourceService": "marketing-site",
  "occurredAt": "2026-07-20T12:00:00Z",
  "receivedAt": "2026-07-20T12:00:00Z",
  "anonymousId": "browser-cookie-123",
  "sessionId": "session-456",
  "url": "https://example.test/pricing",
  "referrer": "https://search.example/",
  "utmSource": "newsletter",
  "utmCampaign": "launch",
  "properties": {"url": "https://example.test/pricing"},
  "context": {"locale": "en-US"}
}
```

The top-level `url` is useful to web analytics; the `properties.url` value is separately
required by version 1 of the declared `page_view` schema.

## Versioned schemas

Read the live schema catalog without a credential:

```bash
curl --fail --silent http://localhost:8080/v1/schemas | jq .
```

The same deterministic catalog is committed at
[`docs/contracts/events.json`](../contracts/events.json). For a declared event, send the exact
`schemaVersion` your producer implements. Omitting it means version 1, never the latest version.
Unknown versions and versions outside `1..65535` are rejected.

Undeclared event names are accepted without property-schema checks, provided their optional
schema version is in range. Declaring an event in Kansoku is the point at which its published
property types, required fields, and constraints become enforced. Catalog version 2 added
string `minLength` and numeric `minimum` alongside regular-expression `pattern`. Catalog version 3 also publishes the closed
`identifierKinds` vocabulary, including `email_hmac`.

`alias` v1 requires nonempty `properties.previousId` and `properties.newId` matching top-level
`anonymousId` and `userId`. It binds an anonymous identifier to a user. `group` v1 requires
a nonempty top-level `organizationId` and stamps organization context. `page_leave` v1
requires numeric `properties.durationMs >= 0`; it is a lifecycle event, with the page URL
at top level. See
[event schema governance](../event-schema-governance.md) before changing a released schema.

## Single-event responses

A valid single event returns HTTP 202:

```json
{"accepted": 1, "eventId": "01j2y8m8f5q6c3v4b7n9p0r2st"}
```

A validation failure returns HTTP 400 with an RFC 9457 problem document and
`Content-Type: application/problem+json`:

```json
{
  "type": "about:blank",
  "title": "Bad Request",
  "status": 400,
  "code": "validation_failed",
  "detail": "validation failed: event 'page_view': missing required property 'url'",
  "retryable": false
}
```

Treat the `code` and `retryable` fields as the machine-readable contract. The HTTP status matches `status`; `about:blank` titles use the HTTP status phrase.
Human-readable details and
batch rejection text are for people and may change.

Clients should send `Accept: application/json, application/problem+json` to admit both successful
responses and problems. This replaces the earlier `{code, message, retryable}` error shape;
update decoders to use `detail`. Success bodies and parsed-batch rejection records keep their
existing JSON shape. Authentication problems use the same schema, and 401 retains
`WWW-Authenticate: Bearer`. Browser callers can read ingest problems through CORS.

## Partial batch acceptance

`POST /v1/batch` accepts a JSON array. An admitted, in-bound syntactically valid batch returns HTTP 202,
including when every event is invalid. Valid events are enqueued; invalid events are reported by
their zero-based input index:

```json
{
  "accepted": 1,
  "rejected": [
    {
      "index": 1,
      "eventId": "bad-page-view",
      "errors": ["event 'page_view': missing required property 'url'"]
    }
  ]
}
```

Do not automatically retry entries in `rejected`: Kansoku has finished processing that batch.
Correct rejected payloads before submitting again. A body
that cannot decode as an event array returns HTTP 400 instead.

The default limits are 500 events per batch and 5 MiB per request body. Either limit can be
configured. HTTP 413 is permanent for that request; split the batch or reduce event size.

## Identity

Use top-level `userId` for an authenticated user and `anonymousId` for the browser cookie or
anonymous identity. The Haskell SDK's `identify`, `alias`, and `group` helpers emit the matching
event names, but raw HTTP producers may send those events directly.

The optional `identifiers` object accepts only these keys:

- `cookie`
- `device`
- `fingerprint`
- `email_sha256` (legacy, discouraged)
- `email_hmac`

Each value must be 1–256 printable, non-space ASCII characters. `anonymousId` already acts as an
implicit cookie signal, so do not duplicate it in `identifiers`. Explicit user IDs win.
Implicit cookie evidence is created by `identify`, `identify_once` and `alias`; mapped identifiers
bind on any event carrying an explicit `userId`.

Anonymous activity first uses same-cookie evidence in its `(account, sourceService, sessionId)`
when the nonempty session identifies exactly one user, including activity before login. A
session with two users stays ambiguous for that cookie. Without session evidence, a cookie must
identify exactly one user across retained history. Other signal kinds also require a unique
user before confidence ranking; a tie between different users at the strongest confidence stays
anonymous. Confidence is email 0.95, cookie 0.90, device 0.80 and fingerprint 0.50, not certainty.
Evidence outside the selected event window can resolve an event. Fingerprint observations expire
after 180 days by corrected event time, both in queries and eventual physical cleanup.

Canonical subjects are `user:<original id>` or `anonymous:<original id>`. Prefixing preserves
IDs containing colons or existing prefixes and prevents equal raw text in the two namespaces
collapsing. Events with neither identity remain empty and are excluded from user counts. No
arbitrary transitive user merge or unrecorded logout boundary is inferred.

For `email_hmac`, compute HMAC-SHA-256 in a trusted backend with a secret pepper from its secret
manager. Normalize the email by trimming leading/trailing ASCII whitespace (U+0009–U+000D and
U+0020), applying Unicode default lowercase without locale-specific rules, then UTF-8 encoding.
Do not apply Unicode normalization or provider-specific dot/plus rewriting. Coordinate the
Unicode/lowercase implementation across producers. Send a version prefix and lowercase hex,
for example `v1:<64 hex digits>`. The generic ASCII/length validator treats this as an opaque
identifier; it does not validate the digest's construction. Never ship the pepper to a browser.
Pepper rotation uses a new prefix and separate explicit-user observations for old/new identifiers
when a bridge is needed; equality does not cross versions automatically. `email_sha256` remains
accepted for existing producers but is discouraged because it lacks the secret pepper.

See the [identity deletion runbook](../runbooks/identity-data-deletion.md) for erasure and raw
fingerprint retention. The acceptance ledger and replayable inputs also need coordinated
lifecycle maintenance; the administrative child owns the complete fenced workflow.

## Delivery and retries

Kansoku enqueues accepted events in PostgreSQL and returns before ClickHouse insertion. The
queue-to-ClickHouse boundary is at-least-once; `eventId` provides storage idempotency. Keep the
same `eventId` when retrying an uncertain request.

An account/event ID permanently identifies its first accepted producer payload. Acceptance and
queue publication commit together in PostgreSQL. Equal retries are acknowledged without another
queue message or another timestamp normalization. Delivery `receivedAt`, `sentAt` and the ignored
producer `accountId` do not change identity; all other original fields, including unknown fields,
do. Nested object order and equivalent JSON numbers do not change the payload hash. Changing an
accepted payload requires a new event ID. Reusing its ID returns HTTP 400 `event_id_conflict` for
a single event, or an indexed rejection inside a batch's HTTP 202 acknowledgement.

Queue redelivery remains at-least-once. Canonical analytical reads and exact distinct-ID count
states prevent it changing counts, revenue or averages before background merges. The minimal
acceptance ledger has no automatic expiry; erasure tombstones also prevent restoration by retry.


Retry transient network failures, HTTP 429 or 503 responses whose problem document has `retryable: true`, and
an interrupted request for which no response was received. Use bounded exponential backoff. A 429 `rate_limited` response carries a positive whole-second
`Retry-After` header, exposed through CORS; wait at least that long. Default admission is 2000
submitted events/s with a burst of 10000 per credential per server process. Invalid events and
equal retries consume tokens. A denied request changes no acceptance, normalization, quarantine
or queue state. These limits protect admission; use a proxy for outer request/byte limits.
Do not automatically retry HTTP 400, 401, 403, 404, or 413, or per-event batch rejections.

Browser CORS applies to `/v1/*`. The default allows every origin; production deployments should
set an exact allowlist with `KANSOKU_CORS_ORIGINS`. This is browser policy, not authentication.

## Haskell producers

The bundled client adds buffering, batching, retries, and helpers around this contract. See
[Use the Haskell SDK](haskell-sdk.md).

[Documentation index](../README.md)
