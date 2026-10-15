---
type: Architecture Decision Record
title: Pipeline observability, readiness, and writer recovery
description: Add OpenTelemetry tracing, Prometheus pipeline metrics, ordered readiness checks, and logical writer-connection recovery for the PGMQ-to-ClickHouse pipeline.
timestamp: 2026-10-15T03:31:27Z
generated:
  by: human:kansoku-maintainers
  at: 2026-07-19T00:00:00Z
docId: ADR-2
status: Accepted
date: 2026-07-19
---

# ADR 0002: Pipeline observability, readiness, and writer recovery

- Deciders: Kansoku maintainers

## Context

Kansoku accepts analytics events into a durable PostgreSQL PGMQ queue and writes them to
ClickHouse in Shibuya-managed batches. Process supervision detects a dead writer, but before
EP-16 the service exported no spans, queue or writer metrics, or signal that a live writer was
failing to flush. Operators could only diagnose pipeline health by querying both databases.

The public analytics API already owns `/metrics/*`, and the served Servant type is also the
source of the public OpenAPI document. EP-14 separately established ingest-only CORS and body
limits. Operational telemetry must not enter those public API or middleware contracts.

Live dependency failure also exposed a driver ownership problem. ClickHaskell serializes a
connection through an internal `MVar`; when an operation fails and the driver's immediate
reconnection fails too, that opaque state can remain empty. Reusing the handle then blocks
forever, preventing queue recovery and graceful cancellation.

## Decision

Kansoku uses OpenTelemetry for traces and Prometheus for operational metrics. Real trace SDK
initialization is opt-in through standard OpenTelemetry exporter variables; with none present,
development retains the no-op provider. The server owns the provider lifetime and shuts it down
after writer/HTTP supervision unwinds, flushing buffered spans. A registered `console` exporter
supports collector-free validation, while configured OTLP remains the production export path.

Prometheus owns seven Kansoku-specific pipeline instruments: queue length, oldest queued-message
age, writer batches, successfully written events, batch insert duration, insert failures, and
decode dead letters. `GET /internal/metrics` is an exact WAI-level operational route on the main
port. It stays outside Servant/OpenAPI, ingest CORS, and body-size handling, and can be disabled
with `KANSOKU_INTERNAL_METRICS_ENABLED`.

A supervised poller samples PGMQ metrics once per configured interval and publishes one shared
sample to both Prometheus and readiness. Readiness never scans the queue directly. `/ready`
always reports four ordered checks: `writer_alive`, `pgmq_reachable`, `queue_depth`, and
`writer_flush_stale`. The pipeline checks use configurable depth and successful-flush-age
thresholds. Flush age matters only while a fresh sample shows backlog; startup is the baseline
until the first successful flush, an empty queue is healthy, and samples older than three poll
intervals are ignored because the independent PGMQ check owns dependency reachability.

The batch writer owns a logical `WriterConnection`, not a process-lifetime physical driver
handle. It lazily opens and caches one ClickHouse connection, clears that cache whenever an
operation throws, and opens a fresh connection on the next Shibuya delivery. Query connections
remain in EP-11's separate bounded pool. The batch handler converts synchronous insert failures
to `AckRetry` and rethrows asynchronous cancellation so supervision and graceful shutdown remain
effective.

## Planned extension: query recovery and HTTP tracing privacy

The review of [MasterPlan 4](../masterplans/4-align-kansoku-with-relevant-haskell-jitsurei-practices.md)
on 2026-10-15 established the following implementation constraints. This extension is planned;
the existing accepted behavior above remains the runtime baseline until the named child plans
record acceptance evidence.

[EP-24](../plans/24-adopt-shared-liveness-and-readiness-probes.md) owns the query-pool lifetime
used by both readiness and analytics. Failed or interrupted native operations must dispose
their physical connection before propagating failure, and a later checkout creates a fresh
connection. Cancellation cleanup must not synchronously reconnect. Probe budgets include pool
wait and cleanup; neither abandoned background operations nor forgotten sockets satisfy a
bounded probe contract. A native stalled-I/O and recovery proof is required before adoption.
[EP-26](../plans/26-bound-analytics-query-inputs-and-result-cardinality.md) consumes that accepted
boundary and classifies storage errors after resource cleanup. The writer retains its separate
connection ownership and retry policy.

[EP-25](../plans/25-trace-http-requests-and-emit-safe-correlated-access-logs.md) owns HTTP tracing
privacy before instrumentation records attributes. Instrumentation receives a sanitized request
view with no query values; the application receives the original query and the instrumented
request's trace context. Credentials, bodies and query values must be absent from exported HTTP
span attributes/events and access records in both legacy and stable semantic-convention modes.
Query-free access logs alone are insufficient, and export-only redaction would leave sensitive
values visible to earlier span processors. The production assembly must expose the sanitizing
adapter as its tracing middleware, preserving request semantics and W3C parent correlation.

The owning children must update this section with the implemented boundary and native/export
evidence when accepted. Their execution ordering and temporary fixtures remain in the plans.

## Alternatives considered

- OpenTelemetry metrics were rejected for this surface because they require an OTLP collector;
  a direct Prometheus scrape works in development and production without another process.
- `/metrics` was rejected because it is already the analytics query namespace. A separate
  listener was rejected as unnecessary deployment surface.
- Adding `/internal/metrics` to Servant was rejected because it would publish an operational
  endpoint in the customer-facing OpenAPI document and pull it inside ingest middleware.
- Querying PGMQ on every readiness request was rejected because probe frequency would dictate
  database scan load and could make readiness itself expensive.
- Trusting ClickHaskell's in-place reconnect was rejected after live recovery hung and source
  inspection showed the unrepairable empty-lock path. Restarting the whole Kansoku process was
  rejected because Shibuya already provides safe redelivery and the service owns the physical
  connection boundary.
- Swallowing all `SomeException` values as retryable insert failures was rejected because it also
  swallows thread cancellation and can wedge graceful shutdown.

## Consequences

Operators can distinguish a dead writer, an unreachable queue, excessive backlog, and a live but
stale writer in one readiness response, and can correlate those states with scrape counters and
exported spans. Default development requires no exporter or new environment variables.

The queue sample is deliberately eventually consistent. A missing or stale sample disables the
two pipeline threshold checks; PostgreSQL reachability still fails independently. Readiness
recovers after backlog drains and does not retain historical failure state, so alerting should
also watch the monotonic insert-failure and dead-letter counters.

The pinned Shibuya PGMQ adapter still owns retry policy: its default `maxRetries = 3`
auto-archives before handler invocation on delivery four. Replace-on-failure connection recovery
therefore guarantees automatic drain only inside that retry budget. Longer dependency outages
require archive replay or a separately approved retry-policy change; EP-16 does not silently
change that established delivery policy.

Changes to operational route placement, readiness semantics, writer connection ownership, or
trace/metric export boundaries must update the server, conformance and readiness tests, EP-16,
and this ADR together.
