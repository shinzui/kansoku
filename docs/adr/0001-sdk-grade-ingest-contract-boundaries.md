---
type: Architecture Decision Record
title: SDK-grade ingest contract boundaries
description: Accept syntactically valid ingest batches partially, cap request size and count, and scope CORS to /v1/* so SDKs get stable retry semantics.
timestamp: 2026-10-15T16:24:04Z
generated:
  by: human:kansoku-maintainers
  at: 2026-07-19T00:00:00Z
docId: ADR-1
status: Accepted
date: 2026-07-19
---

# ADR 0001: SDK-grade ingest contract boundaries

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
query surface is not CORS-opened. A disallowed origin is rejected by wai-cors with its
400 HTML response and no allow-origin header, before the inner problem boundary.
Allowed-origin API failures retain readable problem JSON and CORS headers.

The analytics application has a configurable positive request-body cap, defaulting to 5 MiB, and
the batch handler has a configurable positive event-count cap, defaulting to 500. Both violations
return HTTP 413 with the standard non-retryable RFC 9457 problem document. CORS wraps the size-limit
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
  network failure instead of a readable 413 problem.
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

The coordinated problem migration is recorded in [ADR-8](0008-rfc9457-problem-details-and-generated-client-media.md).
It changes error media and fields while preserving partial 202 batches, permanent 413s and CORS ordering.

## Ingest normalization and diagnostic ownership

Before validation, the authenticated account and server receive time override client values.
Past occurrences remain unchanged. Future events with `sentAt >= occurredAt` preserve client
elapsed time by storing `receivedAt - (sentAt - occurredAt)`. Otherwise offsets within a
nonnegative configurable tolerance (default one day) clamp to server time; zero disables
clamping. Larger offsets fail validation. The resulting occurrence and receive timestamps
must be in `[1970-01-01, 2100-01-01)` UTC. This conservative range avoids the native driver's
unsigned negative-epoch representation and fits the deployed timestamp/partition types; native
boundary roundtrips protect it. Send timestamps are consumed before queue serialization.

The HTTP request representation preserves the original event object independently of its
parsed, normalized queue record. Optional quarantine stores only declared-schema rejections,
with authenticated account, fixed reason codes and transport. It never stores request
credentials or a transport envelope. One separate 250 ms operation bounds all diagnostic
writes for a request; diagnostic failure cannot undo accepted queue work, and asynchronous
cancellation escapes. Payloads larger than the configured byte cap become an empty object
with truncation/size metadata. The supervised cleanup runs at startup and hourly, enforcing
14-day default retention and a 10000-row default per-account cap, including after capture is
disabled. Failed cleanup retries each minute; expiry is eventual, not a hard deadline.
