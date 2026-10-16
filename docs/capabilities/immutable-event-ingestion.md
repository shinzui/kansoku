---
type: Capability
title: "Immutable event ingestion"
description: "Accept single events, partial batches and browser exit beacons with durable event identity and explicit retry outcomes."
generated:
  by: process:codex
  at: "2026-10-16T13:11:11Z"
capabilityId: CAP-2
provider: mori://shinzui/kansoku
status: shipped
stability: experimental
since: unreleased
packages:
  - "kansoku-api"
  - "kansoku-core"
  - "kansoku-server"
interface:
  - "POST /v1/events"
  - "POST /v1/batch"
  - "POST /v1/beacon"
tags: [ingestion]
requires:
  - CAP-1
evidence:
  - kind: test
    resource: "kansoku-core/test/Kansoku/Ingest/AcceptanceSpec.hs"
    proves: "Checks equal retries, conflicting payloads, concurrent publication, rollback and uncertain commit acknowledgement."
  - kind: test
    resource: "kansoku-core/test/Kansoku/Ingest/BeaconSpec.hs"
    proves: "Checks body-only write-key authentication, both media types, CORS and shared admission."
  - kind: guide
    resource: "docs/guides/send-events.md"
    proves: "Specifies byte/count/rate limits, timestamp normalization and partial acknowledgements."
---

# Immutable event ingestion

Validate and normalize events, transactionally claim account/event IDs and publish accepted payloads to PostgreSQL. Equal retries reuse first acceptance; changed producer content under an accepted ID fails. Batches retain original rejection indexes. The beacon envelope supports text/plain and application/json with a body write key. Bounded per-credential admission returns 429 with Retry-After.

## Compatibility

Available in the current checkout. No release tags establish a released version, so since is unreleased. This experimental interface has no stable compatibility promise; pin the server and clients to a reviewed revision and regenerate contracts together.

## Limits

HTTP 202 acknowledges durable acceptance, with per-event rejections in batches; it does not promise immediate analytical visibility. Beacon browser queue admission is best effort and exposes no HTTP acknowledgement. Rate buckets are per server process. Unknown event fields affect immutable identity but are not promised storage.

## Requires

- [CAP-1 — Account-scoped credentials](account-scoped-credentials.md).

## Evidence

- [AcceptanceSpec.hs](../../kansoku-core/test/Kansoku/Ingest/AcceptanceSpec.hs) — Checks equal retries, conflicting payloads, concurrent publication, rollback and uncertain commit acknowledgement.
- [BeaconSpec.hs](../../kansoku-core/test/Kansoku/Ingest/BeaconSpec.hs) — Checks body-only write-key authentication, both media types, CORS and shared admission.
- [send-events.md](../../docs/guides/send-events.md) — Specifies byte/count/rate limits, timestamp normalization and partial acknowledgements.
