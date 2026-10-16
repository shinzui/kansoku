---
type: Architecture Decision Record
title: Stable reader SQL and real consumer conformance
description: Expose explicit versioned single-tenant projections through constrained reader privileges and verify supported consumers against the packaged database.
docId: ADR-18
status: Accepted
date: 2026-10-16
timestamp: 2026-10-16T22:55:08Z
generated:
  by: process:codex
  at: 2026-10-16T04:23:20Z
---

# Stable reader SQL and real consumer conformance

## Context

The HTTP query connection owns private identity caches. SQL consumers need a deliberate
read contract that resolves the same canonical subjects without those connection-local tables.
Granting views that still require the reader to select raw storage is not a working boundary.
The retained-history and current-identity rules in ADRs 4, 5 and 17 apply to SQL as well as HTTP.

## Decision

Keep the ordered events_resolved/events_resolved_v3 projection stable. The organisation
extension in [ADR-21](0021-organization-aggregation-and-current-membership.md) appends
organization_id as column eight, preserving the original seven-column prefix. Add
an explicitly named events_analytics_v1 projection with account/from_time/to_time parameters,
half-open UTC candidate bounds, canonical subject names, properties and named source/session/
bot/device/acquisition columns. It delegates to the conservative parameterized resolver,
independent of HTTP caches. Identity evidence may lie outside the candidate window, while
applied retention and erasure remain effective through canonical facts and rebuilt evidence.

These views use explicit SQL SECURITY DEFINER with the migration operator as owner. A trusted
single-tenant reader role gets SELECT on just the three views. Account parameters are query
scope, never row-level authorization for an untrusted viewer. The owner must retain underlying
SELECT rights; ownership and grants are operator responsibilities. Base relations, raw sketches,
identity evidence and HTTP caches remain internal and can change.

A reader settings profile fixes read-only mode and bounds execution to 30 seconds, memory to
512 MiB, results to 10000 rows/10 MiB with native block-boundary overflow checks, and four threads.
A single native block can overshoot the nominal result bound; this is distinct from the
HTTP complete-or-error point contract. Reader JSON timestamps use explicit ISO UTC output so consumer preview
parsing is independent of its local time zone. Clients may lower
the time/memory limits but cannot disable them. Creating the role requires writable SQL access
storage and an operator with access-management privileges. Reader credentials belong on the
consumer backend; they are not browser write keys or metrics service tokens.

Recipes must be executed with that actual role and matched to HTTP on adversarial facts.
A supported dashboard/experiment recipe requires a pinned real consumer or equivalent actual
consumer-code integration, not SQL review alone. GrowthBook assignments retain distinct
exposure events, use the same canonical subject as facts and map variation labels explicitly.
Kansoku supplies analytical facts and diagnostics; it does not implement a statistics engine.

Direct SQL bypasses the PostgreSQL HTTP maintenance fence. Operators pause external query
schedules during destructive maintenance and resume after the completed administrative receipt;
a query racing rebuilds has no atomic cross-table snapshot guarantee. Downstream caches and
exports require their own deletion and retention. Typed JSON recipes use guarded Dynamic
subcolumns rather than string JSON extraction. Consumer settings must fit the fixed role
bounds; Grafana uses a shorter deadline because its pinned Go driver adds five seconds.

## Alternatives considered

Granting raw tables would make internal layout a public contract and bypass retained projections.
Invoker-only views would require underlying privileges. Reusing HTTP's connection-local Join
caches would fail in ordinary external connections. Freezing every rollup would also freeze
approximation and implementation details without a consumer need.

## Consequences

Named SQL versions can evolve independently of storage. Full retained-history and identity
work can still reach the finite resource bounds; result limits do not promise constant scan cost.
The compatibility view includes bots and profile events; metric parity uses the richer view with
explicit matching population predicates. The actual constrained reader reproduces all three HTTP recipes before and after retention.
GrowthBook 5.1.0 passes four real adapter cases; Grafana 13.2.4/plugin 4.22.1 passes datasource
health, saved panel import/readback and real panel query. These are local integration proofs,
not claims of a deployed consumer service. Reproduction is in the consumer-conformance guide.

## Native migration sessions

Pause external reader schedules through the complete native migration session described in
[ADR-22](0022-explicit-clickhouse-migrations-and-persistent-administrative-sessions.md),
including diagnosis and repair. Resume only after deliberate current-history verification and
session completion. The PostgreSQL fence cannot stop direct SQL readers. The native baseline
retains the migration operator as SQL SECURITY DEFINER; that identity must retain underlying
SELECT privileges, and the existing constrained reader role/grants remain operator-owned.
