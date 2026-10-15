---
type: Architecture Decision Record
title: RFC 9457 problem details and generated-client media
description: Use one RFC 9457 error shape and explicit per-response media types across typed handlers, authentication, framework failures, and generated clients.
docId: ADR-8
status: Accepted
date: 2026-10-15
timestamp: 2026-10-15T03:43:15Z
generated:
  by: codex-cli/gpt-6.1-sol
  at: 2026-10-15T03:43:15Z
---

# ADR 0008: RFC 9457 problem details and generated-client media

## Context

Kansoku's former `{code, message, retryable}` envelope lacked a standard media type and
HTTP status in its body. Authentication responses were documented without schemas, and
record-level authentication obscured operation ownership. Servant's endpoint Accept list
and each MultiVerb alternative's response encoding are separate contracts: changing only
the encoder can make an otherwise correct generated client reject a problem response.

The relevant practice is
`mori://shinzui/haskell-jitsurei/docs/api-rfc9457-problem-details`. The generated-client
content negotiation precedent is `mori://shinzui/kotei/okf/adrs/concepts/ADR-1`.
[ADR-1](0001-sdk-grade-ingest-contract-boundaries.md) preserves partial batches and browser
access; [ADR-3](0003-api-key-authentication-and-account-scoped-analytics.md) preserves
credential transport, account isolation and immediate revocation.

## Decision

All analytics JSON failures use `application/problem+json` and the same `ProblemDetails`
wire fields: `type`, `title`, `status`, `detail`, `code`, and `retryable`. `type` is
`about:blank`, `title` is the HTTP status phrase, and `status` equals the HTTP response
status. Stable codes retain their existing meanings and live in `Kansoku.Api.Response`'s
catalog. Human-readable detail can change. Retryable 503s cover authentication, queue and
analytics-storage outages. Unexpected synchronous faults return a generic non-retryable
500; the private cause goes to application logs. Asynchronous cancellation propagates.

Routes admit JSON and problem JSON. Successful MultiVerb alternatives explicitly use
`RespondAs JSON`, and failed alternatives use `RespondAs ProblemJSON`. The released
`openapi-hs` 5.0.0 and `servant-openapi-hs` 5.1.0 cohort preserves these response-specific
media types in the generated document. Authentication belongs to each protected leaf;
the public schema catalog remains unauthenticated. Authentication docs include problem
content, a schema, and the Bearer challenge header for 401.

A narrow response boundary fills empty framework 405, 406 and 415 rejections, preserves
status-specific headers, and leaves existing bodies and streams intact. CORS surrounds
that boundary and body limits so browser clients can read ingest errors. Operational
probes and Prometheus remain outside the public analytics error contract.

The generated Haskell clients decode declared handler failures into `KansokuResult`.
Authentication can reject before the typed handler and arrive as a Servant client failure;
callers can decode its problem body explicitly. The buffering SDK drops permanent typed
problems and pre-handler 4xx failures, retries retryable 503s and connection failures with
bounded backoff, and preserves event IDs across retries. Parsed 202 batch rejections
remain acknowledgement data and are never retried.

## Consequences

This is a coordinated API/server/client wire and source migration. `ErrorEnvelopeWire`
and `message` are removed; there is no legacy decoder. Generated route records take a
credential per protected operation. Experiment convenience helpers retain their public
credential-first signatures.

Changes to error producers must extend the shared catalog, preserve media admission,
regenerate OpenAPI, and exercise real HTTP and generated-client decoding. Schema tests
cover every documented error, including authentication. Query-limit additions can add
codes without changing the wire shape; probe adoption must preserve the operational
exemption. Server/client builds must use the same verified OpenAPI cohort.
