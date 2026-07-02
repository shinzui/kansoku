---
id: 4
slug: ingestion-api-with-pgmq-queue-and-batched-clickhouse-writer
title: "Ingestion API with pgmq queue and batched ClickHouse writer"
kind: exec-plan
created_at: 2026-07-01T16:04:44Z
intention: "intention_01kwf425fxenc904ear54cr2n7"
master_plan: "docs/masterplans/1-kansoku-analytics-service-mvp.md"
---

# Ingestion API with pgmq queue and batched ClickHouse writer

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Kansoku (観測, "observation") is a self-hostable analytics service. This plan builds its
high-throughput write path: the part that turns an HTTP request carrying an analytics event
into a durable row in ClickHouse, sustaining a very high write rate. It is the single most
performance-critical plan in the whole project, and the reason the service is not
event-sourced: analytics ingestion is write-volume-bound, so we amortize the cost of each
ClickHouse write across thousands of rows.

After this plan is implemented, a person running Kansoku locally can do the following and see
it work:

1. Start PostgreSQL and ClickHouse with `process-compose up` and run the `kansoku-server`
   binary.
2. Send one event: `curl -X POST http://localhost:8080/v1/events -H 'content-type: application/json' -d '<one JSON event>'`
   and receive HTTP `202 Accepted` with a small JSON acknowledgement.
3. Send many events at once: `curl -X POST http://localhost:8080/v1/batch -H 'content-type: application/json' -d '[ <event>, <event>, ... ]'`
   and receive `202 Accepted` with a count.
4. A moment later, run `clickhouse-client --query 'SELECT count() FROM analytics.events_raw FINAL'`
   and observe the row count increase by exactly the number of accepted events.

The user-visible behavior enabled is durable, validated, batched event ingestion over HTTP.
Under the hood the HTTP handler does **not** write to ClickHouse directly. Instead it validates
each event and enqueues it onto a PostgreSQL-backed message queue named `kansoku_events`
(using the `pgmq` message-queue implemented purely as SQL functions inside PostgreSQL). A
separate consumer — built on the `shibuya` message-processing framework using its new
**batch** capability — pulls events off that queue in large groups, decodes them, and performs
**one** ClickHouse `INSERT` per group. "One INSERT per group, never one event at a time" is
the whole point.

Because the queue-delete and the ClickHouse-insert are not one transaction, delivery is
*at-least-once*: a crash after a successful insert but before the queue acknowledgement will
redeliver and re-insert a batch. This plan relies on the deduplication built by the storage
plan (a `ReplacingMergeTree` table keyed on `eventId`) so that replayed rows collapse on merge
and queries using `FINAL` never see duplicates. The end-to-end demonstration in this plan
proves that replaying a batch does not increase the deduplicated row count.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Milestone 0: precondition confirmed — the local shibuya checkout (on `master`, at or
      after commit `8a91e83`) contains `shibuya-core/src/Shibuya/Batch.hs` (with
      `BatchHandler`, `BatchConfig`, `BatchAck`, smart constructors) and
      `Shibuya.App.mkBatchProcessor`; verified by the file-existence and
      `git merge-base --is-ancestor` checks in Milestone 0 (NOT by a version bound — the
      feature is unreleased). This milestone verifies checkouts only; Milestone 1 owns all
      `cabal.project` edits.
- [x] Add the three author libraries (`pgmq-hs`, `shibuya`,
      `shibuya-pgmq-adapter`) to `cabal.project` as local `packages:` entries plus the
      `source-repository-package` pin for `shinzui/hasql-migration` (tag `4aaff6c`); add their
      component libraries plus `servant`/`servant-server`/`hasql`/`hasql-pool` to
      `kansoku.cabal` `build-depends`; verified by `cabal build all`.
- [x] Extend `Kansoku.Config` with pgmq connection + queue settings; add a shared connection
      pool and tracer to the runtime.
- [x] Add `Kansoku.Ingest.Queue` (queue name constant + JSON message encoding + bootstrap:
      `migrate` then `createQueue`).
- [x] Milestone 1: declare the servant API type `IngestAPI` (`POST /v1/events`, `POST /v1/batch`)
      in `Kansoku.Api.Ingest` (in the shared `kansoku:kansoku-api` sub-library), then
      `Kansoku.Ingest.Producer` + the handler module `Kansoku.Ingest.Handler` validate and
      enqueue; verified by the live server returning HTTP 202 for valid single and batch
      requests and HTTP 400 for an invalid event.
- [x] Milestone 2: `Kansoku.Writer.Batch` (`writerBatchHandler` + `pgmqAdapter` +
      `mkBatchProcessor` + `runApp`) consumes the queue and performs one `insertEvents` per
      flushed batch; verified by rows appearing in `analytics.events_raw`.
- [x] Milestone 3: wire both the HTTP server (warp) and the writer (`runApp`) into the
      `kansoku-server` executable running concurrently; end-to-end demo (POST → queryable row).
- [x] Milestone 3: at-least-once / dedup demonstration — replay a batch and confirm the
      `SELECT count() ... FINAL` count does not increase.
- [x] Automated tests: unit test for message encode/decode round-trip; guarded writer
      integration test asserts a batch lands in ClickHouse when ClickHouse is reachable.
- [x] Final verification: `nix fmt`, `cabal build all`, `cabal test`, `nix build .#default`,
      and `git diff --check` pass.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-07-01: Milestone 0 is satisfied in the local checkout. Evidence:
  `test -f /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/shibuya-core/src/Shibuya/Batch.hs`
  succeeded, `git -C /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya merge-base
  --is-ancestor 8a91e83 HEAD` succeeded, and the checkout is on `master` at
  `bdfccae3aee883c232457c788c495d28a73ec6e3`.

- 2026-07-01: Some older prose in this plan predates the implemented EP-1/EP-2 layout. The
  canonical event modules are under the shared `api/Kansoku/Event*.hs` tree, and the servant
  ingestion API type must be created as `api/Kansoku/Api/Ingest.hs` in the
  `kansoku:kansoku-api` sub-library, not under `src/`. The existing HTTP config field is
  `serverPort` / `KANSOKU_SERVER_PORT`; EP-4 keeps that field instead of adding a second
  `httpPort` alias.

- 2026-07-02: The current ClickHouse CLI rejects `--path=...` when it is passed before the
  `--` separator. Passing `-- --path=...` works, but ClickHouse then writes generated
  `access/` and `preprocessed_configs/` directories relative to the process working
  directory. `process-compose.yaml` now starts ClickHouse from `$CLICKHOUSE_HOME` and passes
  the path after `--`, so all generated files stay under `clickhouse/`.

- 2026-07-02: The Nix build needed an explicit overlay for EP-4's local and pinned Haskell
  dependencies. In particular, `warp` must be built with its `x509` cabal flag disabled to
  avoid the older `x509`/`crypton-x509` solver conflict, and `pgmq-migration` needs its
  package-local `vendor` symlink recreated during `postPatch` so Template Haskell can embed
  the pgmq SQL files. Evidence: `nix build .#default` completed successfully after these
  overrides.


## Decision Log

Record every decision made while working on the plan.

- Decision: The queue is named `kansoku_events` and each message body is a
  `Data.Aeson.Value` holding exactly one JSON-encoded `AnalyticsEvent` (the same JSON used by
  the HTTP contract).
  Rationale: This plan owns the queue name and body encoding as a MasterPlan integration
  point. One event per message keeps the producer trivial (`toJSON` per event) and lets the
  writer decode messages independently, so a single undecodable message can be dead-lettered
  without poisoning a whole batch. `kansoku_events` is 14 characters and only uses
  alphanumerics and underscore, satisfying `pgmq`'s `parseQueueName` limit (≤47 characters,
  `[A-Za-z0-9_]`).
  Date: 2026-07-01

- Decision: The HTTP handler is the producer and produces with `pgmq-hs` directly
  (`sendMessage` for `/v1/events`, `batchSendMessage` for `/v1/batch`); only the writer uses
  shibuya.
  Rationale: shibuya is consumer-only (it has no produce API). This matches the MasterPlan's
  recorded discovery and splits the plan cleanly into producer (pgmq-hs) and consumer
  (shibuya).
  Date: 2026-07-01

- Decision: On a successful ClickHouse insert, the writer acknowledges every decodable message
  as `AckOk` and dead-letters only messages whose body failed to decode into an
  `AnalyticsEvent`. On an insert failure, the writer acknowledges nothing for the decodable
  messages (it returns a retry decision so `pgmq` redelivers them) while still dead-lettering
  the undecodable ones.
  Rationale: Redelivery after a failed insert is safe because the storage layer deduplicates on
  `eventId` (`ReplacingMergeTree`). Dead-lettering undecodable messages prevents an infinite
  redelivery loop of a permanently-broken payload while never dropping good data.
  Date: 2026-07-01

- Decision: Start with a single batch accumulation group (`batchKey = const defaultBatchKey`)
  and `Serial` batch execution — one ClickHouse `INSERT` in flight at a time, maximally large
  batches — with recommended tuning `BatchConfig.batchSize = 5000`, `BatchConfig.batchTimeout =
  5s`, `tickInterval = Nothing`, pgmq adapter `PgmqAdapterConfig.batchSize = 1000`, and
  `visibilityTimeout = 60s`. Note the naming collision: `BatchConfig.batchSize` (ClickHouse flush
  size) and `PgmqAdapterConfig.batchSize` (rows per pgmq poll) are separate knobs sharing a field
  name. The documented scaling path to concurrent inserts is a bucketing `batchKey` (hash the
  message into N buckets) plus `Async N`.
  Rationale: A single group produces the largest possible per-INSERT batches, which is the
  throughput goal, and accumulation is already pipelined against execution (the batcher keeps
  filling the next batch while the current INSERT runs). `visibilityTimeout` (60s) must exceed
  `batchTimeout` (5s) plus insert time plus ack time or messages redeliver mid-flight; 60s leaves
  a wide margin. Concurrency across batches only helps when there are multiple batch keys
  (shibuya serializes same-key batches for order), and analytics events need no ordering, so
  bucketing is the correct — but secondary — scaling lever.
  Date: 2026-07-01

- Decision: This plan owns adding `pgmq-hs`, `shibuya`, and `shibuya-pgmq-adapter` to
  `cabal.project` as local filesystem `packages:` entries (absolute paths), not
  `source-repository-package` git stanzas.
  Rationale: The MasterPlan records that EP-4 owns this extension point and that these are not
  on Hackage. Local paths are the simplest for MVP and let changes in the libraries be picked
  up without a git push. The tradeoff — the build is coupled to the local checkout layout — is
  accepted for now and noted so a later plan can switch to pinned git stanzas for
  reproducibility.
  Date: 2026-07-01

- Decision: `receivedAt` on every event is set server-side to the ingestion time; `occurredAt`
  is preserved as sent by the client.
  Rationale: `receivedAt` is Kansoku's own observation timestamp and must be trustworthy;
  `occurredAt` is the client's account of when the thing happened and must be preserved for
  time-series accuracy.
  Date: 2026-07-01

- Decision: The external shibuya batch dependency has shipped, so the plan now targets the real,
  confirmed `Shibuya.Batch` API instead of the previously-frozen (assumed) signatures.
  The shibuya `master` checkout (commit `8a91e83` or later) exposes `Shibuya.Batch` and
  `Shibuya.App.mkBatchProcessor` (shibuya masterplan EP-16..EP-21 Complete); note the feature is
  **unreleased** — the `v0.7.1.0` tag predates it and Hackage carries only 0.7.0.0 — so its
  presence is proven by checkout contents, never a version bound (see Milestone 0 and the
  dedicated decision below). Concretely: `BatchHandler es msg` takes `BatchInfo` **first**
  then `NonEmpty (Ingested es msg)`; `BatchConfig`'s fields are `batchSize`/`batchTimeout`/
  `batchKey`/`tickInterval` (NOT the assumed `maxSize`/`maxLatency`); and the insert-failure +
  dead-letter case uses `withFallback (AckRetry …) badOverrides` (a custom `AckRetry` fallback),
  since `ackExcept`'s fallback is fixed at `AckOk` and cannot express retry.
  Rationale: The dependency is now real code, so the plan should compile against actual
  signatures rather than a frozen spec that carried unresolved field-name/argument-order caveats.
  Milestone 0 is correspondingly demoted from a blocking gate to a satisfied precondition.
  Date: 2026-07-01

- Decision: The shibuya batch feature is consumed from the local `master` checkout via the
  `packages:` entry pointing at
  `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/shibuya-core`, and its presence is
  verified by checkout **contents** — `test -f .../shibuya-core/src/Shibuya/Batch.hs` plus
  `git -C .../shibuya merge-base --is-ancestor 8a91e83 HEAD` — never by a cabal version bound.
  Rationale: The `v0.7.1.0` git tag contains no `Shibuya/Batch.hs`, shibuya-core's `version:`
  field was never bumped past 0.7.1.0, and Hackage carries only shibuya-core 0.7.0.0 (no
  batching). A constraint like `shibuya-core >= 0.7.1` is therefore satisfiable by code that
  lacks the feature and proves nothing; the content check is the only reliable proof. Commit
  `8a91e83` is the commit at which the batch stack is complete.
  Date: 2026-07-01

- Decision: MVP dead-letter posture — leave `deadLetterConfig = Nothing` (the adapter default)
  and accept **archive-as-DLQ**. With no DLQ configured, an `AckDeadLetter` finalize decision
  ARCHIVES the message to pgmq's archive table (`pgmq.a_kansoku_events`), so dead-lettered
  payloads are preserved and observable via SQL, not dropped. Independently, the adapter
  auto-dead-letters (archives) a message **on ingest** once its `readCount` exceeds
  `maxRetries` (default 3); that retry budget is adapter-owned, not handler logic.
  Rationale: The archive table already gives everything the MVP needs from a dead-letter queue
  (a durable, queryable quarantine) with zero extra configuration or queues. A dedicated DLQ
  queue can be added later by setting `deadLetterConfig`, without touching handler code.
  Date: 2026-07-01

- Decision: `BatchConfig.batchTimeout` is **5 seconds**, not 1 second (config default
  `writerMaxLatencyMs = 5000`); `visibilityTimeout` stays 60 s.
  Rationale: Each flush is one ClickHouse INSERT and each INSERT creates a part. At low traffic
  a 1 s timeout means up to one small insert per second per table — right at ClickHouse's
  recommended sustained insert ceiling and a source of merge pressure. 5 s costs only
  queryability latency, which is not a product requirement for analytics, and cuts worst-case
  part creation 5x. The invariant still holds with wide margin: `visibilityTimeout` (60 s) ≫
  `batchTimeout` (5 s) + insert time + ack time. The adapter's documented constraint
  `bufferSize * batchSize * avgProcessingTime < visibilityTimeout` is also respected by the
  MVP numbers.
  Date: 2026-07-01

- Decision: The sustained-throughput ceiling of this design is **PostgreSQL, not ClickHouse** —
  accepted for the MVP.
  Rationale: Every event is WAL'd on send, read back on poll, and deleted/archived on ack
  (roughly 3x write amplification before ClickHouse ever sees the event). Mitigations are
  documented in Context and Orientation ("Throughput ceiling"): sustained high volume must
  arrive via `POST /v1/batch` + `batchSendMessage` (the single-event endpoint costs one
  Postgres round trip per event); the delete-heavy queue table needs healthy autovacuum;
  pgmq's unlogged-queue option is a documented durability-for-WAL-savings knob (not enabled);
  and shibuya's Kafka adapter is the escape hatch when pgmq saturates.
  Date: 2026-07-01

- Decision: Keep the MVP runtime as one `kansoku-server` process that starts the pgmq-backed
  writer in an async thread beside Warp and cancels it when Warp exits.
  Rationale: The plan's user-visible deliverable is one local binary. Splitting the writer into
  a separate executable would introduce process supervision and deployment choices that are not
  needed to prove the write path. The writer still has a clean `runWriter` entry point, so a
  later production packaging plan can split it without changing the batch handler or API.
  Date: 2026-07-02

- Decision: The writer test is guarded on ClickHouse availability rather than forcing
  ClickHouse to run for every `cabal test`.
  Rationale: The Nix build environment does not provide the process-compose ClickHouse service.
  Guarding the integration spec keeps `nix build .#default` reproducible while still exercising
  the real writer path during local process-compose validation.
  Date: 2026-07-02


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

EP-4 is complete. The implementation adds the shared servant ingestion API, pgmq bootstrap and
producer code, validation-aware HTTP handlers, a shibuya batch writer over the pgmq adapter,
runtime wiring that runs Warp and the writer together, config for queue and writer tuning, and
tests for queue encoding plus the writer batch handler.

Validation:

- `GET /health` returned 200 from the running `kansoku-server`.
- Invalid single-event input returned HTTP 400 with validation details.
- `POST /v1/events` accepted one valid event with HTTP 202.
- `POST /v1/batch` accepted two valid events with HTTP 202.
- After the writer flushed, `SELECT count() FROM analytics.events_raw FINAL` returned `3`.
- Replaying the same two-event batch left the `FINAL` count at `3`, demonstrating the
  at-least-once/dedup boundary.
- `cabal build all`, `cabal test`, `nix fmt`, `nix build .#default`, and
  `git diff --check` all pass.


## Context and Orientation

This section assumes you know nothing about this repository. Read it fully before editing.

### Coding standards

All Haskell in this plan follows the shared Kansoku standards in
`/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/core/` — `standards.md`, `custom-prelude.md`,
`record-patterns.md`, and `multiline-strings.md`. In practice that means: every package uses the
`GHC2024` language edition and the shared `common` cabal stanza (every stanza declares
`import: common`) enabling `DeriveAnyClass`, `DuplicateRecordFields`, `OverloadedLabels`,
`OverloadedStrings`, and `MultilineStrings`; every module imports `Kansoku.Prelude` (the custom
prelude established by EP-1 and exported from the `kansoku:kansoku-api` sub-library, which
re-exports `Text`, `Generic`, aeson's `FromJSON`/`ToJSON`, `Data.Time`, `NonEmpty`, and the
`lens` operators); qualified imports use the postpositive form
(`import Data.Text qualified as Text`, not `import qualified Data.Text as Text`); records use
strict `!` fields with explicit `deriving stock`/`deriving anyclass`/`deriving newtype` clauses
and no field-name prefixes; records are read and updated through generic-lens `#label` syntax —
each such module adds `import Data.Generics.Labels ()` — rather than record-selector or
record-update syntax; and any embedded SQL or other multi-line text is written with `"""..."""`
MultilineStrings. The code sketches below are written to these rules.

### What already exists (dependencies of this plan)

This repository is a greenfield Haskell project built with GHC 9.12.4 and a Nix flake, using
the `effectful` effect system (application code runs in a monad written `Eff es`, where `es`
is a type-level list of capabilities; a capability constraint is written like `IOE :> es`
meaning "the `IOE` effect, which allows `IO`, is available"). Three prior plans have run:

- **EP-1** (`docs/plans/1-project-skeleton-and-application-runtime.md`) created `kansoku.cabal`,
  `cabal.project`, the `Kansoku.*` module namespace, the effectful application runtime, config
  loading from environment variables in `src/Kansoku/Config.hs`, structured logging, and a
  `/health` endpoint. It documented the pattern for adding new effects to the runtime and that
  `cabal.project` is the place to add non-Hackage dependencies.
- **EP-2** (`docs/plans/2-canonical-event-model-and-schema-registry.md`) created
  `src/Kansoku/Event.hs` with the `AnalyticsEvent` record, its `FromJSON`/`ToJSON` instances
  (the on-the-wire JSON contract), and a validation function. EP-2 exports the type
  `AnalyticsEvent` and the validation function
  `validateEvent :: AnalyticsEvent -> Either [ValidationError] AnalyticsEvent` — note the error
  side is a **list** of `ValidationError`s (all failures reported at once), which is exactly
  what feeds the 400 response's `details` array in `Kansoku.Ingest.Handler`. The
  `AnalyticsEvent` fields match the TypeScript `AnalyticsEvent` in `docs/initial-spec.md`:
  `eventId`, `eventName`, `source`, optional `sourceService`, `occurredAt`, `receivedAt`, the
  identity ids (`anonymousId`, `userId`, `organizationId`, `accountId`, `sessionId`), the
  web/UTM fields, the correlation fields, `properties`, and `context`.
- **EP-3** (`docs/plans/3-clickhouse-storage-schema-and-batch-writer.md`) created
  `Kansoku.ClickHouse` with the `analytics.events_raw` table (a `ReplacingMergeTree` keyed on
  `eventId` so duplicate inserts of the same event collapse on merge), the `EventRow` mapping
  type, and a batched insert function referred to here as
  `insertEvents :: Connection -> [AnalyticsEvent] -> IO ()` (confirm the exact name, the
  connection type, and whether it is plain `IO` or an `Eff` action in
  `src/Kansoku/ClickHouse.hs`; if it takes `[EventRow]` rather than `[AnalyticsEvent]`, this
  plan's writer must map events to rows first using EP-3's mapping function). It also documented
  that queries that must not see duplicate rows use the `FINAL` keyword.

The dev environment provides the two datastores. `process-compose.yaml` (at the repository
root) runs `postgres` and `clickhouse`. PostgreSQL is a **unix-socket-only** server: the dev
shell exports `PGHOST=$PWD/db` (a directory holding the socket), `PGDATABASE=kansoku`,
`listen_addresses=''` (no TCP), and a ready-made URI in `PG_CONNECTION_STRING`
(`postgresql://<uri-encoded PGHOST>/kansoku`). ClickHouse listens on TCP port 9000 and HTTP
port 8123 (see `CLICKHOUSE_TCP_PORT` / `CLICKHOUSE_HTTP_PORT`).

### The external dependency: shibuya first-class batch processing (precondition satisfied)

This plan depends on the batch-processing feature of the `shibuya` framework, tracked in
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/docs/masterplans/3-first-class-batch-processing.md`.
That feature has **shipped on shibuya `master`**: the checkout at
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya` exposes the `Shibuya.Batch` module (the
batch handler type `BatchHandler`, `BatchConfig`, `BatchAck` with smart constructors) and the
batching runner constructor `Shibuya.App.mkBatchProcessor`, wired through `runApp`. The shibuya
masterplan's child plans EP-16 through EP-21 are all marked Complete.

**Release caveat — do not trust a version bound.** The batch feature exists only on shibuya
`master`: the `v0.7.1.0` git tag contains no `Shibuya/Batch.hs`, shibuya-core's cabal
`version:` field was never bumped past `0.7.1.0`, and Hackage carries only shibuya-core
`0.7.0.0` (no batching). A `build-depends` constraint like `shibuya-core >= 0.7.1` therefore
proves nothing about the feature's presence. The consumption mechanism is the local `packages:`
entry pointing at `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/shibuya-core` (added
to `cabal.project` in Milestone 1), and the precondition check is on the checkout's
**contents**: `Shibuya/Batch.hs` exists, and the checkout's HEAD contains commit `8a91e83`
(the commit at which the batch stack is complete). Milestone 0 spells out the exact commands.
So this plan's Milestone 0 is a **satisfied precondition**, not a blocking gate: verify the
checkout, then build the writer against the real API quoted below.

One-line fallback note (historical, kept only in case a future version regresses): if a later
`shibuya-core` ever drops `Shibuya.Batch`, the writer can be built by consuming the adapter's
raw per-message stream (`Shibuya.Adapter.source` yields `Ingested es Value`) grouped with the
size-only `Shibuya.Stream.batchStream` plus a custom time-window — but that forfeits supervision,
retry scheduling, metrics, tracing, and graceful-shutdown flush, so it is a last resort only.

### The real, confirmed shibuya batch API this plan targets

These signatures are confirmed against the shipped source
(`shibuya-core/src/Shibuya/Batch.hs` and `Shibuya/App.hs` on shibuya `master`, commit
`8a91e83` or later); use them exactly as written:

```haskell
-- module Shibuya.Batch (shibuya master, commit 8a91e83+; unreleased — see Milestone 0)

type BatchHandler es msg =
  BatchInfo -> NonEmpty (Ingested es msg) -> Eff es BatchAck
  -- NOTE: BatchInfo is the FIRST argument, THEN the NonEmpty batch.

data BatchInfo = BatchInfo
  { batchKey  :: !BatchKey
  , size      :: !Int
  , trigger   :: !BatchTrigger      -- TriggerSize | TriggerTimeout | TriggerFlush
  , partition :: !(Maybe Text)
  }

data BatchConfig es msg = BatchConfig
  { batchSize    :: !Int                        -- flush at this many messages (>=1)
  , batchTimeout :: !NominalDiffTime            -- flush this long after the first message (>0)
  , batchKey     :: !(Envelope msg -> BatchKey) -- const defaultBatchKey for one undivided batch
  , tickInterval :: !(Maybe NominalDiffTime)    -- Nothing => use batchTimeout
  }
defaultBatchConfig :: BatchConfig es msg        -- batchSize=100, batchTimeout=1s, single batch
validateBatchConfig :: BatchConfig es msg -> Either BatchConfigError ()

data BatchAck = BatchAck
  { decisions :: !(Map MessageId AckDecision)   -- per-message overrides
  , fallback  :: !AckDecision                   -- for messages not in `decisions`
  }
ackAllOk     :: BatchAck                                    -- all AckOk
ackAll       :: AckDecision -> BatchAck                     -- one decision for all
ackExcept    :: [(MessageId, AckDecision)] -> BatchAck      -- overrides; fallback AckOk
withFallback :: AckDecision -> [(MessageId, AckDecision)] -> BatchAck  -- overrides + custom fallback
failMessages :: [(MessageId, DeadLetterReason)] -> BatchAck -- dead-letter listed; rest AckOk

-- module Shibuya.App
mkBatchProcessor :: Adapter es msg -> BatchHandler es msg -> BatchConfig es msg -> QueueProcessor es
```

The semantics this plan relies on:

- A `BatchHandler es msg` receives the batch metadata `BatchInfo` **first**, then the **whole
  batch** as a `NonEmpty (Ingested es msg)` (a non-empty list; see below for `Ingested`), and
  returns a `BatchAck`.
- A batch is flushed when it reaches the configured `batchSize` **or** the configured
  `batchTimeout` elapses, whichever comes first. `BatchConfig` carries `batchSize`,
  `batchTimeout`, a required `batchKey` (a pure `Envelope msg -> BatchKey`; use
  `const defaultBatchKey` for one undivided batch, or split into independent concurrent
  sub-batches), and `tickInterval` (`Nothing` uses `batchTimeout`). Same-key batches run in FIFO
  order; different-key batches may run concurrently up to the `Concurrency` bound.
- `BatchAck` is a per-`MessageId` decision map (`decisions`) plus a `fallback` decision. The
  framework iterates its **own** retained `NonEmpty (Ingested es msg)`, looks each message's
  `MessageId` up in `decisions`, applies `fallback` for any not listed, and calls that message's
  idempotent `AckHandle.finalize` exactly once. `MessageId` here is
  `Shibuya.Core.Types.MessageId` (the `Envelope.messageId`). Smart constructors: `ackAllOk` (all
  `AckOk`), `ackAll d` (decision `d` for all), `ackExcept overrides` (listed messages get their
  decision, `fallback = AckOk`), `withFallback fb overrides` (listed messages get their decision,
  everyone else gets `fb`), and `failMessages` (dead-letter the listed ids, rest `AckOk`). This
  plan uses `ackExcept`, `ackAllOk`, `withFallback`, and `ackAll` — see Milestone 2 for the exact
  success/failure cases.

### The shibuya-core types you will touch (these already exist)

These are stable and exist in the current shibuya checkout:

- `Shibuya.Adapter.Adapter es msg` — `{ adapterName :: Text, source :: Stream (Eff es) (Ingested es msg), shutdown :: Eff es () }`.
- `Shibuya.Core.Ingested.Ingested es msg` — `{ envelope :: Envelope msg, ack :: AckHandle es, lease :: Maybe (Lease es) }`.
- `Shibuya.Core.Types.Envelope msg` — has `messageId :: MessageId`, `payload :: msg`, and
  metadata fields. `MessageId` here is `newtype MessageId = MessageId { unMessageId :: Text }`
  (note: this is shibuya's own `MessageId`, distinct from `pgmq`'s `MessageId`).
- `Shibuya.Core.Ack.AckDecision` — `AckOk | AckRetry RetryDelay | AckDeadLetter DeadLetterReason | AckHalt HaltReason`,
  with `RetryDelay { unRetryDelay :: NominalDiffTime }` and
  `DeadLetterReason = PoisonPill Text | InvalidPayload Text | MaxRetriesExceeded`.
- `Shibuya.App.runApp :: (IOE :> es, Tracing :> es) => SupervisionStrategy -> Int -> [(ProcessorId, QueueProcessor es)] -> Eff es (Either AppError (AppHandle es))`,
  `SupervisionStrategy = IgnoreFailures | StopAllOnFailure`, `ProcessorId = ProcessorId Text`.
  Control the running app with `stopAppGracefully :: ShutdownConfig -> AppHandle es -> Eff es Bool`.
- `Shibuya.Policy.Concurrency = Serial | Ahead Int | Async Int` and
  `Shibuya.Policy.Ordering = StrictInOrder | PartitionedInOrder | Unordered`.
- `Shibuya.Telemetry.Effect.Tracing` (an effect) with `runTracing :: OTel.Tracer -> Eff (Tracing : es) a -> Eff es a`
  and `runTracingNoop`.

### The shibuya-pgmq-adapter (this already exists)

`Shibuya.Adapter.Pgmq.pgmqAdapter :: (Pgmq :> es, Error PgmqRuntimeError :> es, IOE :> es, Tracing :> es) => PgmqAdapterConfig -> Eff es (Adapter es Value)`.
The adapter's messages carry a `Data.Aeson.Value` payload — exactly the message body encoding
this plan produces. `PgmqAdapterConfig` has fields including `queueName :: QueueName`,
`visibilityTimeout :: Int32` (seconds), `batchSize :: Int32` (messages read per DB poll),
`polling`, `pollRetry`, `deadLetterConfig :: Maybe DeadLetterConfig`, `maxRetries :: Int64`,
`fifoConfig`, and `prefetchConfig :: Maybe PrefetchConfig`. Build one with
`defaultConfig :: QueueName -> PgmqAdapterConfig` and override fields. When a message's
finalize decision is `AckOk`, the adapter deletes that single message from `pgmq`; on
`AckRetry` it leaves the message to become visible again after its visibility timeout; on
`AckDeadLetter` it routes to the configured DLQ queue when `deadLetterConfig` is set, and with
`deadLetterConfig = Nothing` it **archives** the message to pgmq's archive table
(`pgmq.a_<queue>`), so nothing is silently dropped. Independently of handler decisions, the
adapter auto-dead-letters (archives) a message **on ingest** once its `readCount` exceeds
`maxRetries` (default 3) — the retry budget is adapter-owned and applies before the handler
ever sees the message again. This plan's MVP posture (see Decision Log) is to leave
`deadLetterConfig = Nothing` and treat the archive table as the DLQ.

### The pgmq producer library (this already exists)

From `pgmq-effectful` (`Pgmq.Effectful`): a dynamic effect `Pgmq` with smart operations
including `createQueue :: Pgmq :> es => QueueName -> Eff es ()`,
`sendMessage :: Pgmq :> es => SendMessage -> Eff es MessageId`, and
`batchSendMessage :: Pgmq :> es => BatchSendMessage -> Eff es [MessageId]`. Run the effect with
`runPgmq :: (IOE :> es, Error PgmqRuntimeError :> es) => Pool -> Eff (Pgmq : es) a -> Eff es a`
(from `Pgmq.Effectful.Interpreter`), or the tracing-aware `runPgmqTraced pool tracer` (from
`Pgmq.Effectful`). `Pool` is `Hasql.Pool.Pool`.

The relevant request types (from `Pgmq.Hasql.Statements.Types`, re-exported through the
effectful send functions):

```haskell
data SendMessage      = SendMessage      { queueName :: QueueName, messageBody   :: MessageBody,   delay :: Maybe Delay }
data BatchSendMessage = BatchSendMessage { queueName :: QueueName, messageBodies :: [MessageBody], delay :: Maybe Delay }
type Delay = Int32
```

The message body type (from `Pgmq.Types`): `newtype MessageBody = MessageBody { unMessageBody :: Data.Aeson.Value }`.
Queue names are validated: `parseQueueName :: Text -> Either PgmqError QueueName` (accepts
`[A-Za-z0-9_]`, length ≤ 47). Errors from the effect are thrown through the `Error` effect as
`Pgmq.Effectful.PgmqRuntimeError`.

Bootstrap the pgmq schema **without** the PostgreSQL binary extension using `pgmq-migration`:
`Pgmq.Migration.migrate :: Session (Either MigrationError ())`. Run it with the pool:
`Hasql.Pool.use pool Migration.migrate :: IO (Either UsageError (Either MigrationError ()))`.
This is idempotent — it only applies migrations not already applied. Then create the queue
(idempotent). The reference pattern from the shibuya pgmq example
(`shibuya-pgmq-example/src/Example/Database.hs`):

```haskell
installSchema :: Pool.Pool -> IO ()
installSchema pool = do
  result <- Pool.use pool Migration.migrate
  case result of
    Left err          -> error $ "Migration session error: " <> show err
    Right (Left err)  -> error $ "Migration error: " <> show err
    Right (Right ())  -> pure ()
```

### The connection pool (this already exists)

Build a `Hasql.Pool.Pool` from the socket URI in `PG_CONNECTION_STRING`
(`hasql-pool`, `hasql`):

```haskell
import Hasql.Connection.Settings qualified as Settings
import Hasql.Pool qualified as Pool
import Hasql.Pool.Config qualified as PoolConfig

createPool :: Text -> IO Pool.Pool
createPool connUri =
  Pool.acquire $
    PoolConfig.settings
      [ PoolConfig.size 20
      , PoolConfig.staticConnectionSettings (Settings.connectionString connUri)
      ]
```

`Settings.connectionString :: Text -> Settings` accepts a libpq-style URI, which is what
`PG_CONNECTION_STRING` already is. `Pool.acquire :: PoolConfig.Config -> IO Pool`,
`Pool.use :: Pool -> Session a -> IO (Either UsageError a)`, `Pool.release :: Pool -> IO ()`.

### New terms used in this plan (defined once)

- **pgmq**: a message queue implemented as SQL functions and tables inside PostgreSQL.
  "Enqueue" = insert a row via `pgmq.send`; "read with visibility timeout" = claim a message and
  hide it from other readers for N seconds; "delete/ack" = remove a claimed message. We access
  it from Haskell with the author's `pgmq-hs` libraries.
- **shibuya**: the author's consumer-side message-processing framework. An `Adapter` exposes a
  stream of `Ingested` messages; a processor run through `runApp` applies a handler and finalizes
  each message's acknowledgement.
- **batch (in shibuya's sense)**: a group of messages accumulated by shibuya and handed to a
  batch handler as one `NonEmpty (Ingested es msg)`, flushed on size or timeout.
- **at-least-once / deduplication**: because the ClickHouse insert and the pgmq delete are not
  one transaction, a crash between them redelivers a message. The storage table
  (`analytics.events_raw`, a `ReplacingMergeTree` keyed on `eventId`) collapses duplicate
  `eventId` rows on merge, so `SELECT ... FINAL` counts each event once.

### Throughput ceiling (accepted for the MVP)

The sustained-throughput ceiling of this design is PostgreSQL, not ClickHouse. Every event is
written to PostgreSQL's write-ahead log on send (`pgmq.send` is an INSERT), read back on poll,
and deleted or archived on ack — roughly 3x write amplification per event before ClickHouse
ever sees it. The consequences, all accepted for the MVP and recorded in the Decision Log:
sustained high volume must arrive via `POST /v1/batch` + `batchSendMessage`, because the
single-event endpoint costs one PostgreSQL round trip per event; the delete-heavy queue table
depends on healthy autovacuum to avoid bloat, so watch it under load; pgmq's unlogged-queue
option trades crash durability for WAL savings and is a documented knob (deliberately not
enabled here); and when pgmq saturates, the escape hatch is swapping the pgmq adapter for
shibuya's Kafka adapter — the writer's batch handler is adapter-agnostic (it consumes
`Ingested es Value` either way).


## Plan of Work

The work proceeds in four milestones (numbered 0–3). Milestone 0 confirms the (now satisfied)
external-dependency precondition. Milestone 1 delivers the producer and HTTP endpoints (verifiable without the writer).
Milestone 2 delivers the batch writer (verifiable by inserting rows). Milestone 3 wires both
into one running binary and demonstrates the full path plus deduplication under replay.

All new application code lives under `src/Kansoku/` in the `kansoku` library, and the process
is assembled in the `kansoku-server` executable (created by EP-1; find its `Main` under `app/`
or `src/` — inspect `kansoku.cabal`'s `executable kansoku-server` stanza for the `main-is` path
and `hs-source-dirs`).

### Milestone 0 — Confirm the shibuya batch precondition (satisfied)

Scope: confirm the external batch feature is present in the local shibuya checkout so the
writer can be built now (shibuya masterplan EP-16..EP-21 are Complete). This milestone
**verifies checkouts only — it edits nothing**; all `cabal.project` and `kansoku.cabal` edits
belong to Milestone 1. Because the batch feature exists only on shibuya `master` (the
`v0.7.1.0` tag contains no `Shibuya/Batch.hs`, the version field was never bumped past
0.7.1.0, and Hackage carries only 0.7.0.0), the check is on the checkout's contents and git
history, NOT a version bound — a bound like `shibuya-core >= 0.7.1` cannot prove the feature
is present. Commands to run (working directory
`/Users/shinzui/Keikaku/bokuno/kansoku-project/kansoku`):

```bash
test -f /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/shibuya-core/src/Shibuya/Batch.hs \
  && echo "Shibuya.Batch present"
git -C /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya merge-base --is-ancestor 8a91e83 HEAD \
  && echo "checkout at/after 8a91e83 (batch stack complete)"
grep -rn 'mkBatchProcessor\|type BatchHandler\|data BatchAck\|data BatchConfig\|ackExcept\|withFallback' \
  /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/shibuya-core/src | head
```

Acceptance: both `echo` lines print (the file exists, and the checkout's HEAD contains commit
`8a91e83` — the commit at which the batch stack is complete), and the `grep` shows
`Shibuya.Batch` exporting `BatchHandler`, `BatchConfig`, `BatchAck`, `ackAllOk`, `ackAll`,
`ackExcept`, `withFallback`, and `failMessages`, and `Shibuya.App` exporting
`mkBatchProcessor` — proceed to Milestone 1 targeting the real API (quoted above). One-line
fallback note (historical only, in case a future version regresses): the writer could instead
consume `Shibuya.Adapter.source` grouped with `Shibuya.Stream.batchStream` plus a time-window,
at the cost of supervision/retry/metrics/tracing/graceful-flush — a last resort, not the plan.

### Milestone 1 — pgmq bootstrap + producer + HTTP endpoints

Scope: after this milestone the two HTTP endpoints exist, validate their input, and enqueue
onto `kansoku_events`; you can read the enqueued messages back off the queue to prove it. This
does not depend on the shibuya batch feature.

Cabal wiring (this plan owns it). Edit `cabal.project` at the repository root to add the three
non-Hackage author libraries as local packages (use the absolute paths — confirmed with
`mori registry show`):

```text
packages:
  .
  /Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs/pgmq-core
  /Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs/pgmq-hasql
  /Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs/pgmq-effectful
  /Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs/pgmq-migration
  /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/shibuya-core
  /Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter/shibuya-pgmq-adapter
```

Keep the existing `.` (the `kansoku` package) entry. If EP-1's `cabal.project` already lists
`.` differently, preserve its formatting and only add the new lines. Note that these local
packages will themselves pull in `hasql`, `hasql-pool`, `streamly`, `effectful`, and
`hs-opentelemetry-*`; let cabal's solver resolve them.

In the same `cabal.project` edit, add a pinned git stanza for the hasql-migration fork.
Hackage's `hasql-migration-0.3.1` does not build against hasql 1.10 (the hasql major the pgmq
libraries use), so any consumer of `pgmq-migration`/`pgmq-hasql` on hasql 1.10 needs the fork —
both `shibuya-pgmq-adapter` and `rei` carry this exact pin:

```text
source-repository-package
  type: git
  location: https://github.com/shinzui/hasql-migration
  tag: 4aaff6c
```

One clarification on necessity: `pgmq-core`, `pgmq-hasql`, `pgmq-effectful`, and
`pgmq-migration` **are** on Hackage at 0.3.0.0, so the local `packages:` entries for the pgmq
libraries are a choice (dev convenience — library edits are picked up without a git push or
release), not a necessity; the shibuya entries, by contrast, are required because the batch
feature is unreleased (see Milestone 0).

Then edit `kansoku.cabal`. The servant API *type declaration* goes in the shared internal
sub-library `kansoku:kansoku-api` (the same sub-library that holds the `Kansoku.Event*` event
model): add `Kansoku.Api.Ingest` to that sub-library's `exposed-modules`. `kansoku-api` depends
only on `servant` (the API combinators) plus aeson/base/text/bytestring/time/containers/uuid — it
must NOT depend on `servant-server`, `warp`, the `pgmq-*` packages, or ClickHaskell, because EP-7's
SDK derives a `servant-client` from `Kansoku.Api.Ingest` and EP-8 feeds it to `servant-openapi-hs`.

Then edit the main `kansoku` `library` stanza: add to `exposed-modules` the handler/queue modules
(`Kansoku.Ingest.Queue`, `Kansoku.Ingest.Producer`, `Kansoku.Ingest.Handler`,
`Kansoku.Writer.Batch`, `Kansoku.Writer.Run`) and add to `build-depends`: the `kansoku-api`
sub-library, `servant`, `servant-server`, `warp`, `aeson`, `text`, `bytestring`,
`unordered-containers`, `containers`, `hasql`, `hasql-pool`, `pgmq-core`, `pgmq-hasql`, `pgmq-effectful`,
`pgmq-migration`, `shibuya-core` (no version bound — the batch feature is unreleased and comes
from the local `master` checkout, whose contents Milestone 0 verified; a `>= 0.7.1` bound would
prove nothing), `shibuya-pgmq-adapter`, `hs-opentelemetry-api`, `time`,
`effectful`. (Some may already be present from EP-1/EP-2/EP-3 — do not duplicate; cabal errors on
duplicates.) The writer module `Kansoku.Writer.Batch` needs both `shibuya-core` (for
`Shibuya.Batch`) and `shibuya-pgmq-adapter`; `containers` is needed for `Data.Map` used to
build a `BatchAck.decisions` map when constructing acks directly. All of these are sourced via
the local `packages:` entries (plus the hasql-migration `source-repository-package` pin) that
this same step adds to `cabal.project`.

Config additions. In `src/Kansoku/Config.hs`, extend the `Config` record (follow EP-1's
documented pattern for adding fields and parsing them from environment variables) with:

- `pgConnectionString :: Text` — read from `PG_CONNECTION_STRING`.
- `eventsQueueName :: Text` — default `"kansoku_events"`, override with `KANSOKU_QUEUE_NAME`.
- `writerMaxBatchSize :: Int` — default `5000`, override with `KANSOKU_WRITER_MAX_BATCH`.
- `writerMaxLatencyMs :: Int` — default `5000`, override with `KANSOKU_WRITER_MAX_LATENCY_MS`
  (5 s, not 1 s — see the flush-window Decision Log entry).
- `writerVisibilityTimeoutSec :: Int` — default `60`, override with `KANSOKU_WRITER_VT_SEC`.
- `writerAdapterBatchSize :: Int` — default `1000`, override with `KANSOKU_WRITER_ADAPTER_BATCH`.
- `httpPort :: Int` — default `8080`, override with `KANSOKU_HTTP_PORT` (may already exist from
  EP-1's health endpoint; reuse it).

Queue module. Create `src/Kansoku/Ingest/Queue.hs`:

```haskell
module Kansoku.Ingest.Queue
  ( eventsQueueName
  , encodeEvent
  , decodeEvent
  , bootstrapQueue
  ) where

import Kansoku.Prelude
import Data.Aeson (Value, Result (..))   -- Value/Result are not re-exported by the prelude
import Hasql.Pool qualified as Pool
import Pgmq.Migration qualified as Migration
import Pgmq.Types (MessageBody (..), QueueName, parseQueueName)
import Pgmq.Hasql.Sessions qualified as PgmqS   -- confirm module path exposes createQueue :: QueueName -> Session ()
import Kansoku.Event (AnalyticsEvent)

-- | Parse the configured queue name, failing loudly on an invalid name at startup.
eventsQueueName :: Text -> QueueName
eventsQueueName t = case parseQueueName t of
  Left err -> error ("Invalid kansoku queue name " <> show t <> ": " <> show err)
  Right q  -> q

-- | One event becomes one pgmq message body: a JSON Value.
encodeEvent :: AnalyticsEvent -> MessageBody
encodeEvent = MessageBody . toJSON

-- | Decode a message body back into an event; Nothing if it does not parse.
decodeEvent :: Value -> Maybe AnalyticsEvent
decodeEvent v = case fromJSON v of
  Success ev -> Just ev
  Error _    -> Nothing

-- | Idempotent: install the pgmq schema (pure SQL, no extension) then create the queue.
bootstrapQueue :: Pool.Pool -> QueueName -> IO ()
bootstrapQueue pool qn = do
  mig <- Pool.use pool Migration.migrate
  case mig of
    Left e           -> error ("pgmq migration session error: " <> show e)
    Right (Left e)   -> error ("pgmq migration error: " <> show e)
    Right (Right ()) -> pure ()
  cq <- Pool.use pool (PgmqS.createQueue qn)   -- confirm the Session-level createQueue import path
  case cq of
    Left e  -> error ("pgmq createQueue error: " <> show e)
    Right _ -> pure ()
```

Confirm the exact module that exposes a `Session`-level `createQueue :: QueueName -> Session ()`
(the effectful `createQueue` needs the `Pgmq` effect; the pool-only bootstrap wants the raw
session variant used by `Example.Database`). If only the effectful variant is convenient, run
the bootstrap inside `runEff . runErrorNoCallStack @PgmqRuntimeError . runPgmq pool` instead of
`Pool.use`.

Producer module. Create `src/Kansoku/Ingest/Producer.hs` — thin wrappers over the pgmq effect
that encode events and send them:

```haskell
module Kansoku.Ingest.Producer
  ( enqueueOne
  , enqueueMany
  ) where

import Kansoku.Prelude
import Effectful (Eff, (:>))
import Pgmq.Effectful (Pgmq, sendMessage, batchSendMessage)
import Pgmq.Hasql.Statements.Types (SendMessage (..), BatchSendMessage (..))
import Pgmq.Types (MessageId, QueueName)
import Kansoku.Event (AnalyticsEvent)
import Kansoku.Ingest.Queue (encodeEvent)

enqueueOne :: (Pgmq :> es) => QueueName -> AnalyticsEvent -> Eff es MessageId
enqueueOne qn ev =
  sendMessage SendMessage { queueName = qn, messageBody = encodeEvent ev, delay = Nothing }

enqueueMany :: (Pgmq :> es) => QueueName -> [AnalyticsEvent] -> Eff es [MessageId]
enqueueMany qn evs =
  batchSendMessage BatchSendMessage { queueName = qn, messageBodies = map encodeEvent evs, delay = Nothing }
```

API type module (in `kansoku:kansoku-api`). Create `src/Kansoku/Api/Ingest.hs`, holding ONLY the
servant API *type declaration* and the JSON request/response payload types it references — no
handlers, no `serve`, no `servant-server`, no warp. This module compiles into the `kansoku-api`
sub-library and is what EP-7 (servant-client SDK) and EP-8 (OpenAPI) reuse, so it must stay free
of server-only dependencies:

```haskell
{-# LANGUAGE DataKinds, TypeOperators #-}
module Kansoku.Api.Ingest
  ( IngestAPI
  , IngestAck (..)
  , BatchAck (..)   -- HTTP response type; not the shibuya BatchAck
  ) where

import Kansoku.Prelude
import Servant.API   -- combinators only (:>, :<|>, ReqBody, Verb, JSON); NOT Servant.Server
import Kansoku.Event (AnalyticsEvent)   -- also in the kansoku-api sub-library

data IngestAck = IngestAck
  { accepted :: !Int
  , eventId  :: !Text
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data BatchAck = BatchAck
  { accepted :: !Int
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

type IngestAPI =
       "v1" :> "events" :> ReqBody '[JSON] AnalyticsEvent   :> Verb 'POST 202 '[JSON] IngestAck
  :<|> "v1" :> "batch"  :> ReqBody '[JSON] [AnalyticsEvent] :> Verb 'POST 202 '[JSON] BatchAck
```

(Both `FromJSON` and `ToJSON` are derived for the acks so the same types serve the server
response, the servant-client SDK decode, and the OpenAPI schema.)

Handler module (in the main `kansoku` library). Create `src/Kansoku/Ingest/Handler.hs`. It imports
the API *type* from `Kansoku.Api.Ingest` and provides the handlers, the validation-to-400 mapping,
`serve`/`hoistServer`, and the natural transformation from the effect stack to servant's `Handler`
— everything that needs `servant-server` and the pgmq producer:

```haskell
{-# LANGUAGE DataKinds, TypeOperators #-}
module Kansoku.Ingest.Handler
  ( ingestApp
  ) where

import Kansoku.Prelude
import Data.Generics.Labels ()             -- enables #label access on AnalyticsEvent below
import Data.Aeson qualified as Aeson
import Data.Aeson ((.=))
import Data.ByteString.Lazy.Char8 qualified as LBS
import Data.Text qualified as Text
import Data.Time.Format.ISO8601 (iso8601Show)
import Effectful (Eff, IOE, runEff, (:>))
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Effectful.Error.Static qualified as Error   -- Error.throwError = the Eff-side throw
import Network.Wai (Application)
import Servant                              -- servant-server: serve, hoistServer, Handler,
                                            -- err400/err503, and Servant's OWN throwError
                                            -- (Handler-side). Do NOT also import the Eff
                                            -- throwError unqualified: `Effectful.Error.Static
                                            -- (throwError)` next to unqualified `Servant`
                                            -- is an ambiguous-occurrence error, which is why
                                            -- the Eff throw is qualified as Error.throwError.
import Hasql.Pool qualified as Pool
import Pgmq.Effectful (Pgmq, PgmqRuntimeError, runPgmq)
import Pgmq.Types (QueueName)
import Kansoku.Api.Ingest (IngestAPI, IngestAck (..), BatchAck (..))   -- the shared API type
import Kansoku.Event (AnalyticsEvent, ValidationError, validateEvent)
  -- validateEvent :: AnalyticsEvent -> Either [ValidationError] AnalyticsEvent (EP-2)
import Kansoku.Ingest.Producer (enqueueOne, enqueueMany)

-- The handler effect stack: producing needs Pgmq (which needs Error PgmqRuntimeError and IOE),
-- plus Error [ValidationError] so validation failures can be thrown inside Eff and mapped to
-- HTTP 400 at the effToHandler boundary.
type HandlerEff = Eff '[Pgmq, Error PgmqRuntimeError, Error [ValidationError], IOE]

-- Run the effect stack for one request and translate errors to servant status codes.
-- NOTE on style: `err400 { … }` / `err503 { … }` record-update syntax below is a deliberate
-- deviation from the generic-lens #label rule — ServerError is an external, non-Generic
-- servant type, so #label access does not apply to it.
effToHandler :: Pool.Pool -> HandlerEff a -> Handler a
effToHandler pool act = do
  res <- liftIO $ runEff $ runErrorNoCallStack @[ValidationError]
                         $ runErrorNoCallStack @PgmqRuntimeError
                         $ runPgmq pool act
  case res of
    Left verrs            -> throwError (validation400 verrs)   -- Servant's throwError (Handler)
    Right (Left pgmqErr)  -> throwError err503 { errBody = "queue unavailable: " <> encodeErr pgmqErr }
    Right (Right a)       -> pure a

-- Build the 400 whose body is the JSON error object promised by the API contract.
validation400 :: [ValidationError] -> ServerError
validation400 errs = err400
  { errBody = Aeson.encode $ Aeson.object
      [ "error" .= ("validation failed" :: Text), "details" .= map show errs ] }

-- Eff-side throw; effToHandler maps it to validation400 above.
throwValidation400 :: (Error [ValidationError] :> es) => [ValidationError] -> Eff es a
throwValidation400 = Error.throwError

encodeErr :: PgmqRuntimeError -> LBS.ByteString
encodeErr = LBS.pack . show

-- EP-2's receivedAt is Text ISO-8601 in this sketch; if it is UTCTime instead, set `now`
-- directly and drop renderTime.
renderTime :: UTCTime -> Text
renderTime = Text.pack . iso8601Show

ingestApp :: Pool.Pool -> QueueName -> Application
ingestApp pool qn = serve (Proxy @IngestAPI) (hoistServer (Proxy @IngestAPI) (effToHandler pool) server)
  where
    server = postEvent :<|> postBatch

    postEvent :: AnalyticsEvent -> HandlerEff IngestAck
    postEvent evRaw = do
      now <- liftIO getCurrentTime
      let ev = evRaw & #receivedAt .~ renderTime now   -- set receivedAt server-side (lens setter)
      case validateEvent ev of
        Left verrs -> throwValidation400 verrs         -- verrs :: [ValidationError]
        Right ok   -> do _ <- enqueueOne qn ok
                         pure IngestAck { accepted = 1, eventId = ok ^. #eventId }

    postBatch :: [AnalyticsEvent] -> HandlerEff BatchAck
    postBatch evsRaw = do
      now <- liftIO getCurrentTime
      let stamped = map (\e -> e & #receivedAt .~ renderTime now) evsRaw
      case traverse validateEvent stamped of
        Left verrs -> throwValidation400 verrs
        Right oks  -> do _ <- enqueueMany qn oks
                         pure BatchAck { accepted = length oks }
```

Validation-to-400: servant's `throwError` lives in `Handler`, not in `HandlerEff`, so the
sketch implements the boundary directly: an `Error [ValidationError]` effect in `HandlerEff`,
thrown inside the Eff action with `throwValidation400` (which is just the Eff-side
`Error.throwError`), and mapped by `effToHandler` to `err400` with the JSON error body built
by `validation400`. (The alternative — validating in the `Handler` monad before entering the
Eff action — also works but duplicates the run boundary, so it is not used.) An invalid event
must produce HTTP `400` with a JSON body like
`{"error":"validation failed","details":["eventName must not be empty"]}` — `details` is an
array precisely because `validateEvent` reports **all** failures as `[ValidationError]` — and
must **not** enqueue anything. The `#receivedAt` and `#eventId` labels used above resolve
through generic-lens over EP-2's `AnalyticsEvent` record (hence
`import Data.Generics.Labels ()`), so confirm EP-2's actual field names and types before
writing (e.g. `occurredAt`/`receivedAt` may be `Text` ISO-8601 or `UTCTime`; if `UTCTime`,
set `now` directly and drop `renderTime`).

Verification for Milestone 1 (see Concrete Steps for exact transcripts): start postgres, run a
tiny bootstrap+enqueue path from the REPL (the HTTP route only arrives in Milestone 3), then
read the queue back with SQL. The runnable REPL snippet — paste it into `cabal repl kansoku`
inside the dev shell (where `PG_CONNECTION_STRING` is set):

```haskell
-- cabal repl kansoku
import Data.Aeson (object, (.=))
import Data.Text qualified as Text
import Effectful (runEff)
import Effectful.Error.Static (runErrorNoCallStack)
import Pgmq.Effectful (PgmqRuntimeError, runPgmq, batchSendMessage)
import Pgmq.Hasql.Statements.Types (BatchSendMessage (..))
import Pgmq.Types (MessageBody (..))
import System.Environment (getEnv)
import Kansoku.Ingest.Queue (bootstrapQueue, eventsQueueName)

demo :: IO ()
demo = do
  connUri <- Text.pack <$> getEnv "PG_CONNECTION_STRING"
  pool <- createPool connUri                     -- from Context and Orientation
  let qn = eventsQueueName "kansoku_events"
  bootstrapQueue pool qn                          -- idempotent: migrate + createQueue
  res <- runEff . runErrorNoCallStack @PgmqRuntimeError . runPgmq pool $
    batchSendMessage BatchSendMessage
      { queueName     = qn
      , messageBodies =
          [ MessageBody (object ["eventName" .= ("repl_test_1" :: Text.Text)])
          , MessageBody (object ["eventName" .= ("repl_test_2" :: Text.Text)])
          ]
      , delay         = Nothing
      }
  print res   -- expect: Right [MessageId 1,MessageId 2] (ids monotonically increasing)
```

(For real events use `Kansoku.Ingest.Producer.enqueueMany`, which encodes an `AnalyticsEvent`
via `encodeEvent`; raw `object` bodies are enough to prove the enqueue path works.) Then read
the queue:

```bash
psql "$PG_CONNECTION_STRING" -c "SELECT msg_id, message FROM pgmq.q_kansoku_events ORDER BY msg_id;"
```

You should see one JSON row per enqueued event. (pgmq stores messages in a table named
`pgmq.q_<queue>`; confirm the exact table name with `\dt pgmq.*`.)

### Milestone 2 — the shibuya batch writer (one INSERT per flushed batch)

Scope: after this milestone a writer consumes `kansoku_events` in batches and performs one
`insertEvents` per flush. Gated on Milestone 0.

Writer batch handler. Create `src/Kansoku/Writer/Batch.hs`:

```haskell
module Kansoku.Writer.Batch
  ( writerBatchHandler
  ) where

import Kansoku.Prelude
import Data.Generics.Labels ()                    -- enables #label access on Ingested/Envelope
import Data.List.NonEmpty qualified as NE
import Effectful (Eff, IOE, (:>))
import UnliftIO (try, SomeException)
import Data.Aeson (Value)
import Shibuya.Batch
  ( BatchHandler, BatchInfo (..), BatchAck
  , ackAllOk, ackExcept, ackAll, withFallback )   -- shibuya master (see Milestone 0)
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Envelope (..), MessageId)
import Shibuya.Core.Ack (AckDecision (..), DeadLetterReason (..), RetryDelay (..))
import Kansoku.Event (AnalyticsEvent)
import Kansoku.Ingest.Queue (decodeEvent)
import Kansoku.ClickHouse (Connection, insertEvents)   -- confirm names/types from EP-3

-- | Receive a whole batch, decode each message's JSON body, insert the decodable ones ONCE.
--   'BatchInfo' carries the batch metadata (batchKey/size/trigger/partition); we use it only
--   for logging here (or ignore it with `_info`). The ClickHouse 'Connection' is captured by
--   partial application when the handler is handed to 'mkBatchProcessor'.
writerBatchHandler
  :: (IOE :> es)
  => Connection -> BatchInfo -> NE.NonEmpty (Ingested es Value) -> Eff es BatchAck
writerBatchHandler conn _info batch = do
  let ingesteds = NE.toList batch
      tagged    = [ (i ^. #envelope . #messageId, decodeEvent (i ^. #envelope . #payload)) | i <- ingesteds ]
      events    = [ ev  | (_,   Just ev) <- tagged ]                 -- decodable payloads
      -- Undecodable messages will NEVER decode; dead-letter them in every branch.
      badOverrides =
        [ (mid, AckDeadLetter (InvalidPayload "event body did not decode"))
        | (mid, Nothing) <- tagged ]
  result <- liftIO $ try (insertEvents conn events)
  pure $ case result of
    -- Insert succeeded: decodable messages fall back to AckOk; undecodable ones dead-letter.
    Right () ->
      if null badOverrides then ackAllOk else ackExcept badOverrides
    -- Insert failed: decodable messages RETRY (fallback = AckRetry so pgmq redelivers), while
    -- undecodable ones still dead-letter (retrying them is pointless). Redelivery is safe
    -- because analytics.events_raw dedups on eventId (ReplacingMergeTree) and the visibility
    -- timeout keeps the batch hidden until it becomes visible again.
    Left (_ :: SomeException) ->
      let delay = AckRetry (RetryDelay 0)
      in if null badOverrides then ackAll delay else withFallback delay badOverrides
```

Important correctness note (this is the key point). Use the real `Shibuya.Batch` constructors:

- On **insert success**: `ackExcept badOverrides`, where
  `badOverrides = [(mid, AckDeadLetter (InvalidPayload ...)) | undecodable]`. `ackExcept`'s
  fallback is `AckOk`, so every decodable (good) message is acked and only the undecodable ones
  dead-letter. If there are no undecodable messages, use `ackAllOk`.
- On **insert failure**: `withFallback (AckRetry delay) badOverrides`. Here the fallback is
  `AckRetry`, so every decodable message retries (pgmq redelivers it after the visibility
  timeout), while the undecodable ones still dead-letter (they will never decode). If there are
  no undecodable messages, use `ackAll (AckRetry delay)`. Do **not** return `AckOk` for good
  messages when the insert failed — that would silently drop data. `ackExcept` (fallback `AckOk`)
  is wrong for the failure case precisely because its fallback cannot be `AckRetry`; that is why
  the failure branch uses `withFallback`, whose first argument is the custom fallback decision.

Writer runner. Create `src/Kansoku/Writer/Run.hs`, which assembles the adapter, the batch
processor, and `runApp`, and returns a handle plus a stop action (so the executable can run it
concurrently with warp and stop it on shutdown):

```haskell
module Kansoku.Writer.Run
  ( runWriter
  ) where

import Kansoku.Prelude
import Data.Generics.Labels ()                    -- enables #label config updates below
import Effectful (runEff)                          -- liftIO comes from Kansoku.Prelude
import Effectful.Error.Static (runErrorNoCallStack)
import Hasql.Pool qualified as Pool
import OpenTelemetry.Trace qualified as OTel
import Data.Int (Int32)
import Data.Time (secondsToNominalDiffTime)
import Pgmq.Effectful (PgmqRuntimeError, runPgmqTraced)
import Shibuya.Telemetry.Effect (runTracing)
import Shibuya.Adapter.Pgmq (pgmqAdapter)
import Shibuya.Adapter.Pgmq.Config (PgmqAdapterConfig (..), defaultConfig)
import Shibuya.App
  ( runApp, SupervisionStrategy (..), ProcessorId (..)
  , stopAppGracefully, defaultShutdownConfig, mkBatchProcessor )  -- mkBatchProcessor lives in Shibuya.App
import Shibuya.Batch (BatchConfig (..), defaultBatchConfig, defaultBatchKey)  -- shibuya master (see Milestone 0)
import Shibuya.Policy (Concurrency (..))
import Pgmq.Types (QueueName)
import Kansoku.ClickHouse (Connection)
import Kansoku.Writer.Batch (writerBatchHandler)

-- | Start the batch writer. Blocks until shutdown is signalled, then drains gracefully.
--   Runs in IO so the executable can fork it alongside warp.
runWriter
  :: Pool.Pool -> OTel.Tracer -> Connection -> QueueName
  -> Int32   -- pgmq adapter batchSize (messages per DB poll) — PgmqAdapterConfig.batchSize
  -> Int32   -- visibility timeout seconds
  -> Int     -- ClickHouse flush size — BatchConfig.batchSize (a DIFFERENT knob!)
  -> Int     -- batch timeout in milliseconds — BatchConfig.batchTimeout
  -> IO () -> IO ()   -- block-until-shutdown action
runWriter pool tracer conn qn adapterBatch vt flushSize batchTimeoutMs waitForShutdown = do
  res <- runEff $ runErrorNoCallStack @PgmqRuntimeError $ runPgmqTraced pool tracer $ runTracing tracer $ do
    -- NAMING COLLISION: `#batchSize` below is PgmqAdapterConfig.batchSize (pgmq poll size),
    -- NOT BatchConfig.batchSize (the ClickHouse flush size set two lines down).
    -- MVP dead-letter posture (see Decision Log): deadLetterConfig stays Nothing (the
    -- default). AckDeadLetter then ARCHIVES the message to pgmq's archive table
    -- (pgmq.a_kansoku_events) — preserved and queryable, not dropped. maxRetries (default 3)
    -- is the adapter-owned retry budget: once readCount > maxRetries the adapter dead-letters
    -- (archives) on ingest, before writerBatchHandler ever sees the message again.
    adapter <- pgmqAdapter (defaultConfig qn & #batchSize .~ adapterBatch & #visibilityTimeout .~ vt)
    let bcfg = defaultBatchConfig
                 & #batchSize    .~ flushSize                                       -- ClickHouse flush size
                 & #batchTimeout .~ secondsToNominalDiffTime (fromIntegral batchTimeoutMs / 1000)
                 & #batchKey     .~ const defaultBatchKey                           -- single undivided batch
                 & #tickInterval .~ Nothing                                         -- Nothing => use batchTimeout
        proc = mkBatchProcessor adapter (writerBatchHandler conn) bcfg
    started <- runApp IgnoreFailures 1000 [(ProcessorId "kansoku-writer", proc)]
    case started of
      Left err        -> liftIO (putStrLn ("writer failed to start: " <> show err))
      Right appHandle -> do
        liftIO waitForShutdown
        _drained <- stopAppGracefully defaultShutdownConfig appHandle
        pure ()
  either (\e -> putStrLn ("writer error: " <> show e)) (const (pure ())) res
```

For an explicit, all-fields construction (equivalent to overriding `defaultBatchConfig` above)
the record reads `BatchConfig{ batchSize = 5000, batchTimeout = 5, batchKey = const
defaultBatchKey, tickInterval = Nothing }` — `batchTimeout` is a `NominalDiffTime`, so `5` means
five seconds (see the flush-window Decision Log entry for why 5 s and not 1 s: at low traffic
each timeout flush is one ClickHouse INSERT creating one part, and a 1 s window sits right at
ClickHouse's recommended sustained insert ceiling). Keep the accumulation to a single group
(`batchKey = const defaultBatchKey`) and
leave `mkBatchProcessor`'s default `Concurrency` (`Serial`) for the MVP, so there is one INSERT
in flight at a time and batches fill maximally. The scaling path (a real `batchKey` that hashes
into N buckets + `Async N`) is documented in the Decision Log and Interfaces.

Watch the **naming collision**: `PgmqAdapterConfig.batchSize` (how many rows one `readMessage`
poll pulls off pgmq) and `BatchConfig.batchSize` (how many messages accumulate before one
ClickHouse flush) are two different settings that happen to share the field name. Keep them as
separate, clearly-labeled knobs (recommended MVP: pgmq adapter `batchSize = 1000`,
`visibilityTimeout = 60`; `BatchConfig` `batchSize = 5000`, `batchTimeout = 5`). The invariant
still holds: `visibilityTimeout` must exceed `batchTimeout` + insert time + ack time, or in-flight
messages redeliver mid-flush (60 s ≫ ~5 s + insert + ack satisfies this with wide margin). The
adapter additionally documents the constraint
`bufferSize * batchSize * avgProcessingTime < visibilityTimeout`; the MVP numbers respect it.

Verification for Milestone 2 (details in Concrete Steps): with messages already on the queue
from Milestone 1, run the writer, then
`clickhouse-client --query 'SELECT count() FROM analytics.events_raw FINAL'` shows the count
equal to the number of distinct events enqueued, and the writer's log / shibuya batch metrics
show a single flush covering many messages (one INSERT per N events, not N inserts).

### Milestone 3 — wire HTTP server + writer into `kansoku-server`, end-to-end + dedup demo

Scope: after this milestone `kansoku-server` runs warp and the writer concurrently, sharing one
pool, one ClickHouse connection, and one tracer; posting an event over HTTP results in a
queryable row; replaying a batch does not increase the deduplicated count.

Edit the `kansoku-server` `Main`. Follow EP-1's existing structure (config load, logging,
health endpoint). `Main` imports `Kansoku.Prelude` and `Data.Generics.Labels ()` so it can read
`Config` fields through generic-lens `#label` as shown. Add:

```haskell
main :: IO ()
main = do
  cfg    <- loadConfig                                  -- EP-1
  pool   <- createPool (cfg ^. #pgConnectionString)     -- from Context and Orientation
  conn   <- ClickHouse.connect cfg                      -- EP-3's connection open; confirm name
  tracer <- makeTracer                                  -- noop-first OTel tracer, defined below
  let qn = eventsQueueName (cfg ^. #eventsQueueName)     -- parse configured name
  bootstrapQueue pool qn                                 -- idempotent: migrate + createQueue
  shutdown <- newEmptyMVar
  let waitForShutdown = takeMVar shutdown
  Async.withAsync
    (runWriter pool tracer conn qn
       (fromIntegral (cfg ^. #writerAdapterBatchSize))
       (fromIntegral (cfg ^. #writerVisibilityTimeoutSec))
       (cfg ^. #writerMaxBatchSize)
       (cfg ^. #writerMaxLatencyMs)
       waitForShutdown)
    $ \_writerThread -> do
        -- warp blocks in the main thread; combine the ingest app with EP-1's health route.
        Warp.run (cfg ^. #httpPort) (ingestApp pool qn)     -- or a combined API including /health
```

`makeTracer` is deliberately **noop-first** for the MVP: hs-opentelemetry-api's global tracer
provider is a no-op unless an OTel SDK initializes it, so this tracer records nothing today
while keeping every call site (`runPgmqTraced`, `runTracing`) ready for a real provider later
— no code changes needed, only SDK initialization:

```haskell
import OpenTelemetry.Trace qualified as OTel

makeTracer :: IO OTel.Tracer
makeTracer = do
  tp <- OTel.getGlobalTracerProvider    -- a no-op provider unless an OTel SDK installed one
  pure (OTel.makeTracer tp "kansoku" OTel.tracerOptions)
```

If EP-1's server already defines a servant `Application` with `/health`, combine the APIs with
`:<|>` into one `serve` call rather than starting two warp servers. Use
`Control.Concurrent.Async.withAsync` so the writer thread is cancelled when `main` exits, and
signal `shutdown` from a SIGTERM/SIGINT handler if EP-1 installs one (otherwise Ctrl-C tears
the process down and `withAsync` cancels the writer). The writer and the HTTP handlers share the
same `Pool`, so pgmq produce and consume use one connection pool.

End-to-end + deduplication demo: run the full `curl` → `SELECT ... FINAL` path, then re-post the
exact same batch (same `eventId`s) and confirm the `FINAL` count is unchanged — proving
at-least-once delivery is made idempotent by the `ReplacingMergeTree`. Full transcripts are in
Concrete Steps and Validation and Acceptance.


## Concrete Steps

All commands run from the repository root
`/Users/shinzui/Keikaku/bokuno/kansoku-project/kansoku` inside the Nix dev shell (so the
`PG*`/`CLICKHOUSE_*` env vars and `clickhouse-client`/`psql`/`process-compose` are on `PATH`).

1. Start the datastores and confirm they are up:

```bash
process-compose up -D            # start postgres + clickhouse in the background
psql "$PG_CONNECTION_STRING" -c 'SELECT 1;'
clickhouse-client --query 'SELECT 1'
```

Expected: `psql` prints a `1` row; `clickhouse-client` prints `1`.

2. Build after the cabal wiring edits:

```bash
cabal build kansoku
```

Expected: it compiles `Kansoku.Api.Ingest` (in the `kansoku-api` sub-library), `Kansoku.Ingest.Queue`,
`Kansoku.Ingest.Producer`, `Kansoku.Ingest.Handler`, `Kansoku.Writer.Batch`, and `Kansoku.Writer.Run`
and the `kansoku-server` executable with no
errors. First build will compile the newly-added local packages (`pgmq-*`, `shibuya-core`,
`shibuya-pgmq-adapter`) and may take several minutes.

3. Run the server:

```bash
cabal run kansoku-server
```

Expected startup log lines (wording depends on EP-1's logger): pgmq migration applied, queue
`kansoku_events` created, writer processor `kansoku-writer` started, HTTP server listening on
`:8080`.

4. Post one event (in a second shell inside the dev shell). Use this exact body:

```bash
curl -s -w '\n%{http_code}\n' -X POST http://localhost:8080/v1/events \
  -H 'content-type: application/json' \
  -d '{
    "eventId": "11111111-1111-1111-1111-111111111111",
    "eventName": "page_viewed",
    "source": "web",
    "occurredAt": "2026-07-01T12:00:00Z",
    "receivedAt": "2026-07-01T12:00:00Z",
    "anonymousId": "anon-abc",
    "url": "https://example.com/pricing",
    "properties": {"plan": "pro"},
    "context": {"userAgent": "curl"}
  }'
```

Expected output — the response body on the first line, the status code on the second (the
`-w '\n%{http_code}\n'` appends the status after the body instead of discarding the body):

```text
{"accepted":1,"eventId":"11111111-1111-1111-1111-111111111111"}
202
```

(The server overwrites `receivedAt` with its own clock; the value you send is ignored.)

5. Post a batch (an array):

```bash
curl -s -X POST http://localhost:8080/v1/batch \
  -H 'content-type: application/json' \
  -d '[
    {"eventId":"22222222-2222-2222-2222-222222222222","eventName":"signup_started","source":"web","occurredAt":"2026-07-01T12:00:01Z","receivedAt":"2026-07-01T12:00:01Z","anonymousId":"anon-abc","properties":{},"context":{}},
    {"eventId":"33333333-3333-3333-3333-333333333333","eventName":"signup_completed","source":"web","occurredAt":"2026-07-01T12:00:02Z","receivedAt":"2026-07-01T12:00:02Z","userId":"user-1","properties":{},"context":{}}
  ]'
```

Expected output: `{"accepted":2}`.

6. Prove the messages reached the queue (before the writer drains them — do this quickly, or
   temporarily stop the writer). pgmq stores queued messages in table `pgmq.q_kansoku_events`:

```bash
psql "$PG_CONNECTION_STRING" -c '\dt pgmq.*'
psql "$PG_CONNECTION_STRING" -c 'SELECT msg_id, message->>'"'"'eventName'"'"' AS name FROM pgmq.q_kansoku_events ORDER BY msg_id;'
```

Expected: rows for `page_viewed`, `signup_started`, `signup_completed` (unless the writer has
already consumed and deleted them, which is the normal steady state).

7. Prove the events are queryable in ClickHouse after the writer flushes (allow up to
   `batchTimeout`, ~5s; the table's columns are snake_case — `event_id`, `event_name`,
   `occurred_at` — per EP-3's schema, while the JSON contract stays camelCase):

```bash
sleep 6
clickhouse-client --query 'SELECT count() FROM analytics.events_raw FINAL'
clickhouse-client --query "SELECT event_id, event_name FROM analytics.events_raw FINAL ORDER BY occurred_at"
```

Expected: `count()` is `3`; the three event names appear.

8. Demonstrate batching (one INSERT per N events, not N inserts). Send many events quickly and
   watch the writer's log or shibuya batch metrics:

```bash
seq 1 5000 | while read i; do
  printf '{"eventId":"e-%d","eventName":"bulk","source":"service","occurredAt":"2026-07-01T12:05:00Z","receivedAt":"2026-07-01T12:05:00Z","properties":{},"context":{}}\n' "$i"
done | jq -s '.' | curl -s -X POST http://localhost:8080/v1/batch -H 'content-type: application/json' --data-binary @- -o /dev/null -w '%{http_code}\n'
sleep 6
clickhouse-client --query 'SELECT count() FROM analytics.events_raw FINAL'
```

Expected: `202` from curl, and the `FINAL` count grows by `5000`. The writer log shows a small
number of flushes (roughly `5000 / batchSize` size-triggered plus timeout-triggered ones), each
performing exactly one INSERT — not 5000 inserts.

9. Demonstrate at-least-once + deduplication (replay). Re-run step 5 (the same batch, same
   `eventId`s `2222...`/`3333...`), then re-count with `FINAL`:

```bash
# re-post the identical batch from step 5, then:
sleep 6
clickhouse-client --query 'SELECT count() FROM analytics.events_raw FINAL'
```

Expected: the `FINAL` count is unchanged versus step 7 (still `3` for those ids plus whatever
step 8 added). Without `FINAL` the raw count may temporarily be higher until ClickHouse merges;
`FINAL` collapses duplicate `eventId` rows, proving replay is safe.


## Validation and Acceptance

The plan is accepted when all of the following are observable:

- `cabal build kansoku` succeeds with the new modules and dependencies.
- `POST /v1/events` with a valid event returns HTTP `202` and body
  `{"accepted":1,"eventId":"..."}`; `POST /v1/batch` with a valid array returns `202` and
  `{"accepted":N}`.
- An invalid event (for example `eventName` empty, or `source` not one of
  `web|app|service|worker|email|agent`) returns HTTP `400` with a JSON error body and enqueues
  nothing (verify the queue count does not change).
- After posting, the events are queryable in ClickHouse:
  `SELECT count() FROM analytics.events_raw FINAL` increases by exactly the number of accepted,
  distinct events.
- Sending 5000 events results in a small number of writer flushes (one INSERT per flush), shown
  by the writer log / shibuya batch metrics — not one INSERT per event.
- Replaying an identical batch does not increase the `FINAL` count.

Automated tests. Add:

- A unit test for `Kansoku.Ingest.Queue`: `decodeEvent . unMessageBody . encodeEvent == Just`
  for a sample `AnalyticsEvent` (round-trip through the pgmq body encoding). Run with
  `cabal test`.
- An integration test (guarded so it runs only when `PG_CONNECTION_STRING` and ClickHouse are
  available): bootstrap the queue, `enqueueMany` a handful of events, run the writer for a short
  window (or invoke `writerBatchHandler` directly on a synthesized `NonEmpty Ingested`), then
  assert the rows appear via a ClickHouse `SELECT ... FINAL`. Name the test suite in
  `kansoku.cabal` and run it with `cabal test`. Interpreting results: the suite prints
  `All N tests passed` on success; a failing round-trip prints the differing JSON, and a failing
  integration assertion prints the expected vs. actual row count.

Exact test command:

```bash
cabal test
```


## Idempotence and Recovery

Every startup step is safe to repeat:

- `bootstrapQueue` runs `pgmq-migration`'s `migrate` (only applies unapplied migrations) then
  `createQueue` (a no-op if the queue exists). Restarting the server re-runs both harmlessly.
- Re-posting events is safe: duplicate `eventId`s collapse in the `ReplacingMergeTree` on merge;
  queries use `FINAL`.
- If the writer crashes after a ClickHouse insert but before acking, the messages become visible
  again after `visibilityTimeout` (60s) and are redelivered and re-inserted; deduplication makes
  this harmless.
- If the writer crashes before inserting, the messages redeliver and are processed normally.
- If a message body is permanently undecodable, it is dead-lettered rather than redelivered
  forever. MVP posture (see Decision Log): `deadLetterConfig = Nothing`, under which the
  adapter's handling of `AckDeadLetter` **archives** the message to pgmq's archive table
  (`pgmq.a_kansoku_events`) — durable and observable, inspect it with
  `psql "$PG_CONNECTION_STRING" -c 'SELECT * FROM pgmq.a_kansoku_events;'`. Independently,
  the adapter's `maxRetries` (default 3) is the retry budget: once a message's `readCount`
  exceeds it, the adapter archives the message on ingest — this budget is adapter-owned, not
  handler logic, so `writerBatchHandler` never needs its own retry counting.

Recovery from a bad cabal edit: if the newly-added local packages fail to resolve, run
`cabal build -v` to see which package the solver rejects, and double-check the absolute paths in
`cabal.project` against `mori registry show pgmq-hs --full` / `mori registry show shibuya --full`
/ `mori registry show shibuya-pgmq-adapter --full`. To reset the datastores for a clean re-run,
stop `process-compose`, delete the state directories it manages (see `process-compose.yaml` for
their paths), and start again; then re-run `bootstrapQueue` (it recreates the queue) and EP-3's
ClickHouse migration.


## Interfaces and Dependencies

Libraries used and why:

- `pgmq-effectful` / `pgmq-hasql` / `pgmq-core` / `pgmq-migration` (`pgmq-hs`, local package at
  `/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs`): the producer and queue
  bootstrap. The HTTP handler is the producer. (These four are also on Hackage at 0.3.0.0; the
  local paths are a dev convenience, not a necessity.) They require the `shinzui/hasql-migration`
  fork pinned at tag `4aaff6c` via `source-repository-package`, because Hackage's
  `hasql-migration-0.3.1` does not build against hasql 1.10.
- `shibuya-core` (local at `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/shibuya-core`,
  `master` checkout — required, since the batch feature is unreleased; see Milestone 0)
  and `shibuya-pgmq-adapter` (local at
  `/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya-pgmq-adapter/shibuya-pgmq-adapter`):
  the consumer/writer, including the external batch feature (`Shibuya.Batch`).
- `servant` + `servant-server` + `warp`: the HTTP API and server.
- `hasql` + `hasql-pool`: the PostgreSQL connection pool shared by producer and consumer.
- `aeson`: JSON encoding of events into `MessageBody`.
- EP-2 `Kansoku.Event` (`AnalyticsEvent`, `validateEvent`) and EP-3 `Kansoku.ClickHouse`
  (`Connection`, `insertEvents`).

Signatures that must exist at the end of each milestone (full module paths):

- `Kansoku.Ingest.Queue.eventsQueueName :: Text -> QueueName`
- `Kansoku.Ingest.Queue.encodeEvent :: AnalyticsEvent -> MessageBody`
- `Kansoku.Ingest.Queue.decodeEvent :: Value -> Maybe AnalyticsEvent`
- `Kansoku.Ingest.Queue.bootstrapQueue :: Pool -> QueueName -> IO ()`
- `Kansoku.Ingest.Producer.enqueueOne :: Pgmq :> es => QueueName -> AnalyticsEvent -> Eff es MessageId`
- `Kansoku.Ingest.Producer.enqueueMany :: Pgmq :> es => QueueName -> [AnalyticsEvent] -> Eff es [MessageId]`
- `Kansoku.Api.Ingest.IngestAPI` (the servant type below, in the `kansoku:kansoku-api` sub-library), `Kansoku.Ingest.Handler.ingestApp :: Pool -> QueueName -> Application` (in the main `kansoku` library)
- `Kansoku.Writer.Batch.writerBatchHandler :: IOE :> es => Connection -> BatchInfo -> NonEmpty (Ingested es Value) -> Eff es BatchAck` (i.e. `Connection -> BatchHandler es Value` after partial application, since `BatchHandler es Value = BatchInfo -> NonEmpty (Ingested es Value) -> Eff es BatchAck`)
- `Kansoku.Writer.Run.runWriter :: Pool -> Tracer -> Connection -> QueueName -> Int32 -> Int32 -> Int -> Int -> IO () -> IO ()`

The queue name and message-body encoding (the MasterPlan integration point this plan owns): the
queue is `kansoku_events`; each message body is a `Data.Aeson.Value` holding one JSON-encoded
`AnalyticsEvent` using EP-2's `ToJSON`/`FromJSON`. No other plan touches the queue.

The HTTP ingestion API contract lives as the servant *type declaration* `IngestAPI` in module
`Kansoku.Api.Ingest`, inside the shared `kansoku:kansoku-api` sub-library (which depends on
`servant` only). It is reused three ways so it cannot drift: this plan's server serves it, EP-7's
SDK derives a `servant-client` from it, and EP-8 feeds it — as part of the combined
`Kansoku.Api.KansokuAPI = IngestAPI :<|> MetricsAPI` (EP-6's `MetricsAPI`) — to
`servant-openapi-hs`. The type:

```haskell
type IngestAPI =
       "v1" :> "events" :> ReqBody '[JSON] AnalyticsEvent   :> Verb 'POST 202 '[JSON] IngestAck
  :<|> "v1" :> "batch"  :> ReqBody '[JSON] [AnalyticsEvent] :> Verb 'POST 202 '[JSON] BatchAck
```

`POST /v1/events` takes one `AnalyticsEvent` JSON object and returns `202` with
`{"accepted":1,"eventId":"<id>"}`. `POST /v1/batch` takes a JSON array of `AnalyticsEvent` and
returns `202` with `{"accepted":<n>}`. Validation failure is `400` with
`{"error":"...","details":[...]}`. The server sets `receivedAt` and preserves `occurredAt`.

The shibuya batch API relied upon (the real, confirmed signatures from the `Shibuya.Batch`
module on shibuya `master`, commit `8a91e83` or later — unreleased, so consumed via the local
`packages:` entry, never a version bound; see Milestone 0 — and `mkBatchProcessor` from
`Shibuya.App`):

```haskell
-- module Shibuya.App
mkBatchProcessor :: Adapter es msg -> BatchHandler es msg -> BatchConfig es msg -> QueueProcessor es

-- module Shibuya.Batch (shibuya master, commit 8a91e83+)
type BatchHandler es msg = BatchInfo -> NonEmpty (Ingested es msg) -> Eff es BatchAck

data BatchConfig es msg = BatchConfig
  { batchSize    :: !Int                        -- flush at this many messages (>=1)
  , batchTimeout :: !NominalDiffTime            -- flush this long after the first message (>0)
  , batchKey     :: !(Envelope msg -> BatchKey) -- const defaultBatchKey for one undivided batch
  , tickInterval :: !(Maybe NominalDiffTime)    -- Nothing => use batchTimeout
  }

data BatchAck = BatchAck { decisions :: !(Map MessageId AckDecision), fallback :: !AckDecision }
ackAllOk     :: BatchAck
ackAll       :: AckDecision -> BatchAck
ackExcept    :: [(MessageId, AckDecision)] -> BatchAck                 -- fallback AckOk
withFallback :: AckDecision -> [(MessageId, AckDecision)] -> BatchAck  -- custom fallback
failMessages :: [(MessageId, DeadLetterReason)] -> BatchAck
```

The `BatchHandler` takes the `BatchInfo` metadata **first**, then the whole batch as
`NonEmpty (Ingested es msg)`, and returns a `BatchAck` — a per-`MessageId` `decisions` map plus a
`fallback` decision. `BatchConfig` carries `batchSize`, `batchTimeout`, a required `batchKey`
(use `const defaultBatchKey` for one undivided batch), and `tickInterval`. Smart constructors:
`ackAllOk`, `ackAll`, `ackExcept` (fallback `AckOk`), `withFallback` (custom fallback), and
`failMessages`. This plan uses `ackAllOk`/`ackExcept` on insert success and
`ackAll (AckRetry …)`/`withFallback (AckRetry …)` on insert failure. These are consumed via
`Shibuya.App.runApp` with `SupervisionStrategy` and an inbox size.

The pgmqAdapter + mkBatchProcessor wiring and tuning (recommended MVP numbers): pgmq adapter
`PgmqAdapterConfig.batchSize = 1000` (rows per `readMessage` poll), `visibilityTimeout = 60`
seconds; batch `BatchConfig.batchSize = 5000` (ClickHouse flush size), `batchTimeout = 5`
(seconds — see the flush-window Decision Log entry), `batchKey = const defaultBatchKey`
(single group), `tickInterval = Nothing`, `Concurrency = Serial`, `deadLetterConfig = Nothing`
(archive-as-DLQ; see the dead-letter Decision Log entry), `maxRetries` left at its default of 3
(the adapter-owned retry budget). **Naming collision to keep straight**:
`PgmqAdapterConfig.batchSize` (pgmq poll size) and `BatchConfig.batchSize` (ClickHouse flush
size) are DIFFERENT knobs that share a field name — keep them as separate, clearly-labeled
settings. Invariants to preserve: `visibilityTimeout` must exceed `batchTimeout` + insert time
+ ack time, or in-flight messages redeliver mid-flush (60 s ≫ ~5 s + insert + ack satisfies
this with wide margin), and the adapter's documented constraint
`bufferSize * batchSize * avgProcessingTime < visibilityTimeout` must hold (the MVP numbers
respect it). Scaling path (documented, not
enabled in the MVP): set `batchKey` to hash each message into N buckets and set
`Concurrency = Async N` to run N inserts concurrently, accepting smaller per-bucket batches;
per-key FIFO is preserved by shibuya but analytics needs no ordering so any bucketing is valid.

Config additions (`Kansoku.Config`, extended per EP-1's pattern): `pgConnectionString`,
`eventsQueueName` (default `kansoku_events`), `writerMaxBatchSize` (5000), `writerMaxLatencyMs`
(5000), `writerVisibilityTimeoutSec` (60), `writerAdapterBatchSize` (1000), `httpPort` (8080).
The runtime additionally acquires a shared `Hasql.Pool.Pool`, an OpenTelemetry `Tracer` (a noop
tracer via `runTracingNoop` is acceptable for the MVP), and EP-3's ClickHouse `Connection`, and
adds the `Pgmq` and `Tracing` interpreters to the effect chain following EP-1's documented
extension pattern (`runEff . runErrorNoCallStack @PgmqRuntimeError . runPgmq pool` for the
producer path; `... runPgmqTraced pool tracer . runTracing tracer` for the writer path).

### Commit conventions for this plan

Use Conventional Commits, no feature branch (commit to the current branch). Every commit for
this plan must carry these trailers so the work is traceable to its plan and intention:

```text
feat(ingest): add pgmq producer and /v1/events, /v1/batch endpoints

MasterPlan: docs/masterplans/1-kansoku-analytics-service-mvp.md
ExecPlan: docs/plans/4-ingestion-api-with-pgmq-queue-and-batched-clickhouse-writer.md
Intention: intention_01kwf425fxenc904ear54cr2n7
```


## Revision Notes

- 2026-07-01 — **shibuya first-class batch processing shipped; plan retargeted from frozen
  signatures to the real `Shibuya.Batch` API.** The external hard dependency this plan waited on
  is now available: `shibuya-core 0.7.1.0` exposes the `Shibuya.Batch` module and the batching
  runner `Shibuya.App.mkBatchProcessor`, and the shibuya masterplan's child plans EP-16 through
  EP-21 are all marked Complete. What changed and why:
  - Milestone 0 was demoted from a **blocking external-dependency gate** (with pause / raw
    `batchStream` fallback paths) to a short **satisfied-precondition** step that confirms
    shibuya-core >= 0.7.1.0 provides `Shibuya.Batch`, tells the implementer to add `shibuya-core`
    (>=0.7.1) via the shibuya local `packages:` entry in `cabal.project`, and verify the imports
    resolve. The historical `Adapter.source` + `Shibuya.Stream.batchStream` fallback is kept as a
    one-line note only, in case a future version regresses.
  - The writer's batch handler and runner code, the frozen-spec quotes in Context and Orientation
    and in Interfaces and Dependencies, and the tuning Decision Log entry were all updated to the
    **real, confirmed** signatures: `BatchHandler es msg = BatchInfo -> NonEmpty (Ingested es
    msg) -> Eff es BatchAck` (metadata `BatchInfo` is the FIRST argument); `BatchConfig` fields
    are `batchSize`/`batchTimeout`/`batchKey`/`tickInterval` (replacing the assumed
    `maxSize`/`maxLatency`); and the insert-failure + dead-letter branch uses
    `withFallback (AckRetry …) badOverrides` rather than a hypothetical general `batchAck`
    constructor (`ackExcept` keeps a fixed `AckOk` fallback and is used on the success branch).
  - The naming collision between `PgmqAdapterConfig.batchSize` (pgmq poll size) and
    `BatchConfig.batchSize` (ClickHouse flush size) is now called out explicitly wherever both
    appear.
  Why: the dependency is now real, shipped code, so the plan should target actual signatures a
  novice can compile against instead of a frozen spec that carried unresolved caveats. The pgmq
  producer, the `kansoku:kansoku-api` sub-library wiring, and the ClickHouse writer logic are
  unchanged by this revision.

- 2026-07-01 — **adopted the shared haskell-jitsurei/core coding standards in every Haskell code
  sketch.** The plan's design is unchanged; only the Haskell style was brought into compliance
  with `/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/core/` (`standards.md`,
  `custom-prelude.md`, `record-patterns.md`, `multiline-strings.md`). What changed and why:
  - Added a "Coding standards" subsection to Context and Orientation pointing at the core docs
    and at EP-1's `Kansoku.Prelude` + the shared `common` cabal stanza, so a novice knows the
    house rules before reading any sketch.
  - Every module sketch (`Kansoku.Ingest.Queue`, `Kansoku.Ingest.Producer`, `Kansoku.Api.Ingest`,
    `Kansoku.Ingest.Handler`, `Kansoku.Writer.Batch`, `Kansoku.Writer.Run`, and the
    `kansoku-server` `Main`) now imports `Kansoku.Prelude` and uses postpositive `qualified`
    imports.
  - The request/response DTOs `IngestAck` and `BatchAck` in `Kansoku.Api.Ingest` now use strict
    `!` fields and explicit `deriving stock (Generic, Eq, Show)` + `deriving anyclass (FromJSON,
    ToJSON)`, replacing the lazy fields, bare `deriving (Generic)`, and hand-written empty
    instances.
  - Record reads and updates now go through generic-lens `#label` (each such module adds
    `import Data.Generics.Labels ()`): the handler stamps `receivedAt` with `& #receivedAt .~ …`
    and reads `ok ^. #eventId`; the writer reads `i ^. #envelope . #messageId` /
    `#payload`; `Kansoku.Writer.Run` builds its adapter and batch configs with `& #batchSize .~ …`
    style setters instead of record-update syntax; and `Main` reads `Config` fields with
    `cfg ^. #field`.
  - No Haskell string literal in this plan embeds SQL/DDL (the pgmq bootstrap uses
    `Pgmq.Migration.migrate`, and all raw SQL lives in `psql`/`clickhouse-client` shell blocks),
    so there was nothing to convert to `"""..."""` MultilineStrings here.
  Explicitly unchanged: the pgmq / shibuya-batch / writer design, the shipped `Shibuya.Batch`
  API usage (BatchInfo-first handler, `batchSize`/`batchTimeout`, `withFallback`), the
  `kansoku:kansoku-api` sub-library structure, the ClickHouse `ReplacingMergeTree` dedup
  strategy, and all commit-trailer examples.

- 2026-07-01 — **pre-implementation validation pass + architecture review.** A verification
  sweep against the actual shibuya/pgmq-hs source and an architecture review produced the
  following corrections and decisions. Nothing about the core design (HTTP → pgmq →
  shibuya-batch → one ClickHouse INSERT per flush → `ReplacingMergeTree` dedup) changed.
  - **Shibuya release caveat (corrects the earlier revision note above).** The earlier note's
    claim that "shibuya-core 0.7.1.0 exposes `Shibuya.Batch`" was verified against the shibuya
    repo and found wrong in its versioning: the batch feature exists only on shibuya `master` —
    the `v0.7.1.0` git tag contains no `Shibuya/Batch.hs`, the cabal `version:` field was never
    bumped past 0.7.1.0, and Hackage carries only shibuya-core 0.7.0.0 (no batching). A
    `shibuya-core >= 0.7.1` bound therefore proves nothing. Milestone 0's precondition check was
    rewritten to content checks (`test -f .../shibuya-core/src/Shibuya/Batch.hs` and
    `git merge-base --is-ancestor 8a91e83 HEAD`; commit `8a91e83` completes the batch stack),
    every "0.7.1 ships the batch API" phrasing was replaced, and a Decision Log entry records
    the rule: content check, never a version bound. The local `packages:` entry remains the
    consumption mechanism.
  - **Milestone 0 vs Milestone 1 circularity untangled.** Milestone 0 now only verifies the
    checkouts exist and have the right contents; Milestone 1 owns every `cabal.project` /
    `kansoku.cabal` edit. The Progress checklist says the same.
  - **`validateEvent` canon fixed.** The reconciled EP-2 signature is
    `validateEvent :: AnalyticsEvent -> Either [ValidationError] AnalyticsEvent` (a *list* of
    errors). The list form is now primary everywhere, the "confirm/adapt" hedge was removed,
    and the 400 `details` array (which already presupposed the list) is unchanged.
  - **Handler import ambiguity fixed.** `Kansoku.Ingest.Handler` previously imported
    `Effectful.Error.Static (throwError)` next to unqualified `Servant` (which re-exports its
    own `throwError`) — an ambiguous-occurrence error. The Eff-side throw is now qualified
    (`Error.throwError`); Servant's `throwError` stays unqualified for the `Handler` monad.
  - **Undefined helpers defined.** `throwValidation400` (Eff-side `Error.throwError` over a new
    `Error [ValidationError]` slot in `HandlerEff`, mapped to `err400` + aeson-encoded JSON body
    by `validation400` in `effToHandler`), `encodeErr` (`LBS.pack . show`), `renderTime`
    (`Text.pack . iso8601Show`), and `makeTracer` (noop-first, deliberately:
    hs-opentelemetry-api's `getGlobalTracerProvider` is a no-op unless an SDK initializes it,
    so the MVP records nothing while call sites stay ready for a real provider).
  - **Record-update deviation noted.** `err400 { … }`/`err503 { … }` record-update syntax is a
    deliberate deviation from the generic-lens `#label` rule: `ServerError` is an external,
    non-Generic servant type.
  - **Milestone 1 verification made runnable.** The promised `cabal repl` enqueue snippet now
    exists: acquire the pool, `runEff . runErrorNoCallStack @PgmqRuntimeError . runPgmq pool`,
    `batchSendMessage` with two sample `MessageBody` values, expected `Right [MessageId …]`.
  - **Concrete Steps transcript fixes.** Step 4's curl no longer discards the body it then
    asserts (`-w '\n%{http_code}\n'`, body + status shown); step 7's verification query now
    uses EP-3's snake_case columns (`SELECT event_id, event_name … ORDER BY occurred_at`)
    instead of camelCase.
  - **Dead-letter decision (verified adapter semantics).** With `deadLetterConfig = Nothing`,
    `AckDeadLetter` ARCHIVES the message to pgmq's archive table (`pgmq.a_kansoku_events`),
    and the adapter auto-dead-letters on ingest once `readCount > maxRetries` (default 3).
    Decided for the MVP: keep `deadLetterConfig = Nothing` and accept archive-as-DLQ
    (observable via SQL); `maxRetries` is the adapter-owned retry budget, not handler logic.
    Stated in the `runWriter` sketch commentary, the adapter description, the Idempotence
    section, and a new Decision Log entry.
  - **PERF: flush window widened 1 s → 5 s** (`BatchConfig.batchTimeout = 5`,
    `writerMaxLatencyMs` default 5000, cascaded to every mention and transcript, `sleep`s
    adjusted). Rationale: each flush is one ClickHouse INSERT creating a part; at low traffic a
    1 s timeout means up to one small insert per second per table — right at ClickHouse's
    recommended sustained insert ceiling and a source of merge pressure — while 5 s costs only
    queryability latency, which is not a product requirement for analytics. `visibilityTimeout`
    stays 60 s and the invariant (`visibilityTimeout` ≫ `batchTimeout` + insert + ack) still
    holds; the adapter's `bufferSize * batchSize * avgProcessingTime < visibilityTimeout`
    constraint is noted. New Decision Log entry.
  - **PERF: throughput ceiling named.** A new Context subsection ("Throughput ceiling") and
    Decision Log entry record that the sustained-throughput ceiling is PostgreSQL, not
    ClickHouse (~3x write amplification: WAL on send, read on poll, delete/archive on ack), so
    sustained volume must use `POST /v1/batch` + `batchSendMessage`, autovacuum health matters,
    pgmq's unlogged-queue option is a documented (unused) knob, and the Kafka adapter is the
    escape hatch. Accepted for the MVP.
  - **Dependency wiring completed.** The `cabal.project` step now includes the
    `source-repository-package` pin for `github.com/shinzui/hasql-migration` at tag `4aaff6c`
    (Hackage's hasql-migration-0.3.1 does not build against hasql 1.10; shibuya-pgmq-adapter
    and rei carry the same pin), and notes that the pgmq packages ARE on Hackage at 0.3.0.0 —
    their local `packages:` entries are a dev convenience, unlike the required shibuya ones.
