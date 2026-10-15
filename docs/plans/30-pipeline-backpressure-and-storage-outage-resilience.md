---
id: 30
slug: pipeline-backpressure-and-storage-outage-resilience
title: "Pipeline backpressure and storage-outage resilience"
kind: exec-plan
created_at: 2026-10-15T13:44:34Z
intention: "intention_01m4zwwdrjesytazp5tb39fe3n"
master_plan: "docs/masterplans/5-act-on-rev-1-close-silent-loss-paths-add-metric-filters-and-enrich-web-analytics.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-15T13:44:34Z
---

# Pipeline backpressure and storage-outage resilience

This ExecPlan is a living document. Update its living sections and durable ADRs as work
proceeds. It is a child of
`docs/masterplans/5-act-on-rev-1-close-silent-loss-paths-add-metric-filters-and-enrich-web-analytics.md`
and acts on findings B1, B2, B3 and A4 of
`docs/reviews/2026-10-15-architecture-and-feature-set-against-comparable-products.md`.


## Purpose / Big Picture

A ClickHouse restart, upgrade or host reboot will no longer turn queued events into archived
rows that an operator must replay by hand while readiness reports healthy. The writer will
stop attempting inserts while storage is unreachable, resume on its own when it returns, and
keep its retry budget large enough to outlast any realistic maintenance window. Operators will
see the archive size as a gauge. An abusive or runaway client holding a public write key will
receive HTTP 429 instead of filling the queue until the whole process leaves rotation. The
sustained ingest capacity of the default configuration will be measured and written down.


## Progress

- [ ] M1: With ClickHouse stopped for ten minutes under steady ingest, no message is archived, insert attempts stop within one breaker interval, and every accepted event is written within two flush intervals of ClickHouse returning. Exact replays of a failed insert do not double count in count-state rollups.
- [ ] M2: `kansoku_queue_archived_messages` is exported and documented, and a deliberately archived message raises it within one poll interval.
- [ ] M3: A client exceeding the per-key rate receives HTTP 429 with `Retry-After` and a problem document, the SDK's retry path handles it, and `kansoku_ingest_rate_limited_total` increments.
- [ ] M4: A recorded benchmark states sustained events per second, queue depth and flush latency at default settings on named hardware, and the operations guide carries sizing guidance and the trigger for the Kafka adapter.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Treat a connection-class insert failure and a malformed payload differently. The
  former opens a storage circuit breaker and is retried indefinitely with capped backoff; the
  latter dead-letters immediately as today.
  Rationale: The pinned adapter archives on delivery count, not on failure class, so without a
  breaker every outage minute consumes deliveries. The two failures have opposite correct
  responses.
  Date: 2026-10-15
- Decision: Keep readiness semantics unchanged; the archive is surfaced as a gauge and an
  alert, not as a readiness failure.
  Rationale: Archived data needs an operator, not a load balancer; failing readiness would also
  take metric reads out of rotation.
  Date: 2026-10-15
- Decision: Rate limit per credential, not per IP, with a configurable steady rate and burst,
  returning 429 through the shared problem algebra.
  Rationale: Kansoku never records client IPs and sits behind a proxy; the credential is the
  stable principal. Per-key limiting matches Segment, Mixpanel and Amplitude.
  Date: 2026-10-15


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Accepted events are enqueued in PostgreSQL through PGMQ, a queue implemented as PostgreSQL
tables, and consumed by a supervised batch writer. `runWriter` in
`kansoku-core/src/Kansoku/Writer/Run.hs` builds a Shibuya PGMQ adapter from
`PgmqAdapter.defaultConfig queueName` with `visibilityTimeout` and `batchSize` overridden from
configuration, and drives the batch handler in `kansoku-core/src/Kansoku/Writer/Batch.hs`,
which inserts a batch into ClickHouse and answers `AckRetry (RetryDelay 5)` on failure. The
adapter's configuration record (read it via Mori at
`mori://shinzui/shibuya-pgmq-adapter/packages/shibuya-pgmq-adapter`, module
`Shibuya.Adapter.Pgmq.Config`) has a `maxRetries :: Int64` field, default 3, counted from
PGMQ's per-message delivery count; when exceeded the adapter archives the message into the
PGMQ archive table `pgmq.a_<queue>` before the handler runs. The same configuration documents an
optional visibility timeout for an `AckHalt` acknowledgement; read the adapter source to
confirm whether a halted message's delivery count advances before relying on it.
Configuration variables live in `kansoku-core/src/Kansoku/Config.hs`
(`KANSOKU_WRITER_VT_SEC` default 60, `KANSOKU_WRITER_ADAPTER_BATCH`, `KANSOKU_WRITER_MAX_BATCH`).

The writer owns a logical ClickHouse connection it discards on any failure
([ADR 2](../adr/0002-pipeline-observability-readiness-and-writer-recovery.md)). A supervised
poller in `kansoku-core/src/Kansoku/Observability.hs` samples PGMQ queue metrics every
`KANSOKU_QUEUE_POLL_INTERVAL_SEC` and publishes them to Prometheus and readiness
(`kansoku-core/src/Kansoku/Readiness.hs`). The PGMQ library's effect module exposes
`peekArchivedMessages` and `lookupArchivedMessage`
(`mori://shinzui/pgmq-hs/packages/pgmq-effectful`); the replay command itself belongs to
`docs/plans/37-administrative-executable-for-keys-erasure-retention-and-replay.md`.

The raw table `analytics.events_raw` is a `ReplacingMergeTree` keyed by event id, so duplicate
rows collapse on merge, but the count-state rollups `page_views_by_route` and
`daily_event_counts` (`db/clickhouse/migrations/0006_rollups_v2.sql`) are fed by materialized
views that see inserted blocks before merges and cannot retract a replay. ClickHouse
deduplicates an inserted block by hash when `non_replicated_deduplication_window` is set on a
non-replicated table and the insert carries `insert_deduplication_token`.

Ingest routes are `/v1/*` behind `AuthProtect` write-key or service-token handlers
([ADR 3](../adr/0003-api-key-authentication-and-account-scoped-analytics.md)); the shared
MultiVerb error tail and `application/problem+json` shape are in
[ADR 8](../adr/0008-rfc9457-problem-details-and-generated-client-media.md). A portfolio
precedent for route-marker-driven throttling that keeps OpenAPI 429 responses and runtime
limits in one place is `mori://shinzui/shomei/okf/capabilities/concepts/CAP-21`; reuse the
idea, not the code, which is coupled to that service's authentication.

A "circuit breaker" here is a flag the writer sets when storage is unreachable and clears after
a successful ping, so that it does not attempt inserts while open. "Backpressure" is the
service's answer to a producer sending faster than it can absorb.


## Plan of Work

### M1: Storage circuit breaker, retry budget and replay-safe inserts

In `Kansoku.Writer.Batch`, classify insert failures: a driver connection, handshake or timeout
exception is a storage outage; any other exception keeps today's handling. On a storage outage,
open a breaker cell (an `IORef` or `TVar` owned by `runWriter`) with the failure time and
answer `AckRetry` with a delay that doubles from 5 seconds to a cap of 60 seconds while the
breaker stays open. While the breaker is open, the handler returns the retry acknowledgement
immediately without touching ClickHouse. A background task in `runWriter` pings ClickHouse
(the native ping already used by readiness) every `KANSOKU_WRITER_BREAKER_PROBE_SEC` (default
5) and closes the breaker on success. Expose the breaker state to readiness diagnostics as a
`writer_storage_breaker_open` observation on `/ready` without adding a failing check.

Raise the delivery budget: read `KANSOKU_WRITER_MAX_DELIVERIES` (default 10000) into the
adapter's `maxRetries`. With a 60-second visibility timeout this covers more than a week of
outage before archiving; document that archiving after exhaustion remains the dead-letter path
and that `docs/plans/37-…` replays it. If reading the adapter shows that a halted message does
not advance its delivery count, prefer `AckHalt` with a visibility timeout equal to the probe
interval and record the choice in the Decision Log.

Make exact replays idempotent before materialized views: add a migration (the next unclaimed
number under `db/clickhouse/migrations/`) that sets
`non_replicated_deduplication_window = 1000` on `analytics.events_raw`, and have the writer send
`insert_deduplication_token` set to the SHA-256 of the sorted event ids of the batch. State in
the operations guide that this covers only a retry of the identical batch.

### M2: Archive gauge

Extend the poller to count rows in `pgmq.a_<queue>` once per interval through the existing
PostgreSQL pool, publish `kansoku_queue_archived_messages` (gauge) alongside the queue length,
and add it to the Prometheus list and alerting sentence in `docs/guides/operations.md`:
any increase means events need operator replay.

### M3: Per-key rate limiting

Add a WAI middleware in a new `kansoku-core/src/Kansoku/Ingest/RateLimit.hs` applied to
`/v1/events` and `/v1/batch` after authentication resolves the credential id. Implement a
token bucket per credential keyed by the key's UUID with
`KANSOKU_INGEST_RATE_EVENTS_PER_SEC` (default 2000) and `KANSOKU_INGEST_RATE_BURST` (default
10000), counting events per request (batch length) rather than requests. An exhausted bucket
returns HTTP 429 with `Retry-After` in whole seconds and the standard problem document with a
new stable code `rate_limited` and `retryable: true`. Add 429 to the shared error tail and
regenerate OpenAPI and the client. Count `kansoku_ingest_rate_limited_total`. Confirm the
Haskell client treats 429 as retryable with backoff; the browser SDK already retries unknown
responses. Record a Decision Log entry if the middleware must run before authentication for
unauthenticated floods.

### M4: Measured throughput

Add `scripts/ingest-load.py` that posts batches of synthetic events at a target rate for a
duration and prints achieved rate; run it against the local stack on this machine and on the
deployment's reference hardware, capturing `kansoku_queue_length`,
`kansoku_queue_oldest_message_age_seconds` and `kansoku_writer_batch_flush_seconds` from
`/internal/metrics` during the run. Record sustained events per second at which the oldest
message age stays below the flush interval, and the rate at which it grows without bound.
Write both numbers, the hardware, PostgreSQL settings and the Kafka-adapter trigger into a
"Sizing" section of `docs/guides/operations.md` and into this plan's Outcomes.


## Concrete Steps

Inside `nix develop` at the repository root with the stack running:

```bash
cabal build all --enable-tests
cabal test kansoku-core --test-options='--match "Writer"'
cabal test kansoku-core --test-options='--match "RateLimit"'
```

Controlled outage for M1 (the ClickHouse process is managed by process-compose; stop and
start it with the process-compose CLI on the control port used to start the stack):

```bash
process-compose process stop clickhouse --port 18080
python3 scripts/ingest-load.py --rate 200 --seconds 600 --key "$KEY"
process-compose process start clickhouse --port 18080
```

During the outage `curl -s localhost:8080/internal/metrics | grep -E 'kansoku_queue_(length|archived)'`
shows the queue growing and the archive at `0`; after restart the queue drains to `0` and
`kansoku_writer_events_written_total` equals the accepted count.


## Validation and Acceptance

Required acceptance:

1. M1 outage scenario above: `kansoku_queue_archived_messages` stays `0`, insert failure
   counter increments at most once per probe interval while open, and
   `SELECT count(DISTINCT event_id) FROM analytics.events_raw` equals accepted events after
   recovery. A unit test drives the breaker with an injected failing connection.
2. M1 replay test: insert the same batch twice with the same token; `countMerge` from
   `page_views_by_route` for the day equals the batch's page views once.
3. M2: `SELECT pgmq.archive('kansoku_events', <id>)` on a test message raises the gauge within
   one poll interval.
4. M3: a loop sending batches above the configured rate observes 429 with `Retry-After`,
   problem code `rate_limited`, and the counter moving; requests under the rate are unaffected.
   `OpenApiSpec` documents 429 on both ingest operations.
5. M4: the benchmark numbers and hardware are recorded in the plan and the guide.


## Idempotence and Recovery

All configuration has defaults preserving current behaviour except the larger delivery
budget, which only delays archiving. The migration adding the deduplication window is
additive and reversible with `ALTER TABLE … RESET SETTING`. If the breaker misclassifies a
failure, the worst case is today's behaviour (retry with delay). The rate limiter can be
disabled by setting the per-second rate to `0` (meaning unlimited); document that value.


## Interfaces and Dependencies

No hard dependency on other children. `PipelineMetrics` gains instruments also touched by
`docs/plans/29-correct-client-timestamp-skew-and-count-ingest-rejections.md`; coordinate the
record edits. The archive replay command and purge are owned by
`docs/plans/37-administrative-executable-for-keys-erasure-retention-and-replay.md`, which
consumes this plan's gauge. Libraries: the pinned `shibuya-pgmq-adapter` (config fields
`maxRetries`, `visibilityTimeout`, `batchSize`), `pgmq-effectful` for archive inspection,
`prometheus-client`, `hasql` through the existing pool, and ClickHaskell's native ping.
Update [ADR 2](../adr/0002-pipeline-observability-readiness-and-writer-recovery.md) with the
breaker, the delivery budget and the archive gauge, and
[ADR 1](../adr/0001-sdk-grade-ingest-contract-boundaries.md) with the 429 contract.
