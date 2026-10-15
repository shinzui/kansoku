---
type: Architecture Decision Record
title: Pipeline observability, readiness, and writer recovery
description: Add OpenTelemetry tracing, Prometheus pipeline metrics, ordered readiness checks, and logical writer-connection recovery for the PGMQ-to-ClickHouse pipeline.
timestamp: 2026-10-15T05:12:00Z
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
Its JSON snapshot includes name, trace/span IDs, attributes, events and status so executable
privacy checks inspect the complete captured span rather than only its name.

Prometheus owns seven Kansoku-specific pipeline instruments: queue length, oldest queued-message
age, writer batches, successfully written events, batch insert duration, insert failures, and
decode dead letters. `GET /internal/metrics` is an exact WAI-level operational route on the main
port. It stays outside Servant/OpenAPI, ingest CORS, and body-size handling, and can be disabled
with `KANSOKU_INTERNAL_METRICS_ENABLED`.

A supervised poller samples PGMQ metrics once per configured interval and publishes one shared
sample to both Prometheus and readiness. Readiness never scans the queue directly. `/ready`
always reports five ordered checks: `writer_alive`, `pgmq_reachable`, `clickhouse_query_reachable`, `queue_depth`, and
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

## Shared probes and query connection lifetime

The operational Servant surface uses released servant-health 0.1.0.0, independently
of the public analytics API. `/health/live` and `/health/ready` use its fixed
200/503 JSON contract. Each check has a startup-allocated failure tracker; consecutive
failures retain their onset until recovery. Liveness reads in-process state only.
Readiness short-circuits in the five-check order above. Native ClickHouse ping is a
query-path dependency check; it does not scan tables. External checks have a 750 ms
budget including pool wait and disposal, and the complete probe has a 2 second budget.
Compatibility `/health` and diagnostic `/ready` remain. All four exact paths stay
outside customer OpenAPI, auth and ingest middleware, and form the shared access-log
exclusion inventory.

Query operations let exceptions escape the resource-pool callback, so failed handles
are physically disposed before errors propagate. A later checkout creates a fresh
connection. Idle resources close after 60 seconds and application shutdown closes the
pool. The writer keeps its independent connection/retry ownership.

The released driver at `mori://KovalevDima/ClickHaskell/packages/ClickHaskell`,
v1.1.0 revision `4524fbdd08cd0cf4a3468180323cbf6c4cf5667b`, reconnects during
exception cleanup and has no public close operation. A minimal checked-in compatibility
repair in `vendor/ClickHaskell` adds idempotent close, invalidates failed handles without
reconnection, and closes sockets on failed or interrupted initial authentication. Cabal
and Nix consume the same source. Native regression tests use a controlled TCP proxy and
an isolated real ClickHouse instance to exercise failed connect, stalled handshake,
stalled query, failure without reconnect, cancellation and size-one pool recovery. The
external watchdog prevents a broken deadline hanging the suite. Keep this repair until a
released driver supplies equivalent lifetime behavior and passes those native tests.

## HTTP tracing and access privacy

One outer WAI span observes the assembled application, with exact analytics and
operational Servant proxies annotating its route. No Raw root fallback creates an
empty route label. An inner access logger observes actual auth, body-limit, framework
and application statuses; the existing problem boundary retains its CORS placement.
Incoming W3C context becomes the remote parent, and valid serving IDs correlate with
one JSON access line. Unmatched requests have method-only span names.

The only production-exposed HTTP middleware sanitizes instrumentation inputs before
capture: no raw or parsed query, only necessary propagation/host/user-agent headers,
and bounded path/user-agent input. The inner closure restores the complete original
request with the instrumented vault. Response callbacks also capture the sanitized
copy. Exported spans and access records therefore omit query values, credentials and
payloads in all three HTTP semantic modes. Shared probe paths emit no access records.

Access JSON writes to stdout in one line operation; application diagnostics remain
on stderr. Its fixed fields are method, query-free path, path truncation flag, numeric
status, UTC time, monotonic duration_ms, optional user-agent and its truncation flag,
and valid lowercase trace/span IDs. Input byte limits are 2048 for path and 512 for
user-agent. No body or arbitrary header capture is provided.

Tracer and optional meter providers are installed before constructing instrumentation.
Trace export requires explicit endpoint/exporter configuration; HTTP metric export
requires explicit OTEL_METRICS_EXPORTER. SDK_DISABLED takes precedence. Bracket exit
flushes both providers before shutdown, including exception unwinding. Prometheus
pipeline ownership and the lack of per-event queue trace propagation remain deliberate.
In-memory span tests cover production route annotation, remote parenting, concurrent
context isolation, bounded failures and secret absence; separate subprocesses cover
legacy/stable/duplicate semantic modes and buffered normal/exceptional shutdown.

The verified dependency cohort is WAI instrumentation 1.0.0.0 with the existing 1.0
SDK/API and `mori://shinzui/hs-opentelemetry-instrumentation-servant` at immutable
revision `5e99a7857032484abc669076704dee4335e7d0ad` for MultiVerb/AuthProtect
support. Cabal and Nix pins agree.

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
