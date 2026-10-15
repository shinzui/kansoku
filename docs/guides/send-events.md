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
property types, required fields, and constraints become enforced. Catalog version 2 publishes
string `minLength` and numeric `minimum` alongside regular-expression `pattern`.

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

`POST /v1/batch` accepts a JSON array. A syntactically valid batch always returns HTTP 202,
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

Do not retry entries in `rejected`: Kansoku has finished processing that batch, and a retry would
duplicate accepted events. Correct rejected payloads and send them as new submissions. A body
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
- `email_sha256`

Each value must be 1–256 printable, non-space ASCII characters. `anonymousId` already acts as an
implicit cookie signal, so do not duplicate it in `identifiers`. On events with an explicit
`userId`, mapped identifiers become account-scoped identity evidence. Cookie bindings from
`anonymousId` are created only by `identify` and `alias`. Fingerprint evidence expires after 180
days; see the [identity deletion runbook](../runbooks/identity-data-deletion.md) for erasure and
raw fingerprint retention.

## Delivery and retries

Kansoku enqueues accepted events in PostgreSQL and returns before ClickHouse insertion. The
queue-to-ClickHouse boundary is at-least-once; `eventId` provides storage idempotency. Keep the
same `eventId` when retrying an uncertain request.

Retry transient network failures, HTTP 503 responses whose problem document has `retryable: true`, and
an interrupted request for which no response was received. Use bounded exponential backoff.
Do not automatically retry HTTP 400, 401, 403, 404, or 413, or per-event batch rejections.

Browser CORS applies to `/v1/*`. The default allows every origin; production deployments should
set an exact allowlist with `KANSOKU_CORS_ORIGINS`. This is browser policy, not authentication.

## Haskell producers

The bundled client adds buffering, batching, retries, and helpers around this contract. See
[Use the Haskell SDK](haskell-sdk.md).

[Documentation index](../README.md)
