# ADR 0001: SDK-grade ingest contract boundaries

- Status: Accepted
- Date: 2026-07-19
- Deciders: Kansoku maintainers

## Context

Kansoku is the portfolio's first-party analytics service. Browser SDKs and backend producers
will buffer and batch events, so the ingest API must have stable retry semantics, browser access,
and resource bounds before those clients ship. The original contract rejected an entire batch
when one event was invalid, exposed no CORS policy, and placed no limit on body or batch size.

The API uses one Servant `KansokuResult` algebra and shared MultiVerb error tail across analytics
routes. Operational routes remain WAI-level, while `/v1/*` ingest and `/metrics/*` queries share
the Servant application. A later authentication initiative will add public write keys or service
tokens to ingest and protected read credentials to metrics.

## Decision

`POST /v1/batch` partially accepts any syntactically valid batch. It enqueues valid events and
returns HTTP 202 with an accepted count plus zero-based rejection records for invalid events.
Even an all-invalid parsed batch returns 202. HTTP 400 is reserved for a body that cannot be
decoded as the batch type. Rejection text is human-facing; clients identify rejected submissions
by index and optional event ID.

SDKs treat a 202 response as the end of that delivery attempt. They do not retry rejected events
and account for them as dropped. Oversized requests are also permanent client errors and are not
retried.

CORS applies only to `/v1/*`. Origins are unrestricted by default and may be replaced by an exact
operator allowlist. `Content-Type`, `X-Api-Key`, and `Authorization` are preflight-approved so the
future authentication change does not require another browser contract migration. The metrics
query surface is not CORS-opened.

The analytics application has a configurable positive request-body cap, defaulting to 5 MiB, and
the batch handler has a configurable positive event-count cap, defaulting to 500. Both violations
return HTTP 413 with the standard non-retryable JSON error envelope. CORS wraps the size-limit
middleware so browser JavaScript can read the 413 response. The body middleware rejects known
oversized lengths immediately and guards chunked bodies incrementally as the application reads
them.

HTTP 413 is part of the shared MultiVerb error tail, not an ingest-only fork. This keeps
`KansokuResult` conversion total across every route and keeps the served API, generic Haskell
client, and generated OpenAPI document derived from one response algebra.

## Alternatives considered

- Rejecting an entire batch with HTTP 400 was rejected because one poison event can wedge every
  valid event behind it in a retrying client buffer.
- HTTP 207 was rejected because it adds WebDAV-specific handling without improving delivery
  semantics; 202 already means the parsed flush is finished.
- Opening CORS on the whole service was rejected because browser producers need ingest access,
  while metrics reads should remain same-origin or server-mediated and authenticated.
- Putting the size middleware outside CORS was rejected because browsers would receive an opaque
  network failure instead of a readable 413 envelope.
- Route-specific body limits were rejected in favor of one operational knob plus the semantic
  batch-count limit.
- Adding 413 only to ingest response types was rejected because it would break the total shared
  `KansokuResult`/`AsUnion` mapping.

## Consequences

Future SDKs may safely drop individual rejections without retrying an already-processed batch.
Producers must split batches or reduce event size after a 413. Operators can restrict browser
origins, but origin restrictions are not treated as authentication; EP-15 must still authenticate
write and read paths and scope metric queries.

Every analytics operation documents the shared 413 alternative even when its usual request has
no body. This is a deliberate cost of preserving one total response algebra. Changes to these
semantics must update the server, `kansoku-client`, OpenAPI conformance tests and artifact, and
this ADR together.
