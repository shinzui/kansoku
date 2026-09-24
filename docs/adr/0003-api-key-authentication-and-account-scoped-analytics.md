---
type: Architecture Decision Record
title: API-key authentication and account-scoped analytics
description: Require write-key or service-token bearer authentication on ingest and metrics routes, scoped to an account, via SHA-256-hashed credentials.
timestamp: 2026-07-19T00:00:00Z
generated:
  by: human:kansoku-maintainers
  at: 2026-07-19T00:00:00Z
docId: ADR-3
status: Accepted
date: 2026-07-19
---

# ADR 0003: API-key authentication and account-scoped analytics

- Deciders: Kansoku maintainers

## Context

Kansoku is the shared analytics service for multiple portfolio products. Before EP-15, both
ingest and metrics routes were unauthenticated, event bodies could choose their own
`accountId`, and metric SQL and aggregate rollups mixed every account. That combination made
the service unsuitable for production use even though `events_raw` already carried an
account column.

Authentication must remain part of the served and documented API contract, browser and
service callers need practical credential transports, leaked database contents must not
contain reusable credentials, and account isolation must cover both raw-table and rollup-backed
metric paths. Revocation also needs to take effect promptly without coordinating cache
invalidation.

## Decision

Kansoku has two credential kinds. Write keys use the `ksk_w_` prefix and may ingest; service
tokens use `ksk_s_` and may ingest and read metrics. Issuance generates 32 random bytes,
encodes them as unpadded base64url, prints the credential once, and stores only its lowercase
SHA-256 hash in `kansoku.api_keys`. PostgreSQL DDL is an application-owned component in the
explicit pg-migrate plan. Normal server startup never applies migrations.

Authentication is always enabled and is declared in the Servant route type with two distinct
`AuthProtect` tags and principal newtypes. Distinct result types make selecting the wrong auth
handler a type error. Both route families accept `Authorization: Bearer <token>` and
`X-Api-Key: <token>`; `Authorization` takes precedence when both are present, including when it
is malformed. The OpenAPI document declares matching schemes and operation-level requirements.
The Haskell ingest client requires a credential in `ClientConfig` and sends Bearer auth.

Each request hashes the presented token and performs an indexed PostgreSQL lookup. Unknown and
revoked credentials return 401, write keys on metrics return 403, and key-store failures return
retryable 503. Kansoku deliberately has no authentication-off switch and no credential cache,
so revocation is visible on the next request.

The authenticated principal is the sole source of tenancy. Ingest overwrites any caller-supplied
`accountId` before validation and enqueueing. Metrics construct a strict `QueryRequest` with an
`AccountId` from the service-token principal. Every SQL builder compares `account_id` with one
native ClickHouse parameter; account values are never interpolated into SQL. The
`events_resolved` view exposes `account_id`, and all four aggregate rollups store it as the
leading sort-key dimension and group materialized-view and backfill rows by it.

## Alternatives considered

- WAI authentication middleware was rejected because it would duplicate routing policy outside
  the Servant type and remain invisible to generated OpenAPI.
- A shared principal result type for both auth tags was rejected because Servant selects context
  entries by result type; the metrics route could silently receive the ingest handler and accept
  write keys.
- Trusting or merely comparing the event body's account was rejected because the credential must
  be the single authority, including when the field is absent or spoofed.
- An authentication-off development mode was rejected because a misconfigured deployment would
  permanently create unattributable data. Local development uses explicit key issuance instead.
- A TTL credential cache was deferred because it would delay revocation and the existing
  PostgreSQL pool already supports the indexed lookup. It should be introduced only after
  measurement and with an explicit revocation-lag contract.
- Account-blind rollups were rejected because every production metric request is tenant-scoped;
  retaining them would force real callers onto raw scans and make the rollups operationally
  misleading.

## Consequences

All analytics callers must provision credentials, and applications emitting for multiple
accounts must hold one credential per account. Existing pre-authentication rows with an empty
account remain outside every authenticated query. Adding authentication to the route type is a
wire-contract change, while making credentials mandatory in `ClientConfig` is a source-level
client change.

Credential checks add one PostgreSQL point lookup per request. This buys immediate revocation
and simple failure semantics. Metric queries use the same account parameter on raw,
identity-resolved, ratio, retention, funnel, session, and rollup paths; future builders must pass
the completeness test that asserts this predicate. Future changes to credential kinds, header
precedence, account stamping, query scoping, rollup dimensions, or revocation latency must update
the server, client, OpenAPI artifact, EP-15, and this ADR together.
