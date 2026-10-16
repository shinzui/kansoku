---
type: Architecture Decision Record
title: SDK-grade ingest contract boundaries
description: Accept syntactically valid ingest batches partially, cap request size and count, and scope CORS to /v1/* so SDKs get stable retry semantics.
timestamp: 2026-10-16T17:52:47Z
generated:
  by: process:codex
  at: 2026-10-16T17:52:47Z
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
the Servant application. The authentication boundary in [ADR-3](0003-api-key-authentication-and-account-scoped-analytics.md)
requires write keys or service tokens for ingest and service tokens for metrics.

## Decision

`POST /v1/batch` partially accepts an admitted, in-bound syntactically valid batch. It enqueues valid events and
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

New queue publications carry the validated public event and server enrichment in a private
version-one envelope. The ingest AuthProtect result supplies bounded request metadata to the
shared service; callers cannot choose authoritative categorical columns. Acceptance retries
retain the first enrichment and writer replay preserves it. Older development messages decode
with explicit unknown/version-zero enrichment. See
[ADR-12](0012-server-enrichment-and-first-touch-web-acquisition.md) for the enrichment,
proxy-trust and analytical population decisions under implementation.

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

## Immutable acceptance

PostgreSQL's account/event-ID ledger and PGMQ publication share one Hasql transaction on one
connection. Equal retries acknowledge without publishing or normalizing again. Different
producer content returns `event_id_conflict` (single 400 or indexed batch rejection). SHA-256
covers canonical original JSON, including unknown fields, excluding only authenticated account
overrides and receive/send clocks. Nested order and equivalent numbers canonicalize through
Aeson's lossless RFC8785 encoder. Claims roll back with failed queue sends; concurrent batches
acquire identity claims in stable key order. The minimal ledger persists indefinitely, including
erasure tombstones. It stores no full event payload.

## Shared admission

One process-owned ingest service performs credential admission after bounded decoding and before
normalization, hash/ledger work, quarantine or queue writes. Single and batch share a monotonic,
atomic token bucket per credential; the beacon adapter must use the same service. Submitted
event count includes invalid events and equal retries. Defaults are 2000 events/s and burst
10000; rate zero disables limits, otherwise burst must cover the maximum batch. State is capped
at 10000 credentials and idle eviction waits at least the full-refill interval and 60 seconds.
New credentials at capacity receive a bounded retry delay. Process-local limits require proxy
request/byte limits for a deployment-wide envelope.

Denial returns retryable 429 `rate_limited` with positive whole-second `Retry-After`, exposed by
CORS. No event outcomes, normalization or persistence occur for a denied request. The shared
response algebra, generated OpenAPI and Haskell client include this header-bearing alternative.
Native HTTP tests prove concurrent atomic admission, independent keys on one account and absence
of persistence/normalization side effects. Public beacon endpoint acceptance belongs to EP-39.

## Body-authenticated exit adaptation

`POST /v1/beacon` accepts JSON envelopes over text/plain or application/json and delegates
to the same post-auth service as event and batch ingestion. Body bytes are bounded before
decoding, batch length before admission, and all transports share the credential bucket,
acceptance ledger, enrichment, rejection counters and individual-event quarantine. The
credential envelope is never passed to event persistence or diagnostics. Duplicate root keys
are rejected before JSON object construction; both media decoders suppress producer parser
details. Generic Haskell clients exercise both declared media types.

Configured CORS origins reject simple POSTs before invoking ingest, not merely by hiding the
response. The existing CORS failure response remains 400 outside the problem boundary.
No-Origin nonbrowser requests remain permitted. Browser queueing is separate from a server
202 acknowledgement; lost exit delivery must not determine session correctness.

## Storage-compatible JSON admission

Before a new immutable acceptance claim or queue publication, shared pure event validation
checks both properties and context for duplicate flattened native JSON paths. Nested object
keys join with dots; non-null scalar and array values occupy paths. Nulls and empty objects
do not. Scalar/object prefixes may coexist. Objects inside each array element have independent
scopes, recursively through nested or mixed arrays. Ordinary noncolliding dotted keys remain
supported. For example, `{"a.b":1,"a":{"b":2}}` is rejected, while separate array elements
containing those shapes are allowed. Raw JSON remains the source of truth for producer shape;
native JSON exposes the flattened representation, which can differ from the original nesting.

New incompatible events receive permanent single 400 or indexed batch/beacon 202 rejections.
They create no ledger claim and can be corrected under the same ID. Equal already-accepted
retries bypass validation and do not republish. At most one fixed error per affected field
avoids echoing payload data, with finite telemetry reason `incompatible_json_paths`.
Ingestion acquires no live ClickHouse dependency. The shared shape corpus is exercised by
pure validation, real native inserts into both materialized columns, and public transport
acceptance on fresh owned stores. Writer outage retry and acknowledgement remain unchanged.
This is a first-release input contract; no historical queue migration is required.
