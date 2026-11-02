---
type: Architecture Decision Record
title: Verified TLS for native ClickHouse connections
description: Enable certificate-verified native TLS explicitly for writer and query connections while preserving plaintext local defaults and independent native-migration qualification.
docId: ADR-23
status: Accepted
date: 2026-11-02
timestamp: 2026-11-02T03:15:02Z
originatingPlan: mori://tan/tan-app-infrastructure/plans/42-qualify-kansoku-artifacts-and-the-staging-clickhouse-contract
generated:
  by: process:codex
  at: 2026-11-02T03:15:02Z
---

# Verified TLS for native ClickHouse connections

## Context

The TAN staging ClickHouse endpoint requires native TLS on port 9440. Kansoku's
native writer and query-pool connections previously sent plaintext regardless of
port. The separate migration executable already accepts an explicit HTTPS endpoint.
Its exact-server and retained-identity requirements remain governed by
[ADR-22](0022-explicit-clickhouse-migrations-and-persistent-administrative-sessions.md).

## Decision

`KANSOKU_CLICKHOUSE_SECURE=true` enables TLS for every native connection opened by
`Kansoku.ClickHouse.openClickHouse`, including writer reconnection and query pools.
The default is false for existing owned local deployments. Ports remain explicit;
setting a secure port does not silently enable TLS, and enabling TLS does not guess
a provider-specific port.

Wrap the driver's already-opened TCP socket before its native authentication
handshake using released `crypton-connection` 0.4.6. Reuse its system certificate
store, hostname/SNI binding and normal certificate verification. `SSL_CERT_FILE`
can select a trusted CA bundle in an image or owned test. No insecure verification
switch, plaintext fallback, external proxy process or additional socket is exposed.
The driver retains connection and error cleanup ownership.

The transport's intended package reference is
`mori://kazu-yamamoto/crypton-connection/packages/crypton-connection`; registry adoption
is pending, and the source was verified from Hackage and its upstream repository.

The existing dependency set already contains this release. Its Hackage metadata,
upstream v0.4.6 tag and source were verified before adding a direct dependency;
the TLS stack's existing Nix pins remain unchanged. The driver extension point is
documented in `mori://KovalevDima/ClickHaskell/docs/connection` and its TLS example
in `mori://KovalevDima/ClickHaskell/docs/clickhaskell-tls`.

## Validation

The required owned TLS harness executes the actual writer/query connection factory
against a fresh native server. Plaintext and trusted TLS both complete native pings
and query-pool acquisition. Untrusted and wrong-host certificates fail before the
proxy receives any native application bytes. The executable acceptance gate runs
this harness; missing prerequisites fail visibly. Configuration tests reject an
invalid selector and preserve explicit ports and the plaintext default.

Read-only native pings through the writer connection factory and query pool also
succeeded against TAN staging with its read-only login and publicly trusted
certificate. This establishes transport interoperability, not schema migrations,
managed-endpoint affinity, privileged operation support or deployment readiness.

## Consequences

Images enabling TLS need a valid CA trust store. Credentials reach the native
protocol only after verified TLS. The HTTP migration endpoint is configured
separately with `KANSOKU_CH_MIGRATION_ENDPOINT=https://...`; this selector does not
relax its version, topology, identity, exclusion or recovery checks.
