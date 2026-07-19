---
id: 16
slug: pipeline-observability-queue-depth-writer-lag-and-exported-telemetry
title: "Pipeline observability: queue depth, writer lag, and exported telemetry"
kind: exec-plan
created_at: 2026-07-15T21:30:34Z
master_plan: "docs/masterplans/2-kansoku-production-hardening-review-fixes-and-portfolio-service-readiness.md"
intention: intention_01kxr5jt2heyvt0n768ym9dwqd
---

# Pipeline observability: queue depth, writer lag, and exported telemetry

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Kansoku is the first-party analytics service for the kikan portfolio. Its write path is:
HTTP ingest (`POST /v1/events`, `POST /v1/batch`) enqueues events into a durable pgmq queue
inside Postgres; a shibuya batch consumer (the "writer") reads the queue and performs one
batched `INSERT` per flush into ClickHouse. The 2026-07-15 architecture review found this
pipeline unobservable: the OpenTelemetry tracer created in
`kansoku-core/src/Kansoku/Telemetry.hs` is constructed with an empty processor list, so every
span the writer and pgmq interpreter create is silently discarded; there are no metrics for
queue depth, batch flush latency, or insert failures; and the only operational signal is
JSON log lines on stderr. An operator (or an agent) currently cannot answer "is the pipeline
keeping up?" without opening `psql` and `clickhouse-client` by hand.

After this plan is implemented, three things are true and demonstrable. First, traces are
actually exported: setting the standard OpenTelemetry environment variables
(`OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_SERVICE_NAME`, `OTEL_TRACES_EXPORTER`) makes the
service ship spans to an OTLP collector (or print them to stdout with
`OTEL_TRACES_EXPORTER=console`), and a graceful shutdown flushes pending spans. Second,
`GET /internal/metrics` returns a Prometheus text-format scrape containing
`kansoku_queue_length`, `kansoku_queue_oldest_message_age_seconds`,
`kansoku_writer_batches_total`, `kansoku_writer_events_written_total`,
`kansoku_writer_batch_flush_seconds`, `kansoku_writer_insert_failures_total`, and
`kansoku_writer_dead_letters_total`, so you can watch the queue spike under load and drain as
the writer catches up. Third, the `/ready` endpoint introduced by
`docs/plans/10-restore-the-build-and-supervise-the-writer.md` (EP-10) is extended — never
replaced — with two configurable pipeline-health checks: it returns 503 when the queue depth
exceeds `KANSOKU_READY_MAX_QUEUE_DEPTH`, or when the queue is non-empty but the writer has
not successfully flushed within `KANSOKU_READY_MAX_FLUSH_AGE_SEC`. The 503 body names the
failing check and the observed value. EP-10 makes writer *death* fatal; this plan makes
writer *sickness* visible (backlog growth, slow flushes, insert failures).

With no new environment variables set, nothing changes for `nix develop` +
`process-compose up` development: the tracer stays a no-op, the metrics endpoint simply
exists, and `/ready` thresholds default to values generous enough never to fire in dev.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] M1: add hs-opentelemetry-sdk and hs-opentelemetry-exporter-handle to kansoku-core.cabal
- [x] M1: add the sdk/exporter/propagator packages to the nix overlay in nix/haskell.nix
- [x] M1: rewrite Kansoku.Telemetry (makeTelemetry with env-gated real initialization, console factory, shutdown handle)
- [x] M1: wire the telemetry bracket into kansoku-server/app/Main.hs shutdown path
- [x] M1: transcript captured — spans printed with OTEL_TRACES_EXPORTER=console; zero-change run without env vars
- [ ] M2: add prometheus-client to kansoku-core.cabal (and nix override if the pinned nixpkgs needs one)
- [ ] M2: new module Kansoku.Observability (PipelineMetrics, WriterHeartbeat, QueueDepthCell, registerPipelineMetrics)
- [ ] M2: thread PipelineMetrics + WriterHeartbeat through Kansoku.Writer.Run into Kansoku.Writer.Batch and instrument the handler
- [ ] M2: queue-depth poller (runQueueDepthPoller) supervised beside the writer in Main.hs
- [ ] M2: GET /internal/metrics route in Kansoku.Server (respecting KANSOKU_INTERNAL_METRICS_ENABLED)
- [ ] M2: config fields KANSOKU_QUEUE_POLL_INTERVAL_SEC, KANSOKU_INTERNAL_METRICS_ENABLED with defaults
- [ ] M2: transcript captured — scrape before/during/after a /v1/batch load showing queue spike and drain
- [ ] M3: new module Kansoku.Readiness (pure evaluatePipelineReadiness + threshold types)
- [ ] M3: extend EP-10's /ready handler with the two pipeline checks and the named-check JSON body
- [ ] M3: config fields KANSOKU_READY_MAX_QUEUE_DEPTH, KANSOKU_READY_MAX_FLUSH_AGE_SEC
- [ ] M3: hspec unit tests for threshold logic (Kansoku.ReadinessSpec) and metrics registration smoke test
- [ ] M3: failure-injection transcript — ClickHouse stopped, insert failures counted, /ready 503 with named check, recovery to 200
- [ ] Living sections updated; MasterPlan Progress rows for EP-16 ticked
- [x] Milestone 0 (completed 2026-07-19T16:02Z): reconciled the plan with EP-10, EP-11,
      EP-14, current dependency source, and ADR 0001; marked EP-16 In Progress and attached
      the MasterPlan intention. Baseline `cabal build all` and `cabal test all` passed with
      live dependencies (62 core examples, 0 failures; 10 client examples, 1 opt-in live
      pending).
- [x] Milestone 1 (completed 2026-07-19): real SDK initialization remains opt-in, console
      export emitted the existing pgmq/shibuya spans, Ctrl-C flushed pending writer spans,
      and the no-variable run emitted no exporter traffic or diagnostics. `cabal build all`,
      `cabal test all`, and `nix build` passed; the Nix build uses the same released TLS
      dependency family as the Cabal solver.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

Findings from the plan-authoring investigation (2026-07-15), recorded here because they
shaped the design and a future implementer must not re-derive them:

- The pinned hs-opentelemetry is version 1.0.0.0 — both on Hackage (the existing
  `dist-newstyle/cache/plan.json` resolves `hs-opentelemetry-api 1.0.0.0` and
  `hs-opentelemetry-sdk 1.0.0.0` from hackage.haskell.org) and in the nix overlay
  (`nix/haskell.nix` pins github `iand675/hs-opentelemetry` rev `46a42cdf80405fdb36fbb48a309254b2332617b4`).
  A read-through of that source (checked out at
  `/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/hs-opentelemetry`, found via
  `mori registry search opentelemetry`) confirms `OpenTelemetry.Trace.initializeGlobalTracerProvider`
  exists, reads `OTEL_TRACES_EXPORTER` / `OTEL_EXPORTER_OTLP_ENDPOINT` / `OTEL_SERVICE_NAME` /
  `OTEL_SDK_DISABLED`, and installs a batch span processor over the OTLP exporter.
- With `OTEL_TRACES_EXPORTER` unset, the SDK *defaults to the otlp exporter* (source:
  `detectExporters` in `sdk/src/OpenTelemetry/Trace.hs`, `fromMaybe ["otlp"] exportersInEnv`).
  So calling `initializeGlobalTracerProvider` unconditionally would make dev builds try to
  POST spans to `http://localhost:4318` on every flush. This forces the env-gating decision
  recorded in the Decision Log.
- There is no built-in "console" exporter (`knownExporters` contains only `otlp`, plus
  `jaeger`/`zipkin` stubs that `error`), but `OpenTelemetry.Registry.registerSpanExporterFactoryIfAbsent`
  (hs-opentelemetry-api) lets us register one, and `hs-opentelemetry-exporter-handle` provides
  `stdoutExporter' :: (ImmutableSpan -> IO Text) -> SpanExporter` and `defaultFormatter`.
  Registering `"console"` before initialization makes `OTEL_TRACES_EXPORTER=console` work,
  which is what the validation transcripts use (no collector needed).
- The pinned hs-opentelemetry 1.0.0.0 ships a real metrics SDK (`OpenTelemetry.MeterProvider`
  with in-process aggregation, `OpenTelemetry.MetricReader` periodic export, and
  `OpenTelemetry.Exporter.OTLP.Metric`) — the historical "Haskell OTel metrics lag" is largely
  gone in this fork. We still chose prometheus-client for metrics; see the Decision Log.
- pgmq's `QueueMetrics` (defined in
  `/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs/pgmq-hasql/src/Pgmq/Hasql/Statements/Types.hs`)
  *does* expose message age: fields are `queueName :: Text`, `queueLength :: Int64`,
  `newestMsgAgeSec :: Maybe Int32`, `oldestMsgAgeSec :: Maybe Int32`, `totalMessages :: Int64`,
  `scrapeTime :: UTCTime`, `queueVisibleLength :: Int64`. So
  `kansoku_queue_oldest_message_age_seconds` is directly measurable; no derived-lag fallback
  is needed.
- The path prefix `/metrics/*` is already taken by the *analytics query* API
  (`kansokuApp` in `kansoku-core/src/Kansoku/Server.hs` routes `"metrics" : _` to
  `metricsApp`, the product feature that answers DAU/retention/funnel queries). The
  Prometheus scrape endpoint therefore must live elsewhere; we use `/internal/metrics`.

(Nothing further yet; add implementation-time discoveries below this line.)

- Reconciliation discovery (2026-07-19): EP-10 landed writer liveness as an `Async` observed
  by `ReadyProbe.writerAlive`; there is no existing heartbeat cell. EP-16 therefore introduces
  the only `WriterHeartbeat` and preserves the two-level `StopAllOnFailure` plus `waitApp`
  supervision inside `runWriter`.

- Reconciliation discovery (2026-07-19): EP-9/EP-14 landed one Servant analytics app inside
  WAI-level `/health`, `/ready`, and `/openapi.json` dispatch. Ingest CORS wraps the body-size
  limit, while the operational wrapper is outside both. `/internal/metrics` must join the WAI
  operational layer without entering OpenAPI, CORS, or body-limit handling, and the operational
  allowlist conformance test must expand deliberately.

- Reconciliation discovery (2026-07-19): Mori-located hs-opentelemetry source and current
  upstream tags agree on the repository's existing `46a42cdf...` pin: the API, SDK, OTLP and
  handle exporters are the coordinated 1.0.0.0 release. The SDK still defaults an absent
  `OTEL_TRACES_EXPORTER` to `otlp`, supports registry-provided exporters, and its provider
  shutdown flushes processors. The plan's environment gate and registered `console` exporter
  remain necessary and match the exact source API.

- Reconciliation discovery (2026-07-19): Mori has no registered `prometheus-client` project.
  The authoritative Hackage index and upstream tag identify 1.1.2 as current. Its acquired
  source confirms the planned registry/gauge/histogram/text-export API, with two specifics:
  `addCounter` returns `Bool` (negative increments are rejected) and `exportMetricsAsText`
  returns a lazy `ByteString`. Instrumentation uses `void (addCounter ...)` and the WAI response
  accepts that lazy body directly.

- Reconciliation discovery (2026-07-19): current Shibuya ships `shibuya-metrics`, but its
  Prometheus view covers generic processor receive/process/failure/state/in-flight facts. It
  does not own Kansoku's pgmq queue age, ClickHouse insert duration/failure, dead-letter cause,
  or successful-event semantics. The application-specific seven-instrument surface remains the
  correct boundary instead of coupling `/internal/metrics` to Shibuya's separate server.

- Milestone 1 discovery (2026-07-19): hs-opentelemetry-sdk's library depends on the OTLP
  exporter even when its optional TLS metadata detector is disabled. That exporter exposed
  stale Nix pins: `tls 2.3.1` selected the broken `mlkem 0.2.0.0`, and jailbreaking its old
  `hpke 0.0.0` then failed against the repository's `crypton 1.1.2`. The already-green Cabal
  plan resolves `tls 2.4.3`, `hpke 0.1.0`, `mlkem 0.2.2.0`, `crypton-connection 0.4.6`,
  `http-client-tls 0.4.0`, `crypton-x509 1.9.1`, and
  `crypton-x509-validation 1.9.1`. Hackage metadata and each upstream release tag confirmed
  those versions; pinning that coherent set made the full `nix build` pass without marking a
  broken package usable or removing OTLP support.


## Decision Log

Record every decision made while working on the plan.

- Decision: Prometheus text format (library `prometheus-client`, endpoint
  `GET /internal/metrics`) for metrics; OTLP via hs-opentelemetry-sdk for traces.
  Rationale: investigation showed the pinned hs-opentelemetry 1.0.0.0 does ship a usable
  metrics SDK (see Surprises & Discoveries), so the historical maturity argument is weaker
  than expected — but OTel metrics are push-only over OTLP, meaning nothing is observable
  without running a collector, whereas this plan's acceptance criteria and the intended
  operator workflow ("curl the service and see if the pipeline is keeping up") demand a
  directly scrapable endpoint. A scrape endpoint also works in dev with zero extra
  processes, and Prometheus scraping is the assumed portfolio standard for kikan. If the
  portfolio later standardizes on an OTLP collector everywhere, migrating these seven
  instruments to the OTel metrics API is mechanical; the split is recorded so that future
  work knows it was deliberate, not an oversight.
  Date: 2026-07-15

- Decision: queue depth is sampled by a small periodic poller thread (default every 15
  seconds) that calls pgmq's `queueMetrics` and publishes to both a Prometheus gauge and an
  in-process cell that `/ready` reads; `/ready` never queries Postgres for depth itself.
  Rationale: `pgmq.metrics()` scans queue tables; running it per readiness probe (Kubernetes
  probes every few seconds) would put load on the ingest database proportional to probe
  frequency. One poller amortizes the cost, gives the gauge and the readiness check a single
  consistent source, and keeps `/ready` fast. Staleness is handled explicitly (a sample older
  than three poll intervals is discarded; EP-10's separate pgmq-reachability check already
  covers "Postgres is down").
  Date: 2026-07-15

- Decision: real tracer initialization is gated on the presence of `OTEL_EXPORTER_OTLP_ENDPOINT`
  or `OTEL_TRACES_EXPORTER` in the environment; with neither set, `Kansoku.Telemetry` keeps
  today's no-op provider (empty processor list) and shutdown is a no-op.
  Rationale: the SDK's own default with no env vars is to install the OTLP exporter pointed
  at localhost:4318 (verified in source, see Surprises & Discoveries), which would make every
  dev run attempt HTTP exports to a nonexistent collector. Gating preserves the required
  "zero behavior change in `nix develop`" guarantee while still deferring all real
  configuration (endpoint, service name, sampler, batch tuning) to the standard env vars.
  Date: 2026-07-15

- Decision: one heartbeat cell, shared with EP-10. The writer's last-successful-flush
  timestamp lives in a single `WriterHeartbeat` (an `IORef (Maybe UTCTime)`) updated inside
  `writerBatchHandler`; EP-16's flush-age readiness check reads it. If EP-10's liveness
  implementation already introduced a heartbeat cell, extend that same cell to carry a
  timestamp rather than adding a second mechanism; if EP-10 implemented liveness purely by
  supervising the writer thread (an `Async` whose death kills the process), then
  `WriterHeartbeat` is the only cell and there is no duplication.
  Rationale: two parallel "is the writer OK" mechanisms would inevitably disagree; the
  MasterPlan's integration-point rule is that EP-16 extends EP-10's readiness surface, and
  that extends to its state cells.
  Date: 2026-07-15

- Decision: the scrape endpoint is `GET /internal/metrics` on the main server port (no
  separate listener), toggleable via `KANSOKU_INTERNAL_METRICS_ENABLED` (default enabled).
  Rationale: `/metrics/*` is already the analytics query API (see Surprises & Discoveries),
  so the conventional `/metrics` path is unavailable; a separate port adds deployment surface
  for no benefit at this scale. The toggle exists so an operator can disable the endpoint
  where the port is internet-exposed before EP-15 (auth) lands.
  Date: 2026-07-15

- Decision: preserve `waiWrapper :: ReadyProbe -> Application -> Application` and add a small
  exact-path `internalMetrics` middleware inside that operational wrapper but outside EP-14's
  ingest CORS/body-limit/Servant stack; extend `ReadyProbe` with one pipeline-check action rather
  than introducing the authored positional `ServerEnv` sketch.
  Rationale: the landed `Config` already reaches `kansokuApp`, so the scrape toggle needs no new
  parameter bundle. A closure in `ReadyProbe` keeps state acquisition in `Main.hs`, keeps pure
  threshold evaluation in `Kansoku.Readiness`, and lets `readyApp` extend EP-10's response without
  learning about pools or mutable cells. The nesting preserves ADR 0001's middleware order and
  keeps the scrape endpoint out of public OpenAPI.
  Date: 2026-07-19

- Decision: generate the Nix SDK expression with `-f-tls-metadata`, and align the transitive
  TLS/crypto overrides to the current released versions already selected and tested by Cabal.
  Rationale: the optional cloud metadata detector is not used by Kansoku and needlessly adds a
  direct TLS dependency, but the required OTLP exporter still needs the HTTP TLS chain. Keeping
  that exporter while pinning a coherent release family preserves the plan's OTLP contract and
  fixes the Nix build at the dependency boundary instead of allowing a known-broken package.
  Date: 2026-07-19


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

- Milestone 1: `Kansoku.Telemetry` now returns a lifetime-owned tracer/shutdown handle. The
  server brackets that handle around both writer and HTTP supervision, so normal exit and
  writer-triggered unwind run SDK shutdown. A no-variable live run preserved the drop-all
  behavior; `OTEL_TRACES_EXPORTER=console` emitted `receive kansoku_events`,
  `kansoku-writer process`, and pgmq delete/visibility spans, including buffered spans after
  Ctrl-C. Both Cabal and Nix builds resolve hs-opentelemetry 1.0.0.0 and pass.


## Context and Orientation

This repository is a Haskell service built with GHC 9.12.4 via a nix flake. Enter the dev
environment with `nix develop` at the repo root; `just build` runs `cabal build all`,
`just test` runs `cabal test all`, and `process-compose up` (or `just up`) starts local
Postgres and ClickHouse. The server runs with `cabal run kansoku-server` and listens on
`KANSOKU_SERVER_PORT` (default 8080).

There are four cabal packages. `kansoku-api` holds wire types and servant route types
(including `Kansoku.Prelude`, the project prelude every module imports). `kansoku-core`
holds the runtime: configuration (`src/Kansoku/Config.hs`), logging (`src/Kansoku/Logging.hs`),
the WAI application (`src/Kansoku/Server.hs`), ingest handlers, the ClickHouse client
(`src/Kansoku/ClickHouse.hs`), and the writer (`src/Kansoku/Writer/Run.hs`,
`src/Kansoku/Writer/Batch.hs`). `kansoku-server` is the executable (`app/Main.hs`).
`kansoku-client` is the Haskell SDK (untouched by this plan).

The write path: `POST /v1/events` and `POST /v1/batch` (servant routes in
`kansoku-api/src/Kansoku/Ingest/Api.hs`) validate `AnalyticsEvent` records and enqueue them
into a pgmq queue. pgmq is a Postgres extension-style message queue (plain SQL functions and
tables inside Postgres); the Haskell bindings live in the local `pgmq-*` packages referenced
by `cabal.project`. The queue name defaults to `kansoku_events`. The writer is a shibuya
batch processor — shibuya is a message-pipeline framework (local packages `shibuya-core`,
`shibuya-pgmq-adapter`) — that accumulates queued messages into batches (up to
`KANSOKU_WRITER_MAX_BATCH`, default 5000, or `KANSOKU_WRITER_MAX_LATENCY_MS`, default 5000 ms)
and calls `writerBatchHandler`, which decodes each message and performs one
`insertEvents conn goodEvents` call (one ClickHouse INSERT per batch). On insert failure the
handler returns a retry decision (`AckRetry (RetryDelay 5)`), so the same messages come back
about five seconds later; messages whose payload cannot be decoded are dead-lettered
(`AckDeadLetter`). The handler receives a `Shibuya.Batch.BatchInfo` (fields `batchKey`,
`size`, `trigger`, `partition`) alongside the messages.

The observability defect this plan fixes: `kansoku-core/src/Kansoku/Telemetry.hs` currently
reads, in full:

```haskell
makeTracer :: IO OTel.Tracer
makeTracer = do
  provider <- OTel.createTracerProvider [] OTel.emptyTracerProviderOptions
  pure (OTel.makeTracer provider instrumentationLib OTel.tracerOptions)
```

The empty list is the span-processor list. A span processor is the component that receives
finished spans and hands them to an exporter; with none, every span is created and then
dropped. The tracing *plumbing* is otherwise complete and already wired:
`kansoku-server/app/Main.hs` calls `makeTracer` and passes the tracer to `runWriter`, which
runs the pgmq effect through `runPgmqTraced pool tracer` (spans like `pgmq.read`,
`pgmq.send`) and shibuya's `Shibuya.Telemetry.Effect.runTracing tracer` (spans around batch
processing). Fixing export therefore requires touching only `Kansoku.Telemetry` and the
shutdown path in `Main.hs` — no per-call-site work.

Dependency state (verified): `kansoku-core.cabal` already depends on `hs-opentelemetry-api`.
The resolved version is 1.0.0.0 from Hackage; the nix overlay in `nix/haskell.nix` builds
`hs-opentelemetry-api-types`, `hs-opentelemetry-api`, `hs-opentelemetry-propagator-w3c`, and
`hs-opentelemetry-semantic-conventions` from the pinned GitHub source (`hsOpenTelemetrySrc`,
rev `46a42cd...`) via the local helper `otelPackage name subdir`. The SDK and exporters are
*not* yet dependencies; Milestone 1 adds them.

EP-10 (`docs/plans/10-restore-the-build-and-supervise-the-writer.md`) is complete. The landed
`Main.hs` holds the writer in an `Async`, races its `wait` against Warp, and supplies
`ReadyProbe.writerAlive`; `runWriter` uses `StopAllOnFailure`, races shutdown against
`waitApp`, and drains gracefully. `GET /ready` reports writer liveness and pgmq reachability
with 200/503 JSON. EP-16 extends those exact mechanisms and must preserve both supervision
boundaries. EP-11 (connection split) is complete and remains a soft dependency only in the sense that
ClickHouse-side gauges would be cleaner against its pool; ClickHouse-side gauges are out of
scope here, so nothing in this plan actually needs EP-11.

The relevant durable record is `docs/adr/0001-sdk-grade-ingest-contract-boundaries.md`.
It requires ingest CORS to remain outside the body-size limit so browser callers can read 413
responses, and it keeps operational routes at WAI level. EP-16 therefore adds its scrape route
beside `/health`, `/ready`, and `/openapi.json`, not inside the Servant/OpenAPI contract and not
between the two ingest middlewares.

Term definitions used below. A *counter* is a monotonically increasing number (only ever
goes up; rate-of-change is what you graph). A *gauge* is a point-in-time value that can go
up or down (queue depth). A *histogram* records observations into cumulative buckets so you
can compute quantiles (flush duration). The *Prometheus text format* is the plain-text
`metric_name value` representation served on a scrape endpoint; *scraping* means a
Prometheus server periodically GETs that endpoint. *OTLP* is the OpenTelemetry wire
protocol; an *OTLP collector* is any process accepting OTLP over HTTP (default port 4318).

Code standards (from `/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/core/`, already
followed by every module here): GHC2024 with the default-extensions listed in each cabal
file, import `Kansoku.Prelude`, postpositive qualified imports (`import Data.Text qualified
as Text`), generic-lens optics via `OverloadedLabels` (`cfg ^. #serverPort`, requires
`import Data.Generics.Labels ()`), strict record fields (`!`), and explicit deriving
strategies (`deriving stock`, `deriving newtype`, `deriving anyclass`).


## Plan of Work

The work is three independently verifiable milestones: make the existing spans go somewhere
(M1), add pipeline metrics end-to-end (M2), extend readiness with thresholds over those
metrics (M3). Each milestone compiles, tests green, and demonstrates behavior on its own.


### Milestone 1 — Real trace export with flush on shutdown

Scope: replace the no-op tracer provider with the hs-opentelemetry-sdk standard
initialization, gated so that development without OTel env vars is byte-for-byte unchanged,
and flush the provider on shutdown. At the end of this milestone, running the server with
`OTEL_TRACES_EXPORTER=console` prints every pgmq/shibuya span to stdout, running it with
`OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318` ships them to a collector, and running
it with neither behaves exactly as today.

First, dependencies. In `kansoku-core/kansoku-core.cabal`, add to the library
`build-depends`:

```text
    , hs-opentelemetry-exporter-handle
    , hs-opentelemetry-sdk
```

(`hs-opentelemetry-api` is already present; keep it — `Kansoku.Telemetry` still uses
`OpenTelemetry.Trace.Core.makeTracer` and `OpenTelemetry.Registry` from it.) Both resolve to
1.0.0.0 from Hackage for cabal-in-dev-shell builds. For the nix package build, extend the
overlay in `nix/haskell.nix`: next to the existing `hs-opentelemetry-api = otelPackage ...`
lines (around line 186), add every package the SDK needs that is not already listed. The
SDK's cabal file declares dependencies on api, exporter-handle, exporter-otlp,
propagator-b3, propagator-datadog, propagator-jaeger, propagator-w3c, propagator-xray, and
semantic-conventions; exporter-otlp additionally needs the `hs-opentelemetry-otlp` protobuf
package. So add:

```nix
hs-opentelemetry-otlp = otelPackage "hs-opentelemetry-otlp" "/otlp";
hs-opentelemetry-exporter-otlp = otelPackage "hs-opentelemetry-exporter-otlp" "/exporters/otlp";
hs-opentelemetry-exporter-handle = otelPackage "hs-opentelemetry-exporter-handle" "/exporters/handle";
hs-opentelemetry-propagator-b3 = otelPackage "hs-opentelemetry-propagator-b3" "/propagators/b3";
hs-opentelemetry-propagator-datadog = otelPackage "hs-opentelemetry-propagator-datadog" "/propagators/datadog";
hs-opentelemetry-propagator-jaeger = otelPackage "hs-opentelemetry-propagator-jaeger" "/propagators/jaeger";
hs-opentelemetry-propagator-xray = otelPackage "hs-opentelemetry-propagator-xray" "/propagators/xray";
hs-opentelemetry-sdk = otelPackage "hs-opentelemetry-sdk" "/sdk";
```

(Verify the subdirectory names against the checked-out source tree at
`/Users/shinzui/Keikaku/hub/haskell/hs-opentelemetry-project/hs-opentelemetry/` before
committing; the propagator directories follow the `propagators/<name>` layout there. If one
of these fails its test suite or version bounds under nix, the existing `otelPackage` helper
already applies `dontCheck` and `doJailbreak`.)

Second, rewrite `kansoku-core/src/Kansoku/Telemetry.hs`. Replace the exported `makeTracer`
with a `Telemetry` handle that carries both the tracer and the shutdown action, so `Main.hs`
cannot forget to flush:

```haskell
-- | OpenTelemetry tracer bootstrap for the service.
--
-- Real export is opt-in via the standard environment variables. When neither
-- OTEL_EXPORTER_OTLP_ENDPOINT nor OTEL_TRACES_EXPORTER is set, the provider has
-- no processors (spans are created and dropped) and shutdown is a no-op, so
-- `nix develop` runs are unchanged. When either is set, the hs-opentelemetry
-- SDK reads the full standard configuration surface (endpoint, service name,
-- sampler, batch processor tuning) and installs a batching exporter. We also
-- register a "console" exporter factory so OTEL_TRACES_EXPORTER=console prints
-- spans to stdout for local verification without a collector.
module Kansoku.Telemetry
  ( Telemetry (..),
    makeTelemetry,
  )
where

import OpenTelemetry.Attributes qualified as Attr
import OpenTelemetry.Exporter.Handle qualified as Handle
import OpenTelemetry.Registry qualified as Registry
import OpenTelemetry.Trace qualified as TraceSdk
import OpenTelemetry.Trace.Core qualified as OTel
import Kansoku.Prelude
import System.Environment (lookupEnv)

data Telemetry = Telemetry
  { tracer :: !OTel.Tracer,
    shutdownTelemetry :: !(IO ())
  }
  deriving stock (Generic)

makeTelemetry :: IO Telemetry
makeTelemetry = do
  endpoint <- lookupEnv "OTEL_EXPORTER_OTLP_ENDPOINT"
  exporterSelection <- lookupEnv "OTEL_TRACES_EXPORTER"
  if isNothing endpoint && isNothing exporterSelection
    then do
      provider <- OTel.createTracerProvider [] OTel.emptyTracerProviderOptions
      pure Telemetry {tracer = tracerFrom provider, shutdownTelemetry = pure ()}
    else do
      _ <-
        Registry.registerSpanExporterFactoryIfAbsent
          "console"
          (pure (Handle.stdoutExporter' Handle.defaultFormatter))
      provider <- TraceSdk.initializeGlobalTracerProvider
      pure
        Telemetry
          { tracer = tracerFrom provider,
            shutdownTelemetry = void (OTel.shutdownTracerProvider provider Nothing)
          }
  where
    tracerFrom provider = OTel.makeTracer provider instrumentationLib OTel.tracerOptions
    instrumentationLib =
      OTel.InstrumentationLibrary
        { OTel.libraryName = "kansoku",
          OTel.libraryVersion = "0.1.0.0",
          OTel.librarySchemaUrl = "",
          OTel.libraryAttributes = Attr.emptyAttributes
        }
```

API facts, verified against the pinned 1.0.0.0 source so you do not have to guess:
`OpenTelemetry.Trace.initializeGlobalTracerProvider :: IO TracerProvider` (module
`OpenTelemetry.Trace`, hs-opentelemetry-sdk) reads `OTEL_SDK_DISABLED`, `OTEL_TRACES_EXPORTER`
(comma-separated; `none` yields no processors; unset defaults to `otlp`; anything else is
looked up in the registry first, then in the built-in table), `OTEL_EXPORTER_OTLP_ENDPOINT`
and friends via `loadExporterEnvironmentVariables`, `OTEL_SERVICE_NAME`,
`OTEL_RESOURCE_ATTRIBUTES`, sampler and batch-span-processor (`OTEL_BSP_*`) settings, and
sets the result as the global provider. `OpenTelemetry.Registry.registerSpanExporterFactoryIfAbsent
:: Text -> IO SpanExporter -> IO Bool` is in hs-opentelemetry-api.
`OpenTelemetry.Exporter.Handle.stdoutExporter' :: (ImmutableSpan -> IO Data.Text.Lazy.Text) -> SpanExporter`
and `defaultFormatter` are in hs-opentelemetry-exporter-handle.
`OTel.shutdownTracerProvider :: MonadIO m => TracerProvider -> Maybe Int -> m ShutdownResult`
takes an optional timeout in microseconds (default 5 s) and shuts down every processor,
which forces a final export of buffered spans. There is no separate force-flush needed on
exit; shutdown flushes.

Third, wire the shutdown into `kansoku-server/app/Main.hs`. Today `main` builds the pool,
opens ClickHouse, calls `makeTracer`, then runs the writer and server together (EP-10
restructures exactly how they are linked; adapt to whatever structure it left). The edit is:
replace `tracer <- makeTracer` with a `bracket` that owns the whole writer-plus-server
lifetime, so the flush runs on graceful shutdown *and* on the writer-death exit path that
EP-10 introduced (both unwind the stack; only an uncatchable kill skips it):

```haskell
telemetryBracket :: (Telemetry -> IO a) -> IO a
telemetryBracket = bracket makeTelemetry shutdownTelemetry
```

and inside `main`, after `openClickHouse`:

```haskell
telemetryBracket $ \telemetry -> do
  let tracer = telemetry ^. #tracer
  -- ... existing EP-10 supervision structure, passing `tracer` to runWriter ...
```

Place the bracket *inside* the existing `bracket (createPool ...) Pool.release` (the pool
must outlive nothing telemetry needs, but nesting inside keeps release ordering obvious) and
*outside* the writer/server concurrency, so the last thing the process does before exiting
is flush spans. `Kansoku.Writer.Run.runWriter`'s signature is unchanged in this milestone —
it already takes `OTel.Tracer`.

Acceptance for M1: (a) `just build` and `just test` are green; (b) with services up and no
OTel env vars, `cabal run kansoku-server` starts and behaves exactly as before (no new
output, no connection attempts to port 4318 — verify with the transcript step in Validation);
(c) `OTEL_TRACES_EXPORTER=console OTEL_SERVICE_NAME=kansoku cabal run kansoku-server`, after
one `POST /v1/batch`, prints span lines (names like `pgmq.read` / `pgmq.send` and shibuya's
batch spans) to stdout within a few seconds (the batch processor's default schedule delay is
5 s), and Ctrl-C flushes any remainder before the process exits.


### Milestone 2 — Pipeline metrics end-to-end

Scope: a Prometheus registry with seven instruments, populated from two places (the batch
handler for writer-side facts, a poller for queue-side facts), served at
`GET /internal/metrics`. At the end of this milestone you can watch
`kansoku_queue_length` spike when you post a load and drain as the writer catches up, and
`kansoku_writer_events_written_total` advance by exactly the number of accepted events.

Add `prometheus-client` to `kansoku-core/kansoku-core.cabal` (library and test-suite
build-depends). It is a plain Hackage package (1.1.x line; the API below has been stable
since 0.4). The pinned nixpkgs haskellPackages set normally provides it; if the nix build
reports it missing or broken, add to the overlay in `nix/haskell.nix`:
`prometheus-client = dontCheck super.prometheus-client;` (or a `callHackageNoCheck` pin like
the neighbors if the set lacks it entirely).

Create `kansoku-core/src/Kansoku/Observability.hs` (add it to `exposed-modules`). The name
deliberately avoids the `Kansoku.Metrics.*` namespace, which is the analytics *product*
domain (metric queries like DAU), not operational telemetry. Contents, in full:

```haskell
-- | Operational telemetry for the ingest pipeline: Prometheus instruments,
-- the writer heartbeat, and the queue-depth poller. Not to be confused with
-- Kansoku.Metrics.*, which is the analytics query product domain.
module Kansoku.Observability
  ( PipelineMetrics (..),
    registerPipelineMetrics,
    WriterHeartbeat,
    newWriterHeartbeat,
    beatWriter,
    lastWriterBeat,
    QueueDepthSample (..),
    QueueDepthCell,
    newQueueDepthCell,
    readQueueDepth,
    runQueueDepthPoller,
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, try)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Int (Int32, Int64)
import Effectful (runEff)
import Effectful.Error.Static (runErrorNoCallStack)
import Hasql.Pool qualified as Pool
import Kansoku.Prelude
import Pgmq.Effectful (QueueName, queueMetrics, runPgmq)
import Pgmq.Effectful.Interpreter (PgmqRuntimeError)
import Prometheus qualified

data PipelineMetrics = PipelineMetrics
  { queueLength :: !Prometheus.Gauge,
    queueOldestMessageAgeSeconds :: !Prometheus.Gauge,
    writerBatchesTotal :: !Prometheus.Counter,
    writerEventsWrittenTotal :: !Prometheus.Counter,
    writerBatchFlushSeconds :: !Prometheus.Histogram,
    writerInsertFailuresTotal :: !Prometheus.Counter,
    writerDeadLettersTotal :: !Prometheus.Counter
  }
  deriving stock (Generic)

-- | Register all pipeline instruments in prometheus-client's global registry.
-- Call exactly once per process, at startup, before the server serves scrapes.
registerPipelineMetrics :: IO PipelineMetrics
registerPipelineMetrics = do
  queueLength <-
    Prometheus.register . Prometheus.gauge $
      Prometheus.Info "kansoku_queue_length" "Messages currently in the pgmq events queue."
  queueOldestMessageAgeSeconds <-
    Prometheus.register . Prometheus.gauge $
      Prometheus.Info
        "kansoku_queue_oldest_message_age_seconds"
        "Age in seconds of the oldest message in the queue; 0 when empty."
  writerBatchesTotal <-
    Prometheus.register . Prometheus.counter $
      Prometheus.Info "kansoku_writer_batches_total" "Batch handler invocations."
  writerEventsWrittenTotal <-
    Prometheus.register . Prometheus.counter $
      Prometheus.Info
        "kansoku_writer_events_written_total"
        "Events successfully inserted into ClickHouse."
  writerBatchFlushSeconds <-
    Prometheus.register $
      Prometheus.histogram
        (Prometheus.Info "kansoku_writer_batch_flush_seconds" "ClickHouse insert duration per batch.")
        Prometheus.defaultBuckets
  writerInsertFailuresTotal <-
    Prometheus.register . Prometheus.counter $
      Prometheus.Info
        "kansoku_writer_insert_failures_total"
        "Failed ClickHouse batch inserts (each retry attempt counts)."
  writerDeadLettersTotal <-
    Prometheus.register . Prometheus.counter $
      Prometheus.Info
        "kansoku_writer_dead_letters_total"
        "Messages dead-lettered because their payload could not be decoded."
  pure PipelineMetrics {..}
```

(prometheus-client API: `Prometheus.register :: MonadIO m => Prometheus.Metric s -> m s`;
constructors `counter :: Info -> Metric Counter`, `gauge :: Info -> Metric Gauge`,
`histogram :: Info -> [Bucket] -> Metric Histogram`; mutators
`incCounter`, `addCounter :: Counter -> Double -> m ()`, `setGauge :: Gauge -> Double -> m ()`,
`observe :: Observer o => o -> Double -> m ()`; and
`exportMetricsAsText :: MonadIO m => m Data.ByteString.Lazy.ByteString`. `Info` takes the
metric name and help text. Confirm exact names against the resolved version with
`cabal repl kansoku-core` and `:browse Prometheus` at implementation time; if `addCounter`
in the resolved version returns `m Bool` (it did in some releases, indicating rejection of
negative increments), wrap it in `void`. Record whichever shape you find in Surprises &
Discoveries. `PipelineMetrics {..}` uses `RecordWildCards`; either enable the extension in
the module or write the fields explicitly — the codebase default-extensions do not include
it.)

In the same module, the heartbeat and the queue-depth cell — plain `IORef`s because both
have a single writer and racy reads are acceptable (a heartbeat read that misses the very
latest beat by nanoseconds is harmless):

```haskell
newtype WriterHeartbeat = WriterHeartbeat (IORef (Maybe UTCTime))

newWriterHeartbeat :: IO WriterHeartbeat
newWriterHeartbeat = WriterHeartbeat <$> newIORef Nothing

beatWriter :: WriterHeartbeat -> IO ()
beatWriter (WriterHeartbeat ref) = getCurrentTime >>= writeIORef ref . Just

lastWriterBeat :: WriterHeartbeat -> IO (Maybe UTCTime)
lastWriterBeat (WriterHeartbeat ref) = readIORef ref

data QueueDepthSample = QueueDepthSample
  { sampleQueueLength :: !Int64,
    sampleOldestAgeSec :: !(Maybe Int32),
    sampledAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)

newtype QueueDepthCell = QueueDepthCell (IORef (Maybe QueueDepthSample))

newQueueDepthCell :: IO QueueDepthCell
newQueueDepthCell = QueueDepthCell <$> newIORef Nothing

readQueueDepth :: QueueDepthCell -> IO (Maybe QueueDepthSample)
readQueueDepth (QueueDepthCell ref) = readIORef ref
```

Integration note (single-heartbeat decision): before adding `WriterHeartbeat`, check what
EP-10 actually landed. If EP-10's `/ready` liveness already reads a heartbeat cell the
writer updates, do not create a second one — move/extend that cell to this module with the
`Maybe UTCTime` representation above and update EP-10's call sites. If EP-10 implemented
liveness by supervising the writer thread only (no cell), `WriterHeartbeat` is new and the
only such mechanism. State what you found in this plan's Surprises & Discoveries.

The poller, also in `Kansoku.Observability`. It loops forever: read pgmq metrics through the
plain (untraced) interpreter, publish to the gauges and the cell, sleep. Failures are logged
to stderr and skipped — a broken poller iteration must not kill the process, and the cell
simply goes stale (M3's readiness logic discards stale samples; EP-10's pgmq reachability
check covers a down database):

```haskell
-- | Poll pgmq.metrics() every intervalSec seconds, publishing to the gauges
-- and the QueueDepthCell. Runs forever; run it under Main.hs supervision.
runQueueDepthPoller ::
  Pool.Pool -> QueueName -> PipelineMetrics -> QueueDepthCell -> Int -> IO ()
runQueueDepthPoller pool queueName metrics (QueueDepthCell cell) intervalSec = forever $ do
  result <-
    try . runEff . runErrorNoCallStack @PgmqRuntimeError . runPgmq pool $
      queueMetrics queueName
  case result of
    Right (Right qm) -> do
      now <- getCurrentTime
      Prometheus.setGauge (metrics ^. #queueLength) (fromIntegral (qm ^. #queueLength))
      Prometheus.setGauge
        (metrics ^. #queueOldestMessageAgeSeconds)
        (maybe 0 fromIntegral (qm ^. #oldestMsgAgeSec))
      writeIORef cell . Just $
        QueueDepthSample
          { sampleQueueLength = qm ^. #queueLength,
            sampleOldestAgeSec = qm ^. #oldestMsgAgeSec,
            sampledAt = now
          }
    Right (Left pgmqErr) -> logPollError (show pgmqErr)
    Left (e :: SomeException) -> logPollError (show e)
  threadDelay (intervalSec * 1_000_000)
```

where `logPollError` writes one stderr line (reuse the JSON shape from `Kansoku.Logging`'s
`runLogStderr`, or call `runEff . runLogStderr $ logWarn ...`). `queueMetrics :: QueueName ->
Eff es QueueMetrics` is from `Pgmq.Effectful` (effect operation; interpreted by
`runPgmq :: Pool -> ...` from `Pgmq.Effectful.Interpreter`, re-exported by `Pgmq.Effectful`).
The `QueueMetrics` record's fields are listed in Surprises & Discoveries;
`oldestMsgAgeSec :: Maybe Int32` is `Nothing` for an empty queue, which we report as gauge
value 0. Field access via `#queueLength` labels requires `Data.Generics.Labels ()` imported
and works despite `DuplicateRecordFields`. Default interval 15 s: coarse enough to be free
(one `pgmq.metrics()` call per interval), fine enough that a readiness threshold breach is
seen within one probe period or two.

Instrument the batch handler. `kansoku-core/src/Kansoku/Writer/Batch.hs` (post-EP-10, where
the handler pattern-matches shibuya's `Message` type) changes signature from
`writerBatchHandler :: (IOE :> es) => Connection -> BatchHandler es Value` to:

```haskell
writerBatchHandler ::
  (IOE :> es) =>
  PipelineMetrics ->
  WriterHeartbeat ->
  Connection ->
  BatchHandler es Value
```

Inside, keeping EP-10's decode logic untouched, the instrumentation points are: increment
`writerBatchesTotal` once per invocation; add `length bad` to `writerDeadLettersTotal` when
`bad` is non-empty (these are the decode failures the handler dead-letters); around the
`insertEvents conn good` call, time it with `GHC.Clock.getMonotonicTime :: IO Double`
(base; monotonic seconds, immune to wall-clock jumps) and `Prometheus.observe
writerBatchFlushSeconds (t1 - t0)`; on `Right ()`, add `length good` to
`writerEventsWrittenTotal` and call `beatWriter heartbeat`; on `Left`, increment
`writerInsertFailuresTotal` (each retry attempt of the same batch counts again — that is
the point: a stuck ClickHouse shows as a climbing failure counter). When `good` is empty
(every message in the batch failed decoding) there is no insert; still count the batch and
the dead letters, and also `beatWriter` — the writer *is* flushing, the data is just bad.
The heartbeat means "the writer last completed a flush cycle successfully", not "ClickHouse
last accepted data"; insert failures are what `writerInsertFailuresTotal` is for.

Thread the new arguments through `kansoku-core/src/Kansoku/Writer/Run.hs`: `runWriter` gains
`PipelineMetrics -> WriterHeartbeat ->` parameters (place them first, before `Pool.Pool`)
and passes them to `writerBatchHandler metrics heartbeat clickHouse` where it builds the
processor. Update the writer tests (`kansoku-core/test/Kansoku/Writer/BatchSpec.hs`) to
construct metrics via `registerPipelineMetrics` (registration in the global registry is fine
in tests; do it once in a top-level `beforeAll` or via `unsafePerformIO`-free hspec hooks)
and a fresh heartbeat.

Serve the scrape. `kansokuApp` already receives the complete `Config`; use the
`internalMetricsEnabled` field there and wrap the EP-14 middleware stack with an exact-path
`internalMetrics` middleware. `waiWrapper` remains outermost and retains its current signature,
so `/internal/metrics` joins the operational WAI allowlist without entering Servant or OpenAPI:

```haskell
["internal", "metrics"]
  | env ^. #internalMetricsEnabled -> do
      body <- Prometheus.exportMetricsAsText
      respond
        ( responseLBS
            status200
            [(hContentType, "text/plain; version=0.0.4")]
            body
        )
  | otherwise ->
      respond (responseLBS status404 [(hContentType, "text/plain")] "Not Found")
```

`exportMetricsAsText` returns a lazy ByteString of the entire global registry in Prometheus
text format; `version=0.0.4` is the format's conventional content-type version. Note the
existing `"metrics" : _` case (analytics queries) must stay untouched and must not shadow
this route — put `["internal", "metrics"]` before it. Cross-plan caution: EP-9 replaces this
hand-rolled router with servant NamedRoutes. If EP-9 has already landed when you implement
this, add the route to the servant API instead (a `"internal" :> "metrics" :> Get '[PlainText] ...`
route or a WAI middleware in front of the servant app; prefer the middleware so the scrape
endpoint never appears in the public OpenAPI document) and record the choice in the
Decision Log.

Config: in `kansoku-core/src/Kansoku/Config.hs`, add two strict fields to `Config` —
`queuePollIntervalSec :: !Int` and `internalMetricsEnabled :: !Bool` — parsed in `loadConfig`
from `KANSOKU_QUEUE_POLL_INTERVAL_SEC` (default 15, reuse `parseInt`) and
`KANSOKU_INTERNAL_METRICS_ENABLED` (default `True`; parse `"false"`/`"0"` as `False`,
`"true"`/`"1"` as `True`, anything else is a `ConfigError` — add a small `parseBool` helper
next to `parseInt`). Extend `kansoku-core/test/Kansoku/ConfigSpec.hs` with default and
parse-failure cases. All defaults keep `loadConfig` total with zero new required env vars.

Wire it all in `kansoku-server/app/Main.hs` (inside the M1 telemetry bracket): call
`registerPipelineMetrics`, `newWriterHeartbeat`, `newQueueDepthCell` before starting the
writer; pass metrics and heartbeat to `runWriter`; run `runQueueDepthPoller pool queueName
metrics cell (cfg ^. #queuePollIntervalSec)` as a sibling of the writer under the same
supervision structure EP-10 established (with EP-10's `withAsync`/`concurrently_` shape, add
one more `withAsync` layer for the poller; the poller never returns, and if it somehow dies
the `withAsync` scope exit is harmless because it is linked to the same lifetime as the
server). Extend `ReadyProbe` in M3 with a closure that reads the heartbeat/cell and runs the pure
threshold evaluator; no positional `ServerEnv` is needed.

Acceptance for M2: `just build` and `just test` green; with services up and the server
running, `curl -s localhost:8080/internal/metrics` shows all seven metric names; posting a
batch of N valid events makes `kansoku_writer_events_written_total` advance by exactly N
within one flush latency (default 5 s), and a scrape taken between enqueue and drain shows
`kansoku_queue_length` above 0 (see the Validation section for the exact choreography, which
shortens the poll interval to make the spike observable); `KANSOKU_INTERNAL_METRICS_ENABLED=false`
makes the endpoint 404.


### Milestone 3 — Readiness thresholds and failure-injection proof

Scope: extend EP-10's `/ready` with two pipeline checks whose thresholds come from config,
answering with a JSON body that names each failing check and the observed value. At the end
of this milestone, stopping ClickHouse while load arrives flips `/ready` to 503 with
`writer_flush_stale` (and, if enough backlog accumulates, `queue_depth`) named in the body,
and restarting ClickHouse recovers it to 200.

Create `kansoku-core/src/Kansoku/Readiness.hs` (add to `exposed-modules`) holding the pure
decision logic so it unit-tests without IO:

```haskell
-- | Pure readiness threshold evaluation for the pipeline checks EP-16 adds on
-- top of EP-10's /ready (writer liveness, pgmq reachability). Pure so it can
-- be tested exhaustively; the handler supplies the inputs.
module Kansoku.Readiness
  ( ReadyThresholds (..),
    ReadyCheckFailure (..),
    checkName,
    evaluatePipelineReadiness,
  )
where

import Data.Int (Int64)
import Data.Time.Clock (diffUTCTime)
import Kansoku.Observability (QueueDepthSample (..))
import Kansoku.Prelude

data ReadyThresholds = ReadyThresholds
  { maxQueueDepth :: !Int64,
    maxFlushAgeSec :: !Int,
    -- | Samples older than this many seconds are ignored (poller stall or
    -- Postgres outage; EP-10's pgmq reachability check covers the latter).
    sampleMaxAgeSec :: !Int
  }
  deriving stock (Generic, Eq, Show)

data ReadyCheckFailure
  = QueueDepthExceeded {observed :: !Int64, limit :: !Int64}
  | WriterFlushStale
      { lastFlushAt :: !(Maybe UTCTime),
        ageSeconds :: !Int,
        limitSeconds :: !Int,
        backlog :: !Int64
      }
  deriving stock (Generic, Eq, Show)

checkName :: ReadyCheckFailure -> Text
checkName = \case
  QueueDepthExceeded {} -> "queue_depth"
  WriterFlushStale {} -> "writer_flush_stale"

-- | Evaluate the pipeline checks. Arguments: thresholds; when the process
-- started (baseline for "never flushed yet"); the latest queue sample, if
-- any; the writer's last successful flush, if any; the current time.
evaluatePipelineReadiness ::
  ReadyThresholds ->
  UTCTime ->
  Maybe QueueDepthSample ->
  Maybe UTCTime ->
  UTCTime ->
  [ReadyCheckFailure]
evaluatePipelineReadiness thresholds startedAt maybeSample lastFlush now =
  case freshSample of
    Nothing -> []
    Just sample -> depthFailure sample <> flushFailure sample
  where
    freshSample = do
      sample <- maybeSample
      guard (ageSec (sample ^. #sampledAt) <= thresholds ^. #sampleMaxAgeSec)
      pure sample
    depthFailure sample =
      [ QueueDepthExceeded
          { observed = sample ^. #sampleQueueLength,
            limit = thresholds ^. #maxQueueDepth
          }
      | sample ^. #sampleQueueLength > thresholds ^. #maxQueueDepth
      ]
    flushFailure sample =
      let baseline = fromMaybe startedAt lastFlush
          age = ageSec baseline
       in [ WriterFlushStale
              { lastFlushAt = lastFlush,
                ageSeconds = age,
                limitSeconds = thresholds ^. #maxFlushAgeSec,
                backlog = sample ^. #sampleQueueLength
              }
          | sample ^. #sampleQueueLength > 0,
            age > thresholds ^. #maxFlushAgeSec
          ]
    ageSec t = floor (diffUTCTime now t)
```

Semantics, spelled out because they are the contract: the depth check fires when the latest
fresh queue sample exceeds `maxQueueDepth`. The flush-staleness check fires only when the
queue is non-empty (an idle service with an empty queue and no flushes for hours is
healthy) *and* the writer has not flushed for more than `maxFlushAgeSec`, where "not flushed
since startup" uses process start time as the baseline so a freshly started service gets a
grace period instead of an instant 503. A stale or missing sample disables both checks
(sample freshness bound: `sampleMaxAgeSec`, set to three poll intervals by the caller) —
readiness must not flap because the poller hiccuped, and a down Postgres already fails
EP-10's reachability check.

Extend EP-10's `/ready` handler (wherever EP-10 put it; it is reachable from `kansokuApp` in
`kansoku-core/src/Kansoku/Server.hs`). Keep EP-10's writer-liveness and pgmq-reachability
checks exactly as they are; append the pipeline checks by calling `evaluatePipelineReadiness`
with: thresholds built from config (`sampleMaxAgeSec = 3 * queuePollIntervalSec`), the
`startedAt :: UTCTime` captured once in `Main.hs` before starting the server, the current
`readQueueDepth cell`, `lastWriterBeat heartbeat`, and `getCurrentTime`. The response
contract: HTTP 200 when EP-10's checks pass and `evaluatePipelineReadiness` returns `[]`;
HTTP 503 otherwise. The JSON body always enumerates every check with its observation so an
operator sees the whole picture in one curl; failing pipeline checks are rendered from
`ReadyCheckFailure` (write a `ToJSON` instance or a small rendering function in the handler
module — include `check`, `ok`, and the failure's numeric fields). Shape:

```json
{
  "status": "unavailable",
  "checks": [
    {"check": "writer_alive", "ok": true},
    {"check": "pgmq_reachable", "ok": true},
    {"check": "queue_depth", "ok": false, "observed": 250413, "limit": 100000},
    {"check": "writer_flush_stale", "ok": false, "lastFlushAt": "2026-07-15T22:01:07Z",
     "ageSeconds": 214, "limitSeconds": 120, "backlog": 250413}
  ]
}
```

with `"status": "ready"` and all `"ok": true` in the 200 case. The first two entries are
EP-10's checks — render them through the same list so the body is uniform; adapt the exact
field names EP-10 used if it already emits a JSON body, extending rather than replacing its
schema.

Config: add to `Config` in `kansoku-core/src/Kansoku/Config.hs` the strict fields
`readyMaxQueueDepth :: !Int64` (env `KANSOKU_READY_MAX_QUEUE_DEPTH`, default 100000 — a
deliberately generous depth that a healthy writer at 5000-row batches clears in well under a
minute) and `readyMaxFlushAgeSec :: !Int` (env `KANSOKU_READY_MAX_FLUSH_AGE_SEC`, default
120 — over twenty times the default 5 s flush latency, so only a genuinely stuck writer
trips it). Add an `parseInt64` helper mirroring `parseInt32`. Both defaults keep dev
behavior unchanged: with the default writer config the dev queue never approaches either
limit.

Tests. New `kansoku-core/test/Kansoku/ReadinessSpec.hs` (add to test-suite `other-modules`)
covering at minimum: empty result when sample is missing; empty when sample is stale even
with a huge backlog; `QueueDepthExceeded` at limit+1 and not at the limit; no
`WriterFlushStale` on an empty queue regardless of flush age; `WriterFlushStale` with
`lastFlushAt = Nothing` using the startup baseline (fires only once `now - startedAt`
exceeds the limit); no staleness when the last flush is recent; both failures together.
Also add a registration smoke test (in a new `kansoku-core/test/Kansoku/ObservabilitySpec.hs`
or inside `Writer.BatchSpec`): `registerPipelineMetrics` succeeds and a subsequent
`exportMetricsAsText` contains all seven metric names — register once per test process, as
prometheus-client's registry is global. Run with `just test`.

Acceptance for M3: `just test` green including the new specs; the failure-injection
transcript in Validation reproduces — ClickHouse stopped, `kansoku_writer_insert_failures_total`
climbing, `/ready` 503 naming `writer_flush_stale` with observed values, then 200 again
after ClickHouse restarts and the queue drains.


## Concrete Steps

All commands run at the repository root inside `nix develop` unless stated otherwise.

Build and test loop, after each milestone's edits:

```bash
just build
just test
```

Expected: both end with no errors; `just test` prints hspec summaries for kansoku-core
including (after M3) the new `Kansoku.Readiness` and observability specs, all green.

Start services and the server (two terminals):

```bash
# terminal 1
process-compose up
# terminal 2 — plain dev run, no OTel env vars
cabal run kansoku-server
```

Generate a load file once (500 unique events; ReplacingMergeTree dedups by event id, so ids
must be unique per run — the `$(date +%s)` prefix handles that):

```bash
mkdir -p .dev
RUN=$(date +%s) python3 - > .dev/batch.json <<'PY'
import json, os, datetime
run = os.environ["RUN"]
now = datetime.datetime.now(datetime.timezone.utc).isoformat()
events = [
    {
        "eventId": f"ep16-{run}-{i:04d}",
        "eventName": "page_view",
        "source": "web",
        "occurredAt": now,
        "receivedAt": now,
        "properties": {"url": "/ep16"},
        "context": {},
    }
    for i in range(500)
]
print(json.dumps(events))
PY
curl -s -X POST localhost:8080/v1/batch \
  -H 'Content-Type: application/json' \
  --data-binary @.dev/batch.json
```

Expected response:

```json
{"accepted":500,"rejected":[]}
```

M1 trace transcript (restart the server with the console exporter; no collector needed):

```bash
OTEL_TRACES_EXPORTER=console OTEL_SERVICE_NAME=kansoku cabal run kansoku-server
```

then post a batch as above and watch the server's stdout. Within ~5 seconds (the batch span
processor's default schedule delay) span lines appear, formatted by the handle exporter's
`defaultFormatter` — one line per span carrying the span name and trace/span identifiers,
with names such as `pgmq.send`, `pgmq.read`, and shibuya's batch-processing spans. The exact
line layout is whatever `defaultFormatter` renders; the acceptance is that named spans
appear at all, then that Ctrl-C prints any still-buffered spans before the process exits
(the shutdown flush). Alternatively, with a local OTLP collector listening on 4318, run with
`OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318` and observe spans arriving there.
Then rerun with no OTel env vars and confirm stdout stays span-free: the dev default is
unchanged.

M2 metrics transcript. To make the spike visible, shorten the poll interval and the writer
batch size for this demonstration only:

```bash
KANSOKU_QUEUE_POLL_INTERVAL_SEC=1 KANSOKU_WRITER_MAX_BATCH=100 cabal run kansoku-server
```

then, in another terminal, scrape before, during, and after a load:

```bash
curl -s localhost:8080/internal/metrics | grep -E '^kansoku_'
curl -s -X POST localhost:8080/v1/batch -H 'Content-Type: application/json' --data-binary @.dev/batch.json
sleep 1
curl -s localhost:8080/internal/metrics | grep -E '^kansoku_(queue_length|writer_events)'
sleep 10
curl -s localhost:8080/internal/metrics | grep -E '^kansoku_(queue_length|writer_events)'
```

Expected shape (values will vary with timing):

```text
kansoku_queue_length 0.0
kansoku_writer_events_written_total 0.0
--- after POST, mid-drain ---
kansoku_queue_length 400.0
kansoku_writer_events_written_total 100.0
--- after drain ---
kansoku_queue_length 0.0
kansoku_writer_events_written_total 500.0
```

`kansoku_writer_batches_total` advances by roughly 500 / batch-size, and
`kansoku_writer_batch_flush_seconds_count` matches successful flushes (histogram text output
includes `_bucket`, `_sum`, `_count` series).

M3 failure-injection transcript. Run the server with demonstration-friendly thresholds:

```bash
KANSOKU_QUEUE_POLL_INTERVAL_SEC=1 \
KANSOKU_READY_MAX_QUEUE_DEPTH=100 \
KANSOKU_READY_MAX_FLUSH_AGE_SEC=15 \
cabal run kansoku-server
```

then:

```bash
# stop ClickHouse (process-compose v1 CLI; in older versions use the TUI's stop key on the clickhouse row)
process-compose process stop clickhouse
# feed the queue while the writer cannot insert (regenerate for unique ids)
RUN=$(date +%s) python3 - > .dev/batch.json <<'PY'
...same generator as above...
PY
curl -s -X POST localhost:8080/v1/batch -H 'Content-Type: application/json' --data-binary @.dev/batch.json
sleep 20
curl -s localhost:8080/internal/metrics | grep -E '^kansoku_(queue_length|writer_insert_failures_total)'
curl -si localhost:8080/ready | head -1
curl -s localhost:8080/ready | python3 -m json.tool
```

Expected: `kansoku_writer_insert_failures_total` at 2 or more and climbing (the writer
retries every ~5 s), `kansoku_queue_length` at 500, `HTTP/1.1 503 Service Unavailable`, and
a JSON body in which `queue_depth` (500 > 100) and `writer_flush_stale` (no successful flush
for > 15 s with a non-empty queue) both appear with `"ok": false` and their observed values,
matching the shape shown in Milestone 3. Then recover:

```bash
process-compose process start clickhouse
sleep 20
curl -si localhost:8080/ready | head -1
curl -s localhost:8080/internal/metrics | grep -E '^kansoku_(queue_length|writer_events_written_total)'
```

Expected: `HTTP/1.1 200 OK`, queue length back to 0, events-written advanced by 500, and no
events lost — the at-least-once queue plus ClickHouse ReplacingMergeTree dedup means the
retried batches land exactly once by `event_id`.

Commit after each milestone with a conventional commit carrying the plan trailers, e.g.:

```text
feat(telemetry): export spans via OTLP/console with flush on shutdown

MasterPlan: docs/masterplans/2-kansoku-production-hardening-review-fixes-and-portfolio-service-readiness.md
ExecPlan: docs/plans/16-pipeline-observability-queue-depth-writer-lag-and-exported-telemetry.md
```

(M2: `feat(observability): pipeline metrics and /internal/metrics scrape endpoint`; M3:
`feat(readiness): queue-depth and writer-lag thresholds on /ready`. Update this plan's
Progress section and the MasterPlan's EP-16 Progress rows in the same commits.)


## Validation and Acceptance

Beyond the per-milestone transcripts above, the plan is accepted when all of the following
hold, each verifiable by a novice with only this file:

1. `just build` and `just test` succeed at every milestone boundary; the test run includes
   `Kansoku.ReadinessSpec` (threshold logic: at-limit vs over-limit depth, empty-queue
   staleness immunity, startup baseline, stale-sample suppression) and the metrics
   registration smoke test, all green.
2. With no OTel environment variables, a dev run produces no telemetry output and no
   connection attempts — behavior identical to before this plan.
3. `OTEL_TRACES_EXPORTER=console` prints named spans after traffic and flushes on Ctrl-C;
   with an OTLP collector and `OTEL_EXPORTER_OTLP_ENDPOINT` set, the same spans arrive at
   the collector.
4. `GET /internal/metrics` serves all seven `kansoku_*` series; a 500-event `POST /v1/batch`
   is visible as a `kansoku_queue_length` spike that drains to 0 while
   `kansoku_writer_events_written_total` advances by exactly 500.
5. With ClickHouse stopped and events queued, `kansoku_writer_insert_failures_total`
   increments on each retry and `GET /ready` returns 503 with a JSON body naming
   `queue_depth` and/or `writer_flush_stale` and the observed values; after ClickHouse
   restarts, `/ready` returns to 200 and the backlog drains without event loss.
6. `KANSOKU_INTERNAL_METRICS_ENABLED=false` disables the scrape endpoint (404); all new
   config fields default such that no new environment variables are required anywhere.


## Idempotence and Recovery

Every step here is additive code or config and safe to repeat. `just build`/`just test` are
idempotent. The load generator writes unique event ids per run, so re-running transcripts
never trips ReplacingMergeTree dedup in a way that hides progress; if you do reuse a batch
file, `kansoku_writer_events_written_total` still advances (it counts insert attempts that
succeeded, pre-dedup) but ClickHouse row counts will not — that is expected and not a
failure. Stopping ClickHouse mid-run loses nothing: messages stay in pgmq (visibility
timeout returns retried messages to the queue) and drain after restart; this is the same
at-least-once guarantee the service already relies on. If a nix build breaks on one of the
new overlay packages, remove the offending line, re-enter `nix develop`, and fix the subdir
or add `dontCheck`; cabal-in-shell builds are unaffected by overlay mistakes since they
resolve from Hackage. Prometheus registration is once-per-process; if you hot-reload in
GHCi, re-registering the same metric names in the same process may fail or duplicate —
restart the REPL rather than re-running `registerPipelineMetrics`. No migrations, no
destructive operations, and no new ClickHouse objects are involved (if a later revision of
this plan ever needs one, it must go through EP-12's versioned migration mechanism under
`db/clickhouse/migrations/`).


## Interfaces and Dependencies

New dependencies in `kansoku-core/kansoku-core.cabal` (library): `hs-opentelemetry-sdk`
(module used: `OpenTelemetry.Trace` — `initializeGlobalTracerProvider`),
`hs-opentelemetry-exporter-handle` (module `OpenTelemetry.Exporter.Handle` —
`stdoutExporter'`, `defaultFormatter`), `prometheus-client` (module `Prometheus`). The
test-suite adds `prometheus-client` (and `time` is already present). Already-present and
still used: `hs-opentelemetry-api` (modules `OpenTelemetry.Trace.Core`,
`OpenTelemetry.Attributes`, and now `OpenTelemetry.Registry`), `pgmq-effectful`
(`Pgmq.Effectful.queueMetrics`, `runPgmq`), `pgmq-hasql` (the `QueueMetrics` record, via
pgmq-effectful's re-exports), `shibuya-core` (`Shibuya.Batch.BatchHandler`, `BatchInfo`),
`hasql-pool`, `effectful`. `GHC.Clock.getMonotonicTime` comes from `base`. The nix overlay
in `nix/haskell.nix` gains the eight `otelPackage` lines listed in Milestone 1 and, only if
needed, a `prometheus-client` override.

Signatures that must exist at each milestone's end (full module paths):

After M1 — `Kansoku.Telemetry.Telemetry` (record: `tracer :: OpenTelemetry.Trace.Core.Tracer`,
`shutdownTelemetry :: IO ()`) and `Kansoku.Telemetry.makeTelemetry :: IO Telemetry`; the old
`makeTracer` export is gone and `kansoku-server/app/Main.hs` compiles against the bracket.

After M2 — in `Kansoku.Observability`: `PipelineMetrics` (seven instrument fields as written
in Milestone 2), `registerPipelineMetrics :: IO PipelineMetrics`, `WriterHeartbeat` with
`newWriterHeartbeat :: IO WriterHeartbeat`, `beatWriter :: WriterHeartbeat -> IO ()`,
`lastWriterBeat :: WriterHeartbeat -> IO (Maybe UTCTime)`, `QueueDepthSample`,
`QueueDepthCell` with `newQueueDepthCell :: IO QueueDepthCell`,
`readQueueDepth :: QueueDepthCell -> IO (Maybe QueueDepthSample)`, and
`runQueueDepthPoller :: Hasql.Pool.Pool -> Pgmq.Effectful.QueueName -> PipelineMetrics -> QueueDepthCell -> Int -> IO ()`.
In `Kansoku.Writer.Batch`: `writerBatchHandler :: (Effectful.IOE Effectful.:> es) =>
PipelineMetrics -> WriterHeartbeat -> ClickHaskell.Connection -> Shibuya.Batch.BatchHandler es Data.Aeson.Value`.
`Kansoku.Writer.Run.runWriter` extended with the two leading parameters. `Kansoku.Server`
serves `GET /internal/metrics`. `Kansoku.Config.Config` has `queuePollIntervalSec :: !Int`
and `internalMetricsEnabled :: !Bool`.

After M3 — in `Kansoku.Readiness`: `ReadyThresholds` (`maxQueueDepth :: !Int64`,
`maxFlushAgeSec :: !Int`, `sampleMaxAgeSec :: !Int`), `ReadyCheckFailure`
(`QueueDepthExceeded` / `WriterFlushStale` as written in Milestone 3),
`checkName :: ReadyCheckFailure -> Text`, and
`evaluatePipelineReadiness :: ReadyThresholds -> UTCTime -> Maybe QueueDepthSample -> Maybe UTCTime -> UTCTime -> [ReadyCheckFailure]`.
`Kansoku.Config.Config` additionally has `readyMaxQueueDepth :: !Int64` and
`readyMaxFlushAgeSec :: !Int`. EP-10's `/ready` handler consumes all of the above and emits
the uniform checks JSON.

Services: local Postgres (with pgmq objects bootstrapped by the existing
`bootstrapQueue`) and ClickHouse via `process-compose up`; optionally any OTLP-over-HTTP
collector on port 4318 for the non-console trace validation. No new ClickHouse objects, so
EP-12's migration mechanism is not exercised by this plan.

---

Revision note (2026-07-19): Milestone 0 reconciled the authored plan with completed EP-10,
EP-11, EP-14, ADR 0001, and current dependency releases/source. The plan now preserves the landed
Async/readiness and WAI middleware architecture, records the sole new heartbeat, corrects the
ingest route path and schema-valid load fixture/BatchAck response, and pins the verified
hs-opentelemetry 1.0.0.0 and prometheus-client 1.1.2 API facts.

Revision note (2026-07-19): Milestone 1 implemented opt-in SDK initialization, registered
console export, and provider shutdown in the server lifetime bracket. Validation covered the
unchanged no-export path, live console spans, shutdown flush, Cabal build/tests, and the full
Nix package build. The Nix overlay records the released TLS dependency alignment needed by
the SDK's mandatory OTLP exporter.
