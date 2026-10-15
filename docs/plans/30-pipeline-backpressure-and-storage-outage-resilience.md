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
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-15T15:43:15Z
      verdict: "changes-requested"
      note: "Original draft review found correctness gaps; findings corrected by the accompanying update, with native acceptance still required."
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-15T15:43:15Z
      mode: "update"
      note: "Reconcile first-release APIs, domain semantics, dependencies and acceptance with the source-validated MP-5 review."
---

# Pipeline backpressure and storage-outage resilience


## Purpose / Big Picture


Keep accepted events durable through storage outages and retries, without counting replayed
events twice. Rate limits protect the queue, and measured recovery capacity defines an honest
operating envelope. Automatic recovery is conditional on PostgreSQL capacity and eventual
storage recovery; no finite system promises arbitrary outage duration.

## Progress


- [ ] M1: Durable event identity and replay-safe analytical reads pass failure/rebatching tests.
- [ ] M2: Writer pauses consumption during outages and resumes with bounded recovery evidence.
- [ ] M3: Archive/backlog instruments and shared credential rate limits pass HTTP tests.
- [ ] M4: Named-hardware ingest and drain benchmarks establish the deployment envelope.

## Surprises & Discoveries


The actual raw sort key is `(account_id,event_name,occurred_at,event_id)`, not event ID alone.
`ReplacingMergeTree` does not deduplicate additive materialized-view counts. The adapter pinned
in `cabal.project` is 0.12.0.0: `maxRetries` counts deliveries before handler execution, zero
archives immediately, and `AckHalt` parks an already-read message. Neither a handler-only
breaker nor AckHalt makes outage retries unlimited. Checked the pinned tag through Mori;
Hackage and upstream tags expose 0.16.1.0 on review day, so do not mistake local HEAD for the pin.

## Decision Log


On 2026-10-15 make `(account,eventId)` an immutable event identity at acceptance, and separate
HTTP retry deduplication from queue redelivery. Finite ClickHouse block tokens are an optional
optimization, never the correctness boundary. Exact metrics deduplicate before aggregation.

## Outcomes & Retrospective


Planning reviewed; no throughput or recovery guarantee has yet been measured.

## Context and Orientation


`Ingest/Producer.hs` currently calls `Pgmq.Effectful.batchSendMessage` independently;
`Writer/Run.hs` constructs the adapter and `Writer/Batch.hs` retries inserts after five seconds.
`ClickHouse.hs` owns the reconnecting writer. Migrations 0004 and 0006 define the raw key and
count-state rollups. Read [ADR-2](../adr/0002-pipeline-observability-readiness-and-writer-recovery.md).
Dependency source is `mori://shinzui/shibuya-pgmq-adapter/packages/shibuya-pgmq-adapter`
(`Shibuya.Adapter.Pgmq.Config` and `Internal`) and
`mori://shinzui/pgmq-hs/packages/pgmq-hasql` (`Pgmq.Hasql.Sessions` and statements).

## Plan of Work


### M1: Durable acceptance and logical event uniqueness


Add `kansoku.accepted_events` keyed by account/event ID, storing a canonical producer-payload
hash and first acceptance time. Hash stable original producer fields, excluding any producer accountId (authentication overrides it), server account,
received time, transport send time and derived enrichment. Canonicalize object ordering.
Validate the original event, then perform deduplication and queue send in one PostgreSQL
transaction on one connection; standalone effect calls do not provide this transaction.
Use the pinned Hasql/PGMQ statement layer (verify the version's exports) or an explicit prepared
statement calling the installed PGMQ SQL API. Identical retries count as accepted in the wire
acknowledgement but do not enqueue or normalize again. Changed payload under the same ID is a
per-event `event_id_conflict` rejection (single 400, batch 202 rejection), not silent overwrite.
Concurrent duplicate submissions and rollback after queue-send failure are required tests.
Retain the minimal acceptance ledger indefinitely in the initial version, including erasure
tombstones; no implicit retry horizon expires event identity. EP-37 documents its storage cost.

Define an internal canonical event source with one row per accepted event before all metrics,
identity and enrichment joins. With immutable acceptance, `events_raw FINAL` collapses queue
redelivery at the existing full key; verify across restart and parts, and keep that implementation
behind a source helper so later benchmarks may replace it without changing semantics.
Rebuild daily count/page-view rollups using exact distinct event-ID states, not additive count
states; sum/average/revenue read canonical rows. No query may rely on background merges having
already happened. Check every builder and downstream view, not only `count(DISTINCT event_id)`.
Enrichment is persisted in the queue once, so replay cannot change group placement.

ClickHouse supports `insert_deduplication_token` through the vendored driver's `passSettings`
and `addSetting`, but a sorted-ID token and a 1000-block window do not cover regrouped or old
replays. Do not make this optimization a prerequisite. If used, test dependent-view settings
and ambiguous insert acknowledgements on the packaged version. See
[ClickHouse retry deduplication](https://clickhouse.com/docs/guides/developer/deduplicating-inserts-on-retries).

### M2: Pause the source, recover storage


Place the breaker before the adapter reads new messages, not only inside the batch callback.
Wrap the source pull boundary or supervise a clean stop/restart of the processor with a bounded
in-flight batch; inspect the pinned source API before choosing. On transient connection/timeout
failure, retain the batch, release/renew leases safely and pause further pulls. Probe with a
separate owned connection every five seconds; a successful ping permits an insert attempt,
whose failure reopens the breaker. No valid event may archive solely because storage is down.
Use a non-exhausting delivery policy for infrastructure failures (the current adapter's finite
maxRetries cannot express it); an adapter change must be an explicit prerequisite, or configure
a practically non-exhausting maximum with a proven source pause and document the numeric bound.
Malformed queue payloads dead-letter; server SQL/schema errors park and alert instead of
rapidly exhausting valid events. Preserve cancellation and connection invalidation.

Do not promise a ten-minute backlog drains in two flushes. Require first successful write within
probe interval plus visibility delay plus flush latency; total drain follows backlog divided by
measured spare throughput, with a recorded tolerance. Test process restart while the breaker
is open and an insert committed just before its acknowledgement was lost.

### M3: Limits and observability


Publish archive size, breaker state and recovery failures alongside queue age/length. Implement
rate admission in the shared ingest service after credential resolution and bounded decoding,
before normalization/quarantine/queue writes. A WAI wrapper outside Servant cannot assume it
already has an authenticated principal. Single, batch and beacon share one token bucket per
credential; charge submitted event count, including invalid events. Defaults: 2000 events/sec,
burst 10000; zero rate explicitly disables; enabled burst must cover maximum allowed batch.
Use monotonic time, bounded idle eviction and atomic updates. State limits are per process;
proxies supply outer request/byte limits. Return retryable 429 `rate_limited`, whole-second
`Retry-After`, and shared OpenAPI/client alternatives. Verify actual SDK 429/backoff behavior.

### M4: Capacity


Add a synthetic load script using disposable credentials and private processes. Measure accepted
rate, newly queued rate, written rate, backlog age, disk growth and drain throughput, naming
hardware and settings. Publish a finite outage capacity estimate and alert thresholds. Reference
hardware measurement remains pending if that machine is unavailable; do not invent a number.

## Validation and Acceptance


Test identical HTTP retries with restamped sentAt, simultaneous duplicates, conflicting IDs,
queue commit rollback, ClickHouse committed-write/lost-ack, restart, different batch boundaries
and archive replay after any block window. Counts, revenue, sessions and traits must remain
unchanged by replay. Compare final values before and after merges. Ten-minute outage under
200 events/sec must archive zero valid events and drain within the measured bound. Cover limits
on all three transports, two keys, bucket eviction and concurrent requests. Tests that only
count distinct IDs cannot establish aggregate correctness.

## Concrete Steps


Run commands from the repository root inside `nix develop`. Use the private databases owned
by `scripts/acceptance.sh` and `Kansoku.ClickHouseTestSupport`, not an ambient development
stack: native fixtures mutate tables. Extend that harness for the scenarios in this plan.

```bash
cabal build all --enable-tests
just openapi
just contracts
just check
just acceptance
```

Use focused Hspec examples while developing. Before marking Complete, require nonzero example
counts, no pending required integration tests, regenerated contract checks, and the packaged
executable acceptance above. Record only the relevant evidence here. This follows
[ADR-10](../adr/0010-owned-executable-acceptance-environments.md).

## Idempotence and Recovery


Backfills of count states are not repeatable by appending. Build replacement tables from canonical data, verify, then swap with writer paused in an owned test. Keep schema-ledger steps explicit and test interrupted migration recovery. Archive replay is operational redelivery, not a new logical event.

## Interfaces and Dependencies


Required complete child artifacts: `docs/plans/29-correct-client-timestamp-skew-and-count-ingest-rejections.md`.

Hard dependency: EP-29 (`docs/plans/29-correct-client-timestamp-skew-and-count-ingest-rejections.md`) Complete. Owns canonical event source, acceptance ledger, writer recovery and admission. EP-32/31 consume canonical reads; EP-37 consumes replay safety. No dependency upgrade is selected by this review; recheck registry and release tags before selecting bounds.

Revision note (2026-10-15): reviewed against the current source and revised for first deployment.
[ADR-11](../adr/0011-initial-release-analytics-contracts.md) records the proposed cross-plan
contracts; implementation must supply the acceptance evidence before those contracts become
accepted runtime guarantees.
