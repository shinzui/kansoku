---
type: Architecture Decision Record
title: Owned executable acceptance environments
description: Gate service changes with deterministic checks and required integration against the Nix executable in fresh owned database processes.
docId: ADR-10
status: Accepted
date: 2026-10-15
timestamp: 2026-10-16T22:55:08Z
generated:
  by: process:codex
  at: 2026-10-16T17:56:53Z
originatingPlan: docs/plans/28-gate-service-releases-with-isolated-hurl-acceptance-and-ci.md
---

# ADR 0010: Owned executable acceptance environments

## Context

Unit and WAI tests cannot prove that the distributed server starts with its packaged
migration executable, native driver and real databases. Existing optional integration
helpers can report pending tests when prerequisites are absent, and native fixtures
truncate analytics tables. Those fixtures must never target an ambient database.

## Decision

`just check` builds tests and runs explicit deterministic subsets, formatting, generated
contract drift, OpenAPI 3.1 lint, strict ADR validation and HTTP telemetry lifecycle/privacy.
Subsets reject zero examples and pending cases. Generator checks compare and restore the
existing artifact bytes, including uncommitted edits, rather than trusting git diff alone.

`just acceptance` resolves Nix JSON outputs and executes the packaged server and migration
binaries directly. It owns fresh PostgreSQL and ClickHouse data, ports, socket and child
processes. It overrides ambient service/exporter/credential configuration, applies explicit
migrations, runs destructive native tests before seeding HTTP fixtures, and issues disposable
credentials through the actual CLI. Required mode turns absent database/schema/live SDK
prerequisites into failures. Native watchdogs, small-block ordering, result bounds, complete
console-export privacy in three semantics modes and live SDK delivery are release evidence.

Hurl files follow resource families. Safe defaults explicitly select read-only files on
IPv4 loopback; ingest/perimeter and metrics-disabled scenarios are explicitly selected by
the owning harness. Stateful families have separate accounts. Mutations execute once;
only eventual read assertions retry. Credentials use a private secrets file.

Each run creates a fresh child under a local parent, retains private logs/data and stops only
its recorded processes on success, error or termination. No option redirects setup to an
existing service. Raw files remain restricted; CI uploads only sanitized log copies.
GitHub Actions runs both gates and Nix package/flake checks with immutable action revisions,
bounded timeouts and no publishing or deployment credentials.

## Alternatives considered

Ambient development databases were rejected because native tests mutate their tables.
A sentinel HTTP process was rejected because it bypasses production startup and dependency
assembly. A green optional suite was rejected as integration evidence because pending cases
can conceal missing prerequisites. Broad Hurl globs were rejected because they mix safe reads
with stateful operations. Raw report uploads were rejected because failure context may echo
credentials or query values.

## Consequences

Acceptance costs more than unit checks but proves the distributed boundary. Every rerun is
independent and needs no database reset. Contributors can inspect retained private evidence;
shared evidence must come from its sanitized subdirectory. Test configuration examples restore
environment values between cases so they cannot silently lose the harness's private endpoints.
The public contracts remain owned by ADRs 1–9 rather than redefined by the harness.
A deliberate Hurl status mismatch produces nonzero exit and sanitized evidence; restoring
it permits a clean rerun. Both runs leave an unrelated listener responsive and stop all
recorded service PIDs. Invalid packaged startup configuration fails within its watchdog.

The owned packaged gate also requires seven administrative scenario families, including
transaction rollback/concurrency, backend write draining, failed-job resume, retained writer
payloads, old native-block replay, independent fingerprint cleanup and raw/rollup agreement.
It records and stops CLI/server processes and keeps sensitive command evidence outside the
sanitized log set. Required configured SDK helper cases run in each telemetry mode.

## Scenario resource ownership

Shared-store acceptance scenarios register every successfully created saved definition by
returned ID and originating account credential. Context-managed finalization runs on success
and failure, deleting dependent metric definitions before explicitly clearing static membership
and deleting cohorts. Already-absent owned resources may return 404; other failures remain
visible and cleanup continues for the remaining resources. A primary scenario exception stays
primary, with cleanup failures attached as context. Unrelated resources are never inferred
from list membership or name prefixes and never deleted. Strict full-list pagination remains
unchanged. The packaged gate requires repeated same-store scenario composition, failure
injection after membership upload, native verification of cleared active membership, and an
unrelated sentinel. Physical historical membership facts may remain under
[ADR-19](0019-saved-query-time-cohorts-and-static-membership.md).

## Native migration qualification

[ADR-22](0022-explicit-clickhouse-migrations-and-persistent-administrative-sessions.md)
requires the actual Nix migration executable and an explicit test-only compiled suffix, both
stores owned by the harness, and nonzero required fresh/upgrade/recovery/coordination cases.
The initial native proof is restricted to the exact hash-qualified Darwin/arm64 artifact.
The macOS job supplements Ubuntu acceptance; Linux remains a visible qualification blocker,
not a skipped success or a decision to remove that platform. Configuration, local observations,
remote CI results and deployment readiness are recorded separately.
