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
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-15T16:02:57Z
      mode: "update"
      note: "Add released Shibuya/adapter/PGMQ upgrade milestone and fresh-install failure acceptance."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-15T16:58:15Z
      mode: "implement"
      note: "Begin released queue baseline, then durable event identity, source outage control and admission/capacity proofs."
---

# Pipeline backpressure and storage-outage resilience


## Purpose / Big Picture


Keep accepted events durable through storage outages and retries, without counting replayed
events twice. Rate limits protect the queue, and measured recovery capacity defines an honest
operating envelope. Automatic recovery is conditional on PostgreSQL capacity and eventual
storage recovery; no finite system promises arbitrary outage duration.
Start by upgrading the released Shibuya and PGMQ stack so the writer benefits from corrected
acknowledgement and lifecycle behavior. Kansoku is not used anywhere: target a fresh deployment,
without staged rollout, legacy compatibility or downstream release coordination.

## Progress


- [x] M0: Released Shibuya/adapter/PGMQ baseline builds and passes fresh-install and writer lifecycle checks.
- [x] M1: Durable event identity and replay-safe analytical reads pass failure/rebatching tests.
- [x] M2: Writer pauses consumption during outages and resumes with bounded recovery evidence.
- [x] M3: Archive/backlog instruments and shared credential rate limits pass HTTP tests.
- [x] M4: Named-hardware ingest and drain benchmarks establish the deployment envelope.

## Surprises & Discoveries


M0 release verification (2026-10-15): Hackage preferred metadata and upstream tags select
`mori://shinzui/shibuya/packages/shibuya-core` 0.10.0.1 (tag commit
`a083b8fbdc1ba57e7d01b12b445f3fdaa15d90d8`),
`mori://shinzui/shibuya-pgmq-adapter/packages/shibuya-pgmq-adapter` 0.16.1.0
(`8a8b60dfe8cfb4e5f6e818bfcce4066bb0fb7347`), and the four
`mori://shinzui/pgmq-hs` packages 0.6.1.1 (`696b6bd28f29e1ea53d07bf66d2d6d59f1182fa3`).
Both build paths select these versions. Nix uses compatible effectful/core 2.6.1.0;
Cabal selects effectful 2.7.1.0/core 2.7.1.2. No newer checkout-only API is consumed.

The native commit-loss fixture exposed that a dropped libpq result can surface as an empty
server error, which the adapter does not classify as transient. Shibuya's finalizer retry
still retries the same failed acknowledgement, and the transactional source-row claim avoids
a second DLQ insert. The regression exercises that real path, rather than repeating a
successful in-memory acknowledgement handle. Failure snapshots are inspected under
IgnoreFailures so the supervisor's linked exception cannot interrupt the assertion; the
production writer retains StopAllOnFailure. A blocked insert shutdown exposed the narrower
AsyncException catch; it now propagates SomeAsyncException, including AsyncCancelled.

M1 uses `analytics.events_canonical` as the internal database source helper. A default
ClickHouse asterisk omits materialized columns, so its explicit `properties_json` projection
is necessary for the existing seven-column resolved contract and property SQL. Exact-ID states
replace count states through verified replacement tables and atomic name swaps in a new
writer-stopped administrative migration. Native corruption checks refuse publication, and
interruption before verification, between swaps, and before trigger recreation recovers on reapply. Native replay beyond 1000 intervening insert blocks and a real
ClickHouse restart also passes, independent of block tokens. Current built-in count, page-view,
revenue, average, user and session queries retain their values before/after regrouped replays
and merges. Trait analytics is introduced by the later trait child and must consume this
canonical boundary rather than introduce an insert-time additive projection.

The acceptance ledger hashes original JSON with Aeson's lossless RFC8785 encoder (available
since 2.2.1.0; Nix resolves 2.2.4.1 and Cabal 2.2.5.1; current upstream/Hackage preferred is
2.3.2.0). It excludes receive/send clocks and ignored producer account, while preserving unknown
producer content in the hash. Validation/normalization is lazy and skipped for known equal
payloads. Claims and sends share one Hasql transaction; stable key order avoids opposing batch
lock order. Native tests cover concurrent equal/conflicting IDs, rollback, tombstones and a
real discarded acceptance-COMMIT response. Only hash/identity/time/tombstone metadata persists.

M2's released source wrapper must cancel an in-progress pull when the breaker opens:
`Stream.uncons` can otherwise continue the adapter's internal empty polling even when no new
outer pulls occur. Its wake/cancel race is covered by an explicit empty-poll regression.
Prefetch is disabled; serial processing retains one unchanged batch, native batch lease renewal
avoids per-message roundtrips, and the inbox is one element. A single already-issued read can
finish at the transition; the released batcher also has a one-batch ready-output buffer. A conservative per-process
retained-delivery bound for the single constant key is `2 * writerBatch + adapterBatch + 3`
(active handler, ready batch or accumulator, adapter chunk, inbox/producer handoff). At tested
settings this is 11003, with 22006 across one restart. The native run's observed 7200 reads
also passes its original stricter 12002 fixture assertion; the general bound must include that
batcher output buffer rather than treating the inbox as the only background buffer.
Storage probes use a separate owned connection every five seconds, and only a successful
insert reopens pulls. Server errors park/alert at state 2 and retry on that cadence. The
adapter maximum is Int64 maxBound (9223372036854775807); native PGMQ read_ct is a finite Int32,
so this is a practically non-exhausting delivery policy, not an infinite-storage/delivery claim.
Read-count overflow would fail rather than auto-archive a valid event. Ordinary outage retry
holds/renews the batch instead of consuming additional deliveries.

The native smoke proof (`.dev/acceptance/outage-5rlhhwgm/report.json`, private ignored evidence)
passes schema parking/repair, malformed-payload archive, source quiescence, real process restart,
8000 accepted events and zero valid archives. Its outage lasted 51.8 seconds including restart;
first recovered write was 3.90 seconds and drain 54.31 seconds. Old-process leases explain the
longer final drain. This does not discharge the required 600-second/200-events-per-second proof;
`just outage-acceptance` owns that separate, non-skipping duration gate. Both it and
`just outage-smoke` run the packaged server against Haskell-owned ephemeral PostgreSQL and
private ClickHouse/proxy processes, with measured calibration-based drain bounds and disk data.

The actual raw sort key is `(account_id,event_name,occurred_at,event_id)`, not event ID alone.
`ReplacingMergeTree` does not deduplicate additive materialized-view counts. The adapter pinned
in `cabal.project` is 0.12.0.0: `maxRetries` counts deliveries before handler execution, zero
archives immediately, and `AckHalt` parks an already-read message. Neither a handler-only
breaker nor AckHalt makes outage retries unlimited. Checked the pinned tag through Mori;
Hackage and upstream tags expose 0.16.1.0 on review day, so do not mistake local HEAD for the pin.
The selected adapter release still has finite delivery-count-based maxRetries. Shibuya's local
checkout has pauseProcessor/resumeProcessor, but they are absent from released core 0.10.0.1.
PGMQ's local checkout also contains unreleased inspection/error-classification APIs; use the
selected release source when implementing this plan.

## Decision Log


On 2026-10-15 make `(account,eventId)` an immutable event identity at acceptance, and separate
HTTP retry deduplication from queue redelivery. Finite ClickHouse block tokens are an optional
optimization, never the correctness boundary. Exact metrics deduplicate before aggregation.

On 2026-10-15 select shibuya-core 0.10.0.1, shibuya-pgmq-adapter 0.16.1.0 and
pgmq-core/hasql/effectful/migration 0.6.1.1 as M0, before M1–M4. These published releases
fix failure paths relevant to this plan. The adapter requires core ^>=0.10.0.0 and PGMQ ^>=0.6,
so updating all six local pins is required dependency resolution, not a coordinated rollout.
Use the released APIs directly; no external consumer or SDK release blocks this upgrade.

## Outcomes & Retrospective


All milestones are accepted. The released queue lifecycle, permanent acceptance identity,
canonical replay-safe analytics, pre-pull storage gate, bounded credential admission and named
hardware measurement are implemented. The ten-minute outage preserves all 120000 logical events
through restart, first write in 2.48 seconds and drain in 21.21 seconds, with zero valid archives.
The deployment envelope remains finite and hardware/workload-specific. Later children consume
`IngestService`, `events_canonical`, shared typed 429 and the queue dependency baseline. Beacon
endpoint conformance is explicitly owned by EP-39. No deployed-data compatibility is introduced.

## Context and Orientation


`Ingest/Producer.hs` currently calls `Pgmq.Effectful.batchSendMessage` independently;
`Writer/Run.hs` constructs the adapter and `Writer/Batch.hs` retries inserts after five seconds.
`ClickHouse.hs` owns the reconnecting writer. Migrations 0004 and 0006 define the raw key and
count-state rollups. Read [ADR-2](../adr/0002-pipeline-observability-readiness-and-writer-recovery.md).
Dependency source is `mori://shinzui/shibuya-pgmq-adapter/packages/shibuya-pgmq-adapter`
(`Shibuya.Adapter.Pgmq.Config` and `Internal`) and
`mori://shinzui/pgmq-hs/packages/pgmq-hasql` (`Pgmq.Hasql.Sessions` and statements).
Core is `mori://shinzui/shibuya/packages/shibuya-core`; the other required PGMQ packages are
`mori://shinzui/pgmq-hs/packages/pgmq-core`,
`mori://shinzui/pgmq-hs/packages/pgmq-effectful` and
`mori://shinzui/pgmq-hs/packages/pgmq-migration`.
`cabal.project` and the Hackage overrides in `flake.module.nix` currently pin core 0.8.0.1,
adapter 0.12.0.0 and all four PGMQ packages 0.4.0.1. Both build paths must move to the same
selected versions. `kansoku-core/src/Kansoku/Migrations.hs` composes the native PGMQ and
application migration components; `kansoku-core/test/Kansoku/MigrationsSpec.hs` already
tests fresh installation, verification and repeat application.

## Plan of Work


### M0: Adopt the released queue-processing baseline


Set shibuya-core to 0.10.0.1, shibuya-pgmq-adapter to 0.16.1.0 and pgmq-core,
pgmq-hasql, pgmq-effectful and pgmq-migration to 0.6.1.1 in `cabal.project` and
`flake.module.nix`, obtaining the corresponding Hackage source hashes. Verify the selected
package metadata against the upstream release tags using Mori-located sources; do not consume
unreleased checkout APIs or bypass incompatible bounds with allow-newer. These releases were
verified on 2026-10-15; if implementation selects a newer release, record its API review and
update both build paths explicitly. No additional Shibuya metrics package is needed.

Adapt the writer and affected tests to the released APIs. In
`kansoku-core/src/Kansoku/Writer/Run.hs`, the existing direct ShutdownConfig construction only
sets drainTimeout; the new core also requires a finite totalShutdownTimeout. Use the public
default with explicit timeout overrides and test bounded shutdown. Review exhaustive matches
and direct record construction affected by ApplicationFailure, ProcessorState.Processing,
ProcessorFailure and QueueMetrics.defaultPartitionLength. PGMQ visibility-timeout updates
now return Maybe Message: absence after deletion is a normal race, not a database failure.
Queue names must be lowercase ASCII letters, digits or underscore, length 1–47;
`kansoku_events` already complies. Change only actual call sites and fixtures that need it.

Use pgmq-migration's native migration component to install its PGMQ 1.13 SQL baseline on an
empty owned PostgreSQL database. Verify and reapply the migration ledger without new work,
then create a queue and exercise send/read/acknowledgement through the real adapter. Keep
explicit administrative migration ownership; do not add normal-startup DDL or a requirement
to install the PostgreSQL extension separately. There is no deployed schema to preserve or
mixed-version fleet to support. Do not add legacy migration/remediation exercises. Existing
local development data may be recreated through an explicitly chosen disposable test setup.

Prove the fixes at Kansoku's writer boundary: exhausted acknowledgement failure is visible
as processor failure rather than clean completion; cancellation and repeated stop terminate
within the configured deadline; and normal acknowledgement removes the source message.
Exercise ambiguous-commit dead-letter retry without duplicating the dead-letter message,
using an owned PostgreSQL fault fixture. Reuse existing
native harnesses and record non-skipped evidence. This milestone does not assert exactly-once
ClickHouse effects or outage safety; M1/M2 must prove those separately.

### M1: Durable acceptance and logical event uniqueness


Add `kansoku.accepted_events` keyed by account/event ID, storing a canonical producer-payload
hash and first acceptance time. Hash stable original producer fields, excluding any producer accountId (authentication overrides it), server account,
received time, transport send time and derived enrichment. Canonicalize object ordering.
Validate the original event, then perform deduplication and queue send in one PostgreSQL
transaction on one connection; standalone effect calls do not provide this transaction.
Use the M0-upgraded Hasql/PGMQ statement layer (verify the version's exports) or an explicit prepared
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
in-flight batch; inspect the M0-selected released source API before choosing. Do not call the
unreleased pauseProcessor/resumeProcessor API or wait for its publication. Disable adapter
prefetch unless the implementation proves its background reads obey the same pause boundary;
stopping downstream stream pulls alone does not establish that. On transient connection/timeout
failure, retain the batch, release/renew leases safely and pause further pulls. Probe with a
separate owned connection every five seconds; a successful ping permits an insert attempt,
whose failure reopens the breaker. No valid event may archive solely because storage is down.
Use a non-exhausting delivery policy for infrastructure failures (the current adapter's finite
maxRetries cannot express it). With the selected released adapter, configure a practically
non-exhausting maximum with a proven source pause and document the numeric bound; do not make
an upstream release a prerequisite. Retain the explicit finite-capacity qualification.
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

The shared Beacon service adapter is tested here against the same credential bucket; public
beacon HTTP credential/origin and normalization/persistence scenarios belong to its owning
`docs/plans/39-beacon-ingest-route-for-page-exit-delivery.md`, after this whole-child prerequisite.
This preserves the declared dependency graph without pretending the route already exists.

### M4: Capacity


Add a synthetic load script using disposable credentials and private processes. Measure accepted
rate, newly queued rate, written rate, backlog age, disk growth and drain throughput, naming
hardware and settings. Publish a finite outage capacity estimate and alert thresholds. Reference
hardware measurement remains pending if that machine is unavailable; do not invent a number.

## Validation and Acceptance

M0 accepted 2026-10-15: `nix develop -c just check` and `nix develop -c just acceptance`
both pass. The packaged run (`.dev/acceptance/run-0h9ar5ed/sanitized`, private ignored
evidence) executes 185 core examples including all four new owned PostgreSQL lifecycle
examples, 16 client examples, four production probes, native recovery/limit suites and
45 Hurl requests with no required skips or pending cases. Fresh migrations strictly verify
and reapply without work. Nix evaluation and Cabal's build plan agree on all six selected
queue packages. The production writer handles the new finite total shutdown budget.



M1 accepted 2026-10-15: developer checks pass; the final packaged run
`.dev/acceptance/run-k9dxz19h/sanitized` passes 195 core examples, 16 client examples,
four probes, native recovery/limits/replay and 45 Hurl requests, without required skips/pending.
The new ledger cases cover lazy normalization on equal retries, tombstones, concurrent equal
and conflicting submissions, reversed batch lock order, queue-send rollback and a real lost
PostgreSQL acceptance-COMMIT result. Packaged HTTP checks concurrently restamp delivery clocks
and confirm one unchanged physical queue/writer result and indexed conflicts. Native analytical
checks preserve count, page-view, revenue, average, identity and session values before merges;
the lost-insert-confirmation test commits natively before injecting its failure and redelivery.
A separate owned ClickHouse test executes 1001 intervening insert blocks, restarts the real
server, replays old rows, rejects corrupt replacement states before publication, and recovers
from interruption before verification, between atomic swaps and before trigger recreation.
Existing query-pool fault fixtures now apply real migrations rather than assuming a raw-only
schema. No insert deduplication token/window is used as a correctness dependency.

M0 requires agreement between Cabal's resolved build plan and Nix's packaged dependency
versions, successful fresh native migrations and repeat verification, a real queue roundtrip,
and the acknowledgement/lifecycle failure cases above. Run both developer checks and packaged
acceptance. No rolling deployment, older-client matrix or existing-production-data conversion
is required. All milestones remain incomplete until their executable checks pass.

Test identical HTTP retries with restamped sentAt, simultaneous duplicates, conflicting IDs,
queue commit rollback, ClickHouse committed-write/lost-ack, restart, different batch boundaries
and archive replay after any block window. Counts, revenue, sessions and traits must remain
unchanged by replay. Compare final values before and after merges. Ten-minute outage under
200 events/sec must archive zero valid events and drain within the measured bound. Cover limits
on all three transports, two keys, bucket eviction and concurrent requests. Tests that only
count distinct IDs cannot establish aggregate correctness.

M3 implementation checks (2026-10-15): `just check` passes 178 deterministic core examples,
16 client examples, four probes, generated OpenAPI/catalog, strict ADRs and all telemetry modes.
Owned PostgreSQL HTTP admission includes four concurrent requests, independent credentials on
one account, charge for invalid events, retry headers/CORS and unchanged normalization,
quarantine/ledger/queue state on denial. The browser consumer fixture (`just sdk-rate-limit`)
passes at `mori://shinzui/kansoku-ts/packages/kansoku-js`, revision
`f57bc4ef378d60adbd08c81ccf69a2268d368167`: two 429 retries preserve IDs and exponential
scheduling. That SDK currently ignores Retry-After; the Haskell client's real HTTP test honors
its one-second lower bound. Packaged acceptance also passes in `.dev/acceptance/run-hjkdqtkv/sanitized`: 207 core,
17 client, four probe examples and 45 Hurl requests, native recovery/limit/replay and all telemetry
modes, with no required pending cases. The native committed-insert/lost-confirmation example
also exercises the retained recovery callback before successful acknowledgement. M2/M4 are accepted by `just outage-acceptance`, one required example with no failures/pending:
`.dev/acceptance/outage-mk1fy7bw/report.json` records 120000 events over 600.005 seconds at
200/s, real restart, frozen reads 200/7200, zero valid archives, first recovered write 2.477
seconds and drain 21.211 seconds versus 336.280-second bound. Apple M1 Max/64 GiB/macOS 26.7
calibration including probe startup is 870.94 events/s; actual logical drain is 5657.44/s.
Database growth is 146194432 bytes; generated WAL 416709088 bytes; oldest backlog 600.17 seconds.
The successful writer counter is 121049 because leases can redeliver buffered payloads; canonical
logical count and acceptance ledger are both exactly 120000. The named-workload report,
finite 10-GiB/50%-headroom example and alert thresholds are in `docs/guides/capacity.md`.
Other reference hardware is explicitly unmeasured. The run passed the original stricter 12002
cross-restart read bound; the reusable harness now derives its conservative 22006 bound from
the released ready-batch buffer as well, with production code unchanged after acceptance.

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
just outage-acceptance
```

Use focused Hspec examples while developing. Before marking Complete, require nonzero example
counts, no pending required integration tests, regenerated contract checks, and the packaged
executable acceptance above. Record only the relevant evidence here. This follows
[ADR-10](../adr/0010-owned-executable-acceptance-environments.md).

## Idempotence and Recovery


Backfills of count states are not repeatable by appending. Build replacement tables from canonical data, verify, then swap with writer paused in an owned test. Keep schema-ledger steps explicit and test interrupted migration recovery. Archive replay is operational redelivery, not a new logical event.

## Interfaces and Dependencies


Required complete child artifacts: `docs/plans/29-correct-client-timestamp-skew-and-count-ingest-rejections.md`.

Hard dependency: EP-29 (`docs/plans/29-correct-client-timestamp-skew-and-count-ingest-rejections.md`) Complete. Owns canonical event source, acceptance ledger, writer recovery and admission. EP-32/31 consume canonical reads; EP-37 consumes replay safety. M0 owns the selected released dependency upgrades and precedes M1–M4; there is no SDK or upstream-release prerequisite.

Revision note (2026-10-15): reviewed against the current source and revised for first deployment.
[ADR-11](../adr/0011-initial-release-analytics-contracts.md) records the proposed cross-plan
contracts; implementation must supply the acceptance evidence before those contracts become
accepted runtime guarantees.

Revision note (2026-10-15, dependency follow-up): add M0 with explicit released versions,
Cabal/Nix consistency, source adaptations and fresh-install failure checks. The owner's
pre-deployment scope removes rollout/legacy compatibility work; source pausing remains M2's
responsibility because the selected release does not expose the unreleased control API.
