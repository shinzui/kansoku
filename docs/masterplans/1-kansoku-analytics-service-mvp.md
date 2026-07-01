---
id: 1
slug: kansoku-analytics-service-mvp
title: "Kansoku Analytics Service MVP"
kind: master-plan
created_at: 2026-07-01T15:23:12Z
intention: "intention_01kwf425fxenc904ear54cr2n7"
---

# Kansoku Analytics Service MVP

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

Kansoku (観測, "observation") is a first-party, self-hostable product and web analytics
service. It observes how users, applications, and business systems behave by ingesting
events from many sources (browser SDK, product frontend, backend microservices, workers,
email/campaign systems, agent systems), storing them durably in ClickHouse, and exposing reusable metrics
through a typed query API. The full product specification lives in `docs/initial-spec.md`
at the repository root; this MasterPlan turns the MVP scope of that spec into working
software.

After this initiative is complete, a self-hoster can run one binary (`kansoku-server`) that:
accepts analytics events over HTTP at `POST /v1/events` (single) and `POST /v1/batch`
(array); durably buffers them; writes them into a ClickHouse `analytics.events_raw` table in
large batched inserts sustaining high write throughput; maintains materialized-view rollups
for common metrics (daily event counts, daily/weekly active users, page views by route);
resolves anonymous-to-known user identity at query time; and answers typed metric queries at
`GET /metrics/*` (events, page-views, sessions, funnel, retention, acquisition,
feature-adoption, conversion, users, organizations, custom) without exposing raw SQL. In the
MVP, seven of those endpoints are implemented — events, page-views, sessions (basic
session-id counts), funnel, retention (basic query-time cohorts), conversion, and users —
while the remaining four (acquisition, feature-adoption, organizations, custom) are typed
routes returning HTTP 501 Not Implemented: present in the API contract and the OpenAPI
document, implementation deferred. A
Haskell backend service can emit events through a bundled server SDK. The whole thing runs
locally via the existing Nix + process-compose setup (PostgreSQL + ClickHouse).

The defining architectural decision, and the reason this is not our usual service shape:
**the write path deliberately does not use event sourcing.** Our normal write path records
domain facts as an ordered event log (in this ecosystem, the `shibuya-message-db-adapter`
over message-db). Analytics ingestion has the opposite profile — enormous write volume, no
need for per-aggregate ordering or replay of a domain state machine, and a columnar store
(ClickHouse) as the system of record. So Kansoku ingests through a durable queue and a
**batched** writer: the HTTP handler enqueues events onto a PostgreSQL-backed pgmq queue
(via `pgmq-hs`), and a consumer built on the `shibuya` messaging framework with the
`shibuya-pgmq-adapter` pulls events off in batches and performs one ClickHouse `INSERT` per
batch. This is what "high write throughput" requires: amortizing the cost of each ClickHouse
write across thousands of rows.

Term definitions used throughout this MasterPlan (define once here; each child plan repeats
the ones it needs so it stays self-contained):

- **ClickHouse**: a columnar SQL database optimized for high-volume append-only inserts and
  analytical aggregation queries. It is already provided by the dev environment (see
  `process-compose.yaml` and `nix/haskell.nix`, which start `clickhouse-server` on TCP port
  9000 and HTTP port 8123 with state under `$CLICKHOUSE_HOME`).
- **pgmq**: a message-queue implemented entirely inside PostgreSQL as SQL functions and
  tables (create/send/read-with-visibility-timeout/delete/archive). We access it from Haskell
  with the author's `pgmq-hs` library, which can install the pgmq schema itself via pure SQL
  (`pgmq-migration`) — no PostgreSQL binary extension is required, which matters because the
  dev environment uses a plain nixpkgs `postgresql`.
- **shibuya**: the author's Haskell message-processing framework (modeled on Elixir's
  Broadway). It is *consumer-side*: an `Adapter` exposes a stream of `Ingested` messages, and
  a processor run through `runApp` applies a handler and finalizes each message's
  acknowledgement. Producing to the queue is done directly with the backend's own client
  (here `pgmq-hs`), not through shibuya.
- **shibuya first-class batch processing**: a capability being added to shibuya in a separate
  initiative (`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/docs/masterplans/3-first-class-batch-processing.md`).
  It adds a `BatchHandler` and `mkBatchProcessor` so a processor receives a whole batch
  (`NonEmpty (Ingested es msg)`), flushed on size **or** timeout, with exactly-once
  acknowledgement, graceful-shutdown flush, supervision, metrics, and tracing. Kansoku's
  writer depends on this capability (see External Dependencies below).
- **effectful**: the effect system all of these libraries use. Application code runs in
  `Eff es` with capability constraints like `IOE :> es`, `Pgmq :> es`, `Tracing :> es`.
- **ClickHaskell** (`KovalevDima/ClickHaskell`): the ClickHouse client we use, chosen because
  it explicitly supports GHC 9.12.* (the repository pins `ghc9124`) and offers type-safe,
  `Generic`-derived batch inserts and selects. The `scarf-sh/haskell-clickhouse` alternative
  was rejected because it is only tested on GHC 9.8/9.10.

In scope for the MVP: HTTP single + batch ingestion; the canonical event model and a schema
registry with validation; the ClickHouse raw-events schema, migrations, and batched writer;
the pgmq durable queue and the shibuya-based batched writer pipeline; identity events
(identify/alias/group) and query-time identity resolution; materialized-view rollups for
daily metrics, page views, and active users; the semantic metrics layer and the typed query
API; and a Haskell server SDK. Web-analytics event *shapes* (page views, sessions, UTM
attribution) are represented as ordinary events in the canonical model and served through the
metrics API.

Explicitly out of scope for this MVP (deferred to a later initiative): the JavaScript/React
browser SDKs (`kansoku-js`, `kansoku-react`) — this repository is a Haskell-only flake and
adding a JS toolchain is its own effort; the spec's "simple dashboard integration" MVP item —
explicitly deferred to the same later frontend initiative (the typed metrics API plus EP-8's
OpenAPI document are the machine-readable surface any dashboard will consume); the Kafka
ingestion path (the design keeps the
writer backend-agnostic via shibuya so `shibuya-kafka-adapter` can be added later as a wiring
change, but it is not built now); and everything under "Later Scope" in `docs/initial-spec.md`
(experimentation, feature-flag exposure, anomaly detection, NL metric queries, session
replay, OpenTelemetry bridge, tenant retention policies).


## External Dependencies

This initiative depends on work outside this repository. It is recorded here because a child
plan's hard dependency points at it.

**Shibuya first-class batch processing — SATISFIED (2026-07-01).** The Kansoku write-path plan
(EP-4) requires that shibuya expose a batch-processing API. **This dependency has shipped.**
`shibuya-core` version 0.7.1.0 exposes the `Shibuya.Batch` module (`BatchHandler`, `BatchInfo`,
`BatchConfig`/`defaultBatchConfig`/`validateBatchConfig`, `BatchAck` with smart constructors
`ackAllOk`/`ackAll`/`ackExcept`/`withFallback`/`failMessages`) and `Shibuya.App.mkBatchProcessor
:: Adapter es msg -> BatchHandler es msg -> BatchConfig es msg -> QueueProcessor es` wired
through `runApp`. The tracking initiative
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/docs/masterplans/3-first-class-batch-processing.md`
has all six child plans (EP-16 through EP-21) marked Complete. EP-4 now targets this real API
(its Milestone 0 is a precondition check — add `shibuya-core >= 0.7.1` via the existing local
`packages:` entry and confirm `Shibuya.Batch` imports — not a blocking gate).

**Release caveat (2026-07-01, validation pass):** the batch feature exists only on shibuya
`master` (working tree), NOT in any release. The batch commits landed after the `v0.7.1.0` git
tag (verified: `git ls-tree v0.7.1.0` contains no `Shibuya/Batch.hs`), the version field was
never bumped past 0.7.1.0, and Hackage carries only shibuya-core 0.7.0.0. Consequently a
Hackage-style version bound like `shibuya-core >= 0.7.1` does NOT express the dependency: it is
satisfied by the tagged release, which lacks batching. Kansoku must consume shibuya via a local
`packages:` entry pointing at the batch-bearing checkout (commit `8a91e83` or later of
`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya`) or an equivalent
`source-repository-package` git pin — which is what EP-4 already plans; only its "version >=
0.7.1 proves the feature is present" framing is wrong and must be restated as a commit/checkout
check. shibuya-pgmq-adapter 0.8.0.0 (`shibuya-core ^>=0.7.0.0`) is compatible unchanged. The shipped API
differs slightly from the frozen spec EP-4 was first drafted against; see Surprises &
Discoveries. The historical fallback (consume `Adapter.source` with `Shibuya.Stream.batchStream`
plus a custom time-window) is retained only as a contingency if a future shibuya version
regresses.

Why we did not solve batching inside Kansoku: shibuya's per-message `runApp` has no batch
handler, and consuming `Adapter.source` directly (via the existing size-only
`Shibuya.Stream.batchStream`) forfeits supervision, retry scheduling, metrics, tracing, and
graceful-shutdown flush, and still lacks a size-**or**-time window (Streamly 0.11 exposes no
public time-based windowing). Those concerns belong next to the adapters and are reusable
across every batch sink, so the capability was added to shibuya rather than duplicated here.


## Decomposition Strategy

The initiative is decomposed by functional concern into eight child ExecPlans grouped into
four phases. The guiding principles were the ones in `agents/skills/master-plan/MASTERPLAN.md`:
group by behavior not by file, make each plan independently verifiable, keep hard
dependencies minimal and only where one plan's artifacts are physically required to compile
or run the next, and balance scope so no single plan carries the bulk of the work.

The natural seams follow the data's journey through the system: first a foundation everything
sits on (the buildable package and the shared event vocabulary), then the write path (get
events durably into ClickHouse in batches — the throughput-critical core and the whole reason
for the non-event-sourced design), then the read path (turn stored events into rollups and
answerable metrics), and finally the client surface (a Haskell SDK for emitters).

**Phase 1 — Foundation.** EP-1 establishes the buildable Haskell package: the `.cabal` file
that `nix/haskell.nix`'s `callCabal2nix "kansoku"` already expects but that does not yet
exist, the `Kansoku.*` module namespace, the effectful application runtime, configuration
loading from the environment variables the dev shell already exports
(`PG_CONNECTION_STRING`, `CLICKHOUSE_TCP_PORT`, `CLICKHOUSE_HTTP_PORT`), structured logging,
and a health endpoint — proving `cabal build`, `cabal test`, and a running server. EP-2
defines the canonical `AnalyticsEvent` model, its JSON codecs (matching the TypeScript shape
in `docs/initial-spec.md`), validation, and an in-process event schema registry. These are
separated because the event vocabulary is a distinct, heavily-shared concern that four later
plans consume, and it is unit-testable with no runtime.

**Phase 2 — High-throughput write path (no event sourcing).** EP-3 owns ClickHouse: the
`analytics.events_raw` schema with the spec's suggested ordering/partitioning (extended with
`event_id` in the sort key for deduplication), a migration runner, the
`ClickHaskell` row type mapped from `AnalyticsEvent`, the batched `insertEvents` function, and
the idempotency/deduplication strategy (`ReplacingMergeTree` keyed on `eventId`) that the
at-least-once queue boundary makes necessary. EP-4 owns the pipeline: the servant HTTP
ingestion endpoints that validate (using EP-2) and enqueue to pgmq (via `pgmq-hs`), plus the
writer built on shibuya's batch processor that decodes a whole batch and performs one
`insertEvents` (using EP-3). EP-3 and EP-4 are split because the storage layer is
independently verifiable (insert rows, query them back) without the queue, and the queue
pipeline is the integration point that binds everything and carries the external shibuya
dependency.

**Phase 3 — Read path: rollups and metrics.** EP-5 adds identity events (identify/alias/group)
and the ClickHouse materialized views and query-time identity resolution the spec calls for.
EP-6 adds the semantic metrics layer (the `MetricDefinition` abstraction) and the typed
`GET /metrics/*` query API over ClickHouse selects. They are split because rollups/identity
are a storage-and-DDL concern verifiable by inspecting ClickHouse, whereas the metrics API is
an HTTP-contract concern verifiable by request/response; EP-6 consumes EP-5's views.

**Phase 4 — Client surface.** EP-7 delivers the Haskell server SDK (`kansoku-client`): typed
event constructors, batching, and retrying delivery to the ingestion API, with the client
derived from the shared servant API type via `servant-client` so it cannot drift from the
server. EP-8 generates a single OpenAPI 3 document from the combined servant API type (via the
author's `openapi-hs` and `servant-openapi-hs`) and serves it at `GET /openapi.json`, giving
external consumers a machine-readable contract (and the future source for a generated
TypeScript SDK via `openapi-typescript`). Both depend on the shared `kansoku-api` sub-library
(see Integration Points): rather than the SDK talking to an opaque HTTP contract, the servant
API *type* is reused three ways — the server implements handlers over it, EP-7 derives a
client from it, and EP-8 derives the OpenAPI schema from it — which is drift-proof by
construction. This is why the API type is factored into a light sub-library that depends on
`servant` alone.

Alternatives considered and rejected. **A single monolithic ExecPlan** was rejected: the MVP
touches ingestion, storage, a queue pipeline, rollups, a query API, and an SDK across
unrelated modules — far beyond the "five milestones / ten files" threshold in MASTERPLAN.md,
and it would make the write-path throughput reasoning impossible to review in isolation.
**Splitting by source (web/app/service/worker/email)** was rejected because sources differ
only in event *content*, not in processing — they all flow through the same ingestion,
queue, writer, and query code, so a per-source split would create artificial coupling and
duplicate the pipeline. **Merging EP-3 and EP-4** was rejected because the ClickHouse storage
layer is valuable and testable on its own and carries no external dependency, whereas EP-4
carries the shibuya batch dependency; keeping them apart lets EP-3 land and be verified while
the shibuya feature is still shipping. **Including the JS SDKs** was rejected per the scope
decision (Haskell-only repo).


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 1 | Project skeleton and application runtime | docs/plans/1-project-skeleton-and-application-runtime.md | None | None | Complete |
| 2 | Canonical event model and schema registry | docs/plans/2-canonical-event-model-and-schema-registry.md | EP-1 | None | Complete |
| 3 | ClickHouse storage schema and batch writer | docs/plans/3-clickhouse-storage-schema-and-batch-writer.md | EP-1 | EP-2 | Complete |
| 4 | Ingestion API with pgmq queue and batched ClickHouse writer | docs/plans/4-ingestion-api-with-pgmq-queue-and-batched-clickhouse-writer.md | EP-2, EP-3 | None | Not Started |
| 5 | Identity stitching and materialized view rollups | docs/plans/5-identity-stitching-and-materialized-view-rollups.md | EP-3 | EP-4 | Not Started |
| 6 | Semantic metrics layer and typed query API | docs/plans/6-semantic-metrics-layer-and-typed-query-api.md | EP-3, EP-5 | EP-4 | Not Started |
| 7 | Haskell server SDK | docs/plans/7-haskell-server-sdk.md | EP-2, EP-4 | None | Not Started |
| 8 | OpenAPI schema generation and API documentation | docs/plans/8-openapi-schema-generation-and-api-documentation.md | EP-4, EP-6 | None | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-1, EP-3).
EP-4 additionally has an EXTERNAL hard dependency on shibuya first-class batch processing
(shibuya EP-16..EP-21); see the External Dependencies section.

Phase grouping: Phase 1 (Foundation) = EP-1, EP-2; Phase 2 (Write path) = EP-3, EP-4;
Phase 3 (Read path) = EP-5, EP-6; Phase 4 (Client surface) = EP-7, EP-8.


## Dependency Graph

The graph is a shallow tree rooted at EP-1, because every other plan needs the buildable
package and module layout EP-1 creates (the `.cabal` file, the `Kansoku.*` namespace, the
effectful runtime, and config loading). The write path forms the critical chain; the read
path and SDK branch off the storage layer.

EP-1 has no dependencies. It creates the package that `nix/haskell.nix` already references and
the runtime scaffold every other plan extends.

EP-2 hard-depends on EP-1 because the event types live in the `Kansoku.Event` module inside
the package EP-1 creates, and its tests run under EP-1's test-suite wiring. Nothing else, so
it can begin as soon as EP-1 is green.

EP-3 hard-depends on EP-1 (it adds `Kansoku.ClickHouse.*` modules and depends on ClickHaskell
in the package EP-1 defines) and soft-depends on EP-2. The soft dependency exists because the
ClickHouse row type mirrors the `AnalyticsEvent` fields: if EP-2 is done, EP-3 imports the
type and writes a total mapping; if EP-2 is not yet done, EP-3 can still build and test the
storage layer against a locally-defined row record and reconcile with `Kansoku.Event` at the
integration point (see Integration Points). It is soft, not hard, so storage work can proceed
in parallel with the event-model work.

EP-4 hard-depends on EP-2 (it decodes queue payloads into `AnalyticsEvent` and validates
incoming requests with the schema registry) and on EP-3 (its batch handler calls
`insertEvents`), and additionally on the external shibuya batch feature (its writer is built
with `mkBatchProcessor`). It is the confluence of the write path and cannot be meaningfully
completed until both storage and the event model exist and the shibuya feature is available.

EP-5 hard-depends on EP-3 because materialized views and the identity-resolution structures
are ClickHouse DDL layered on the `events_raw` table and its row type that EP-3 defines. It
soft-depends on EP-4 only in that live rollups are best *observed* with events actually
flowing through ingestion; the DDL and its tests can be validated by inserting fixture rows
directly with EP-3's writer.

EP-6 hard-depends on EP-3 (the query API runs ClickHaskell selects against the events table
and rollups) and on EP-5 (several metric endpoints read the rollup views and use
identity-resolved user counts). It soft-depends on EP-4 (end-to-end demos are nicer with real
ingested data, but endpoints are testable against fixture rows).

EP-7 hard-depends on EP-2 (the SDK constructs and serializes the same `AnalyticsEvent`) and on
EP-4. The EP-4 dependency is hard, not soft, because the SDK derives its client from the
shared `Kansoku.Api.Ingest` (`IngestAPI`) servant type via `servant-client`, and EP-4 owns
that type (placed in the `kansoku-api` sub-library). Reusing the type is what makes the client
provably match the server; the cost is that EP-7 can no longer be fully built before EP-4's API
type exists, which is an acceptable trade for eliminating drift.

EP-8 hard-depends on EP-4 (for `Kansoku.Api.Ingest`) and EP-6 (for `Kansoku.Api.Metrics`),
because it derives the OpenAPI document from the combined `KansokuAPI = IngestAPI :<|>
MetricsAPI`. It cannot generate a complete schema until both API types exist. It is otherwise
independent and can be the last plan implemented.

Parallelism: after EP-1 lands, EP-2 and EP-3 can proceed concurrently (EP-3's dependency on
EP-2 is soft). After EP-3 lands, EP-5 can proceed while EP-4 waits on the shibuya feature. The
one strict serialization is EP-3 → EP-4 (writer needs storage), EP-5 → EP-6 (metrics need
rollups), EP-4 → EP-7 (SDK needs the ingestion API type), and EP-4 + EP-6 → EP-8 (OpenAPI needs
both API types).


## Integration Points

**The `AnalyticsEvent` type and its JSON contract.** Involved: EP-2 (defines), EP-3, EP-4,
EP-5, EP-6, EP-7 (consume). The shared artifact is the `AnalyticsEvent` record in
`api/Kansoku/Event.hs` (sub-library `kansoku:kansoku-api`), its field names and optionality exactly matching
the `AnalyticsEvent` TypeScript type in `docs/initial-spec.md` (`eventId`, `eventName`,
`source`, `sourceService?`, `occurredAt`, `receivedAt`, the identity ids, the web/UTM fields,
the correlation fields, `properties`, `context`), and its `FromJSON`/`ToJSON` instances which
define the on-the-wire JSON used by both the HTTP API and the pgmq message body. EP-2 owns the
type and instances and writes them down as the normative contract. EP-3 maps it to a ClickHouse
row (a total function `AnalyticsEvent -> EventRow`); EP-4 decodes the pgmq `Data.Aeson.Value`
body back into `AnalyticsEvent`; EP-7 constructs and encodes it. Any change to a field name or
JSON key must update EP-2 first and then cascade. Because EP-3 may begin before EP-2 finishes
(soft dep), EP-3's plan defines a placeholder `EventRow` and states explicitly that the final
mapping must consume `Kansoku.Event.AnalyticsEvent` once available. The validation function is
`validateEvent :: AnalyticsEvent -> Either [ValidationError] AnalyticsEvent` (EP-2 owns the
exact signature; note the error side is a *list*). EP-4 calls it at the ingestion boundary and
must adapt to the list form.

**The ClickHouse `analytics.events_raw` schema and `EventRow` type.** Involved: EP-3
(defines), EP-4, EP-5, EP-6 (consume). The shared artifact is both the SQL DDL for
`analytics.events_raw` (column names/types, `ORDER BY (account_id, user_id, event_name,
occurred_at, event_id)`, `PARTITION BY toYYYYMM(occurred_at)`, and the
`ReplacingMergeTree(...)` engine keyed for deduplication on `eventId`) and the Haskell `EventRow` record deriving ClickHaskell's
column mapping. EP-3 owns the exact column list and the migration that creates it. EP-4 inserts
`EventRow`s; EP-5 builds materialized views whose `SELECT` reads these exact columns; EP-6
queries them. Column additions must be made in EP-3's migration and reflected in `EventRow`,
then consumed elsewhere. EP-3 documents the deduplication semantics (a replayed batch inserts
duplicate `eventId` rows that `ReplacingMergeTree` collapses on merge, and queries that must
not see duplicates use `FINAL` or aggregate accordingly) because EP-5 and EP-6 rely on it. The
authoritative engine and sort key are `ReplacingMergeTree(received_at)` with `ORDER BY
(account_id, user_id, event_name, occurred_at, event_id)`; the informal "dedup keyed on
event_id" shorthand elsewhere means this full sort key with `received_at` as the version
column. The `event_id` column is ClickHouse `String` (not `UUID`), matching EP-2's free-form
`Text` ids. The migration mechanism is canonical across EP-3 and EP-5: ordered idempotent
(`IF NOT EXISTS`) files under `db/clickhouse/migrations/000N_*.sql` (`0001_events_raw.sql` owned
by EP-3; `0002_identity.sql` and `0003_rollups.sql` owned by EP-5), all applied in filename
order by a single `just ch-migrate` recipe. EP-5 additionally exposes the query-time
`analytics.events_resolved` view for exact identity-resolved unique-user counts; EP-6 reads it
for exact counts and the `dau`/`wau`/`page_views_by_route` rollups for fast aggregates.

**The pgmq queue name and message-body encoding.** Involved: EP-4 (defines and both produces
to and consumes from it). The shared artifact is the queue name (`kansoku_events`) and the
convention that each pgmq message body is a `Data.Aeson.Value` holding one JSON-encoded
`AnalyticsEvent` (the same JSON as the HTTP contract from EP-2). EP-4 owns queue creation
(via `pgmq-migration` + `createQueue`), the producer (`pgmq-hs` `sendMessage`/
`batchSendMessage` from the HTTP handler), and the consumer (shibuya `pgmqAdapter` +
`mkBatchProcessor`). No other plan touches the queue, but EP-5/EP-6 assume the events they
read arrived through it.

**The configuration module and effectful runtime stack.** Involved: EP-1 (defines), EP-3,
EP-4, EP-6 (extend). The shared artifact is `Kansoku.Config` (parsed from environment
variables) and the concrete effectful effect stack the `kansoku-server` executable runs
(`IOE`, a `Reader Config`, logging, and — once EP-4 lands — `Pgmq` and `Tracing`). EP-1 owns
the base stack and the pattern for adding effects. EP-3 adds ClickHouse connection config;
EP-4 adds pgmq connection/queue config and the `Pgmq`/`Tracing` interpreters; EP-6 adds the
query-server wiring. Each consumer extends the `Config` record and the `runEff . …`
interpreter chain following EP-1's documented pattern rather than inventing a parallel one.

**The cabal package structure.** Involved: EP-1 (defines), all others (extend). The shared
artifact is `kansoku.cabal`: the library stanza with its `exposed-modules` and
`build-depends`, and the `kansoku-server` executable. EP-1 creates it with the base
dependencies. Every subsequent plan adds its new modules to `exposed-modules` and its new
libraries to `build-depends` (ClickHaskell in EP-3; servant/warp, `pgmq-hs`'s
`pgmq-effectful`, `shibuya`, `shibuya-pgmq-adapter` in EP-4; etc.). Each plan names the exact
stanza edits it makes so they do not conflict. The author's libraries (`shibuya`,
`shibuya-pgmq-adapter`, `pgmq-hs`) are not on Hackage, so EP-4 also owns adding them as
source-repository or local `packages:` entries in `cabal.project`; EP-1 creates the initial
`cabal.project` and documents this extension point. Separately, an internal
`kansoku:kansoku-api` Cabal sub-library (see the next integration point) holds the event model
and the servant API type declarations so the SDK and OpenAPI generator reuse them without the
server's heavy dependencies (ClickHouse, pgmq, servant-server, warp); the invariant all plans
respect is that the `Kansoku.Event*` and `Kansoku.Api.*` module paths and their JSON/type
contracts stay stable regardless of which component holds them.

**The HTTP ingestion API contract.** Involved: EP-4 (defines), EP-7 (consumes). The shared
artifact is the request/response shape of `POST /v1/events` and `POST /v1/batch` — the JSON
bodies (a single `AnalyticsEvent` or an array), the accepted/validated status responses, and
error shapes. EP-4 owns the servant API type `Kansoku.Api.Ingest.IngestAPI`; EP-7's SDK derives
its client from that exact type via `servant-client`, so drift is impossible at the type level
(no need to hand-copy paths). The type lives in the shared `kansoku-api` sub-library described
next.

**The shared servant API type (the `kansoku-api` sub-library).** Involved: EP-4 and EP-6
(define API types), EP-7 (consumes for the client), EP-8 (consumes for OpenAPI), EP-1 (creates
the sub-library stanza), EP-2 (places the event model there). The shared artifact is an
internal Cabal sub-library `kansoku:kansoku-api` declared in `kansoku.cabal` that depends only
on `servant` (the API combinators) plus aeson/base/bytestring/text/time/containers/uuid —
deliberately NOT
servant-server, warp, ClickHaskell, or pgmq — so any consumer can import the API type without
pulling in the server. It exposes the event model (`Kansoku.Event`, `Kansoku.Event.Types`,
`Kansoku.Event.Registry`, `Kansoku.Event.Validation`, owned by EP-2 — Types is the leaf module
holding the record/newtypes/instances so Registry and Validation can import it without a
cycle; `Kansoku.Event` re-exports all of it and remains the public entry point) and the servant API *type declarations only* (no
handlers): `Kansoku.Api.Ingest.IngestAPI` (owned by EP-4), `Kansoku.Api.Metrics.MetricsAPI`
(owned by EP-6), and `Kansoku.Api.KansokuAPI = IngestAPI :<|> MetricsAPI` (assembled in
`Kansoku.Api`; EP-6 or EP-8 may define it, whichever lands first, and EP-8 guarantees it
exists). The main `kansoku` library depends on `kansoku-api` and provides the handlers and
`serve`/`hoistServer` wiring (servant-server + warp). EP-7 does `client (Proxy @IngestAPI)`;
EP-8 does `toOpenApi (Proxy @KansokuAPI)`. Any change to an endpoint's type must be made in the
owning `Kansoku.Api.*` module and automatically flows to the server, the client, and the
OpenAPI document. The sub-library also holds `Kansoku.Prelude` (the project custom prelude, see
the next integration point); EP-1 creates the `kansoku-api` stanza with the prelude, and EP-2
adds the event modules and EP-4/EP-6 the API-type modules to it. This supersedes the earlier
`kansoku-event` sub-library name (which held only the event model); `kansoku-api` subsumes it.
Consequence to note: because the servant API
types reference their request/response DTOs, those pure DTOs must also live in `kansoku-api`.
For ingestion that is trivial (`IngestAck`/`BatchAck` were already local to the API module).
For metrics, EP-6's response DTOs `MetricResult`, `MetricPoint`, and the `TimeGrain`
query-param enum are re-homed from `Kansoku.Query` (which depends on ClickHaskell) into
`Kansoku.Api.Metrics` so the API type stays ClickHaskell-free; `Kansoku.Query` imports them.
Their shape and JSON are unchanged; only their module home moves.


**Coding standards and the custom prelude.** Involved: EP-1 (establishes), all plans (follow).
Every Kansoku package and module follows the project Haskell standards documented at
`/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/core/` (`standards.md`, `custom-prelude.md`,
`record-patterns.md`, `multiline-strings.md`). The shared artifact is the concrete realization
of those standards that EP-1 owns: the cabal `common common` stanza with
`default-language: GHC2024` and `default-extensions: DeriveAnyClass, DuplicateRecordFields,
OverloadedLabels, OverloadedStrings, MultilineStrings` (every stanza does `import: common`), and
the `Kansoku.Prelude` module in the `kansoku-api` sub-library that re-exports `Text`, `Generic`,
the aeson vocabulary (`FromJSON`/`ToJSON`/`genericParseJSON`/`genericToJSON`/`Options`/
`camelTo2`), `UTCTime`, `NonEmpty`, and a blanket `Control.Lens`. The standing rules every plan
must follow: postpositive qualified imports (`import Data.Map.Strict qualified as Map`); every
module imports `Kansoku.Prelude`; strict record fields with explicit deriving strategies
(`deriving stock`/`deriving anyclass`/`deriving newtype`) and no field prefixes; generic-lens
`#label` access and lens setters instead of record-update syntax (with a per-module
`import Data.Generics.Labels ()` where `#label` is used, never re-exported from the prelude); and
`"""..."""` MultilineStrings for embedded SQL and JSON. Dependencies `generic-lens ^>=2.2` and
`lens ^>=5.3` live in the `kansoku-api` sub-library that holds the prelude. Later plans do not
restate the standards in full; they follow EP-1's setup and cite this integration point.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan and
the milestone. This section provides an at-a-glance view of the entire initiative.

- [x] EP-1: `kansoku.cabal` + `cabal.project` build green under `cabal build` and `nix build`
- [x] EP-1: effectful runtime + `Kansoku.Config` from env + structured logging
- [x] EP-1: `kansoku-server` runs and serves a health endpoint returning 200 OK
- [x] EP-2: `AnalyticsEvent` type + `FromJSON`/`ToJSON` round-trip matching the spec JSON
- [x] EP-2: event validation + in-process schema registry with unit tests green
- [x] EP-3: `analytics.events_raw` migration (ReplacingMergeTree, ORDER BY, PARTITION BY) applied
- [x] EP-3: `EventRow` ClickHaskell mapping + batched `insertEvents`, round-trip insert/select test
- [x] EP-3: deduplication strategy documented and demonstrated (replayed batch collapses)
- [ ] EP-4: pgmq queue bootstrap + HTTP `POST /v1/events` and `/v1/batch` enqueue events
- [ ] EP-4: shibuya batch writer inserts one ClickHouse batch per flush (size-or-timeout)
- [ ] EP-4: end-to-end — POST an event, observe it queryable in `events_raw`
- [ ] EP-5: identity events stored (identify/alias feed the identity map; group stored as
      ordinary events); query-time identity resolution via `events_resolved`
- [ ] EP-5: materialized views for daily event counts, DAU/WAU, page views by route
- [ ] EP-6: `MetricDefinition` semantic layer + registry
- [ ] EP-6: events, page-views, users, conversion endpoints return correct aggregates over fixtures
- [ ] EP-6: funnel endpoint (`windowFunnel` with documented fallback) returns correct step counts
- [ ] EP-6: basic retention (query-time cohorts over `events_resolved`) and sessions
      (`uniqExact(session_id)` counts); acquisition/feature-adoption/organizations/custom
      stubbed at 501
- [ ] EP-7: `kansoku-client` typed event constructors + batching + retry, delivery via `servant-client` over the shared `IngestAPI`
- [ ] EP-7: SDK integration test emits events that appear in `events_raw`
- [ ] EP-8: `openApiDoc` built from `KansokuAPI` via `servant-openapi-hs`, schema instances for `AnalyticsEvent`
- [ ] EP-8: `GET /openapi.json` served and verified (paths + schemas present); optional docs UI


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- Discovery (2026-07-01, during research): shibuya is *consumer-only*. Producing to the queue
  is not a shibuya concern — the ingestion HTTP handler must produce with `pgmq-hs` directly
  (`sendMessage`/`batchSendMessage`), and only the writer uses shibuya. This shaped the EP-4
  split between producer (pgmq-hs) and consumer (shibuya).
- Discovery (2026-07-01, during research): shibuya's `runApp` is per-message and consuming
  `Adapter.source` directly forfeits supervision/metrics/tracing/graceful-shutdown and lacks a
  size-or-time window (Streamly 0.11 has no public time windowing). This is why the batch
  capability was added to shibuya (external dependency for EP-4) rather than hand-rolled in
  Kansoku. See the External Dependencies section.
- Discovery (2026-07-01, during research): the ClickHouse-insert ↔ pgmq-delete boundary is
  at-least-once (they are not one transaction), so a crash after a successful INSERT but before
  acknowledgement redelivers and re-inserts a batch. Kansoku therefore owns ClickHouse-side
  idempotency: EP-3 uses `ReplacingMergeTree` keyed on `eventId`, and EP-5/EP-6 account for
  duplicates (`FINAL` or dedup-aware aggregation). Recorded because it affects three plans.
- Discovery (2026-07-01, during research): `pgmq-hs` installs the pgmq schema via pure SQL
  (`pgmq-migration`), so the plain nixpkgs `postgresql` in this repo needs no binary extension.
  EP-4 relies on this.
- Discovery (2026-07-01, EP-1 implementation): any Warp-based server executable must be linked
  with the threaded RTS. Without `ghc-options: -threaded`, `kansoku-server` logged startup but
  `curl` returned `000` and stderr repeated `GHC.Internal.Event.Thread.getSystemTimerManager:
  the TimerManager requires linking against the threaded runtime`. EP-1 added the flag to the
  executable; EP-4 must preserve it when servant/Warp ingestion replaces the minimal WAI app.
- Discovery (2026-07-01, EP-2 implementation): the canonical event modules live under
  `api/Kansoku/Event*.hs`, not `src/Kansoku/Event*.hs`, because EP-1's shared
  `kansoku:kansoku-api` sub-library uses `hs-source-dirs: api`. The public module names are
  unchanged (`Kansoku.Event*`), but downstream plans should add shared API modules under `api/`
  unless they intentionally belong to the main server library.
- Dependency satisfied (2026-07-01): shibuya first-class batch processing shipped in
  `shibuya-core` 0.7.1.0 (shibuya EP-16..EP-21 all Complete). The shipped `Shibuya.Batch` API
  differs slightly from the frozen signatures EP-4 was first drafted against, and EP-4 was
  updated to the real API: the batch handler is `BatchHandler es msg = BatchInfo -> NonEmpty
  (Ingested es msg) -> Eff es BatchAck` (`BatchInfo` is the FIRST argument); `BatchConfig` fields
  are `batchSize`/`batchTimeout` (not `maxSize`/`maxLatency`) plus `batchKey`/`tickInterval`; and
  `BatchAck` ships an extra `withFallback` constructor that EP-4 now uses for the
  insert-failure-plus-dead-letter case (retry the good messages, dead-letter the undecodable
  ones). Also note the naming collision: `PgmqAdapterConfig.batchSize` (pgmq poll size) is a
  different knob from `BatchConfig.batchSize` (ClickHouse flush size).
- Validation pass (2026-07-01, pre-implementation): eleven parallel reviewers validated all
  eight child plans plus the external claims against the real shibuya/pgmq-hs/ClickHaskell/
  openapi-hs sources, the repository working tree, and `docs/initial-spec.md`. Verdict: all
  eight plans READY-WITH-FIXES; no decomposition change needed. The blocking findings, each of
  which must be fixed in the named plan before its implementation begins:
  - **Shibuya release caveat** (EP-4): the batch API is on shibuya master only, not in the
    v0.7.1.0 tag or on Hackage (0.7.0.0). See External Dependencies. EP-4's Milestone-0 check
    must verify the checkout commit, not a version bound.
  - **`db/` is gitignored wholesale** (EP-3, EP-5): `.gitignore` ignores `db/` (it is the
    Postgres state dir, `PGHOST=$PWD/db`), so the canonical `db/clickhouse/migrations/*.sql`
    files cannot be committed as written. Either narrow the ignore (e.g. `db/*` +
    `!db/clickhouse/`) or move migrations out of `db/`; whichever is chosen must be recorded
    here and cascaded to both plans.
  - **EP-5 identity-resolution SQL defect**: ClickHouse defaults to `join_use_nulls = 0`, so
    the LEFT JOIN miss fills `m.user_id` with `''` (not NULL) and
    `coalesce(nullIf(e.user_id,''), m.user_id, nullIf(e.anonymous_id,''))` never reaches the
    anonymous-id fallback — never-identified visitors are dropped from DAU/WAU and collapse
    into one `''` bucket in `events_resolved`. The plan's fixtures mask the bug (every
    anonymous fixture is identified). Fix `events_resolved`, `mv_dau`, and `mv_wau` with
    `nullIf(m.user_id, '')` (or `join_use_nulls = 1`) plus `assumeNotNull(...)` so the
    aggregate state stays `AggregateFunction(uniqExact, String)`, not `Nullable(String)`.
  - **EP-6 rollup reads use the wrong pattern**: EP-5's `dau`/`wau`/`page_views_by_route` are
    AggregatingMergeTree tables with `AggregateFunction(uniqExact, String)` state columns;
    `toFloat64(users)` with no GROUP BY is a type error. Reads must be
    `uniqExactMerge(users) ... GROUP BY day` (and `wau` keys on `week`, not `day`). EP-6's
    exact-SQL unit tests and acceptance transcripts codify the wrong form and must be rewritten.
  - **EP-6 TimeGrain module-home contradiction**: sketches define `TimeGrain` in
    `Kansoku.Metrics.Definition` (main library) while `Kansoku.Api.Metrics` (kansoku-api
    sub-library) imports it — the sub-library cannot depend on the main library. Move
    `TimeGrain` into `Kansoku.Api.Metrics` per this MasterPlan's integration point.
  - **EP-2 circular module structure**: `Kansoku.Event` re-exports `Kansoku.Event.Registry`
    and `Kansoku.Event.Validation`, which both import types from `Kansoku.Event` — an import
    cycle GHC rejects. Introduce an internal types module (e.g. `Kansoku.Event.Types`).
  - **EP-1 compile errors in sketches**: `camelTo2` is imported from `aeson-casing`, which
    does not export it (it lives in aeson's `Data.Aeson`/`Data.Aeson.Types`; drop the
    unjustified `aeson-casing` dep), and the prelude's blanket `Control.Lens` re-export makes
    `(.=)` ambiguous with `Data.Aeson`'s in `Kansoku.Logging`.
  - **EP-4 stale reconciliation residue**: primary `validateEvent` signature is the singular
    `Either ValidationError` form (canon is the list form), and the end-to-end verification
    query selects camelCase columns (`eventId`) against snake_case ClickHouse columns.
  - **EP-8 placeholder violates the sub-library invariant**: the placeholder
    `MetricsPlaceholderResponse` derives `O.ToSchema` inside kansoku-api, which would pull
    openapi-hs into the servant-only sub-library; use an orphan instance in `Kansoku.OpenApi`
    instead.
  - **ClickHaskell version pin** (EP-3): Hackage's latest release is 1.0.0; 1.1.0 is only a
    Hackage candidate, so a `^>=1.1` bound will not resolve — use the source-repository-package
    pin (commit `56efc1840d79c89c2a6ade3794932588b65febab`, subdir `library`) or the local corpus checkout. Separately, `nix build` via `callCabal2nix`
    resolves deps from the nixpkgs Haskell set; ClickHaskell's presence there is unverified and
    EP-3 should say how to check/handle the nix side.
  - **pgmq ecosystem caveat** (EP-4): pgmq-core/hasql/effectful/migration 0.3.0.0 are all on
    Hackage (local `packages:` entries are optional, not required), but consumers on hasql 1.10
    need the `source-repository-package` pin for the shinzui/hasql-migration fork (tag
    `4aaff6c`), as shibuya-pgmq-adapter and rei both carry.
  Scope findings needing an owner decision (recorded, not yet resolved): the spec's MVP item
  "simple dashboard integration" is covered by no plan and never explicitly deferred; the
  funnel endpoint is promised in the Vision but no milestone owns its computation; the
  retention endpoint is promised in the Vision while its substrate (retention cohorts) sits in
  the deferred Later Scope — a self-contradiction; sessionization (deriving sessions beyond the
  client-supplied sessionId) has no owner between EP-5 and EP-6; and EP-6 as drafted implements
  five endpoints and stubs six at HTTP 501, which the Vision's "answers typed metric queries"
  phrasing does not acknowledge. (All four resolved by the user on 2026-07-01 — see the
  scope-resolution Decision Log entry; the Vision and Progress sections now reflect the
  outcome.)

- Reconciliation (2026-07-01, after drafting all seven child plans in parallel): the
  independently-drafted plans drifted on shared artifacts and were reconciled. Standardized:
  ClickHouse migrations live under `db/clickhouse/migrations/000N_*.sql` applied by one
  `just ch-migrate` recipe (EP-3 previously used `db/clickhouse/0001_events_raw.sql` and a
  `create-clickhouse-schema` recipe); `event_id` is ClickHouse `String` everywhere (matching
  EP-2's `Text` ids); EP-6's unique-user path now reads EP-5's `analytics.events_resolved`
  (it had referenced non-existent `identity_map` columns and an outdated `ORDER BY`); EP-1/EP-2
  gained forward-reference notes for EP-7's `kansoku-event` sub-library. Three residual items
  are tracked below in the Decision Log rather than force-edited.


## Decision Log

Record every decomposition or coordination decision made while working on the master plan.

- Decision: Do not use the event-sourcing write path (`shibuya-message-db-adapter` /
  message-db). Ingest through a durable pgmq queue and a batched ClickHouse writer instead.
  Rationale: Analytics ingestion is write-throughput-bound with no need for per-aggregate
  ordering or domain-state replay; a columnar store batched-insert path fits the workload,
  whereas an ordered event log would bottleneck writes. This is the founding constraint of the
  initiative, given explicitly by the user.
  Date: 2026-07-01

- Decision: Use ClickHaskell (`KovalevDima/ClickHaskell`) as the ClickHouse client.
  Rationale: It explicitly supports GHC 9.12.* (the repo pins `ghc9124`) and provides
  type-safe `Generic`-derived batch inserts/selects; `scarf-sh/haskell-clickhouse` is only
  tested on GHC 9.8/9.10. Recorded so EP-3 does not re-litigate.
  Date: 2026-07-01

- Decision: Solve the batch-write tension by adding first-class batch processing to shibuya
  (external initiative shibuya masterplan 3) rather than consuming `Adapter.source` directly in
  Kansoku. EP-4 hard-depends on that feature (shibuya EP-16..EP-19).
  Rationale: Direct-source consumption forfeits supervision/metrics/tracing/graceful-shutdown
  and lacks a size-or-time window; batching belongs next to the adapters and is reusable across
  sinks. The user authored the shibuya batch masterplan and is implementing it; we proceed
  assuming it is available when EP-4 begins.
  Date: 2026-07-01

- Decision: Keep the writer backend-agnostic (shibuya `Adapter`) so the Kafka path can be
  added later via `shibuya-kafka-adapter` as a wiring change; do not build Kafka now.
  Rationale: The spec's "durable queue / pub-sub" allows either; pgmq is already in the stack
  and needs no extra infrastructure, so it is the MVP backend. The abstraction preserves the
  option without paying Kafka's operational cost now.
  Date: 2026-07-01

- Decision: Own idempotency in ClickHouse via `ReplacingMergeTree` keyed on `eventId`, rather
  than attempting exactly-once across the queue/ClickHouse boundary.
  Rationale: The INSERT and the pgmq ack cannot share a transaction; at-least-once + dedup on a
  natural key is the standard, robust analytics pattern and keeps the writer simple.
  Date: 2026-07-01

- Decision: Scope the MVP to the Haskell backend plus a Haskell server SDK; defer the JS/React
  browser SDKs to a later initiative.
  Rationale: The repository is a Haskell-only Nix flake; introducing a JS toolchain is a
  separate effort. Chosen by the user.
  Date: 2026-07-01

- Decision: Decompose into seven child plans across four phases (Foundation; Write path; Read
  path; Client surface), splitting storage (EP-3) from the queue pipeline (EP-4) and rollups
  (EP-5) from the query API (EP-6).
  Rationale: Isolates the externally-dependent write-path plan (EP-4) from the independently
  verifiable storage layer (EP-3), and keeps each plan within MASTERPLAN.md's scope guidance.
  Date: 2026-07-01

- Decision: Canonicalize the ClickHouse migration layout as ordered idempotent files under
  `db/clickhouse/migrations/000N_*.sql` applied by a single `just ch-migrate` recipe, and fix
  `event_id` as ClickHouse `String` in every plan.
  Rationale: EP-3 and EP-5 drafted divergent paths/recipe names; a single mechanism keeps
  migrations composable and re-runnable. `String` matches EP-2's free-form `Text` ids.
  Date: 2026-07-01

- Residual (tracked, not yet resolved): EP-5's Milestone-0 temporary `0001_events_raw.sql`
  stand-in defines a reduced 18-column table (all `String DEFAULT ''`) whereas EP-3's
  authoritative table has 24 columns with `Nullable`/`LowCardinality` types. It is labeled
  temporary and superseded by EP-3, and EP-5 only relies on the column names it actually uses,
  so it is acceptable as a novice-simple fixture; if strict parity is wanted, regenerate the
  stand-in from EP-3's CREATE TABLE when EP-5 is implemented.
  Date: 2026-07-01
  (Resolved 2026-07-01 during the fix cascade: EP-5's stand-in was regenerated verbatim from
  EP-3's authoritative CREATE TABLE, including the `ReplacingMergeTree(received_at)` version
  argument.)

- Decision: Add EP-8 to generate an OpenAPI 3 document from the servant API type using the
  author's `shinzui/openapi-hs` and `shinzui/servant-openapi-hs`, served at `GET /openapi.json`.
  Rationale: an open-source, self-hostable analytics service needs a machine-readable API
  contract for docs and generated clients (including the deferred TypeScript SDK via
  `openapi-typescript`). Placed in Phase 4 alongside the SDK; depends on EP-4 and EP-6 API
  types. The initial draft omitted this; the user flagged the author's own openapi libraries.
  Date: 2026-07-01

- Decision: The Haskell SDK (EP-7) reuses the shared servant API type via `servant-client`
  rather than hand-written `http-client` + JSON, and the servant API *type declarations* are
  factored into an internal `kansoku:kansoku-api` sub-library (depending on `servant` only) that
  also holds the event model. This reverses EP-7's initial draft decision and makes EP-4 a hard
  dependency of EP-7.
  Rationale: deriving the client from the same type the server serves makes drift impossible at
  the type level; the light sub-library resolves the original objection (that reusing the type
  would drag in servant-server/warp). The same sub-library lets EP-8 derive OpenAPI from the
  same type. Chosen by the user. Supersedes the earlier `kansoku-event` sub-library name.
  Date: 2026-07-01

- Decision: Adopt the project Haskell coding standards at
  `/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/core/` across all child plans — GHC2024 + the
  mandated `common` cabal stanza, a `Kansoku.Prelude` custom prelude, postpositive qualified
  imports, strict fields + explicit deriving strategies, generic-lens `#label` record access, and
  MultilineStrings for embedded SQL/JSON. EP-1 establishes the concrete setup (common stanza +
  prelude in the `kansoku-api` sub-library); every other plan follows it.
  Rationale: these are the baseline standards for every Haskell project in this codebase; the
  initial plan drafts omitted them and were revised to comply. Recorded so the standards are not
  re-litigated per plan. See the "Coding standards and the custom prelude" integration point.
  Date: 2026-07-01

- Residual (tracked): the ReplacingMergeTree dedup is described in EP-4/EP-6/EP-7 with the
  shorthand "keyed on event_id"; the precise behavior is dedup over the full `ORDER BY
  (account_id, user_id, event_name, occurred_at, event_id)` with `received_at` as the version
  column. The one place EP-6 gave an explicit wrong `ORDER BY` was corrected; the informal
  shorthand elsewhere is left as acceptable.
  Date: 2026-07-01


- Decision: Resolve the three open scope questions (chosen by the user). Dashboard integration
  (spec MVP item 14) is explicitly deferred to the later frontend initiative alongside the JS
  SDKs — the typed metrics API plus EP-8's OpenAPI document are the machine-readable surface
  any dashboard will consume. `GET /metrics/retention` is implemented in EP-6 as basic
  query-time cohorts over `analytics.events_resolved` (cohort by first-seen day; no rollup),
  superseding its earlier 501-stub decision. `GET /metrics/sessions` is implemented in EP-6 as
  `uniqExact(session_id)` counts over `events_raw` — counts only; sessionization proper
  (derived boundaries/durations) stays deferred. Funnel required no decision: EP-6 already
  implements it via `windowFunnel`; the Progress checklist now names it explicitly. Resulting
  MVP endpoint surface: seven implemented, four stubbed at 501 (acquisition, feature-adoption,
  organizations, custom).
  Rationale: closes the coverage gaps and the Vision/Later-Scope retention contradiction found
  by the validation pass, with useful basic answers and no new rollup machinery.
  Date: 2026-07-01

- Decision: Commit ClickHouse migrations by narrowing the repo `.gitignore` from `db/` to
  `db/*` plus `!db/clickhouse/`; EP-3 owns the edit and EP-5 verifies it as a precondition.
  Rationale: `db/` is the Postgres state dir and was ignored wholesale, which made the
  canonical `db/clickhouse/migrations/` layout uncommittable; narrowing preserves the layout
  every plan already references with minimal churn.
  Date: 2026-07-01

- Decision: Performance adjustments from the architecture review, cascaded into the plans.
  (a) EP-4's writer flush window `BatchConfig.batchTimeout` raised from 1 s to 5 s: each flush
  is one ClickHouse INSERT creating a part, and a 1 s window at low traffic sits right at
  ClickHouse's recommended sustained insert ceiling, creating merge pressure; latency to
  queryability is not a product requirement for analytics. (b) The MVP accepts pgmq
  archive-as-dead-letter: `deadLetterConfig = Nothing`, so undecodable messages land in pgmq's
  archive table (observable there), and the adapter's `maxRetries` is the retry budget —
  retry-then-DLQ is adapter-owned, not handler logic. (c) Recorded throughput/read-path
  trades: the sustained-throughput ceiling of the write path is PostgreSQL, not ClickHouse
  (each event is WAL'd on send, read on poll, deleted/archived on ack — roughly 3x write
  amplification), so sustained volume must arrive via `POST /v1/batch`, autovacuum health on
  the queue table matters, unlogged queues are the documented durability-for-WAL trade, and
  the Kafka adapter is the escape hatch; `uniqExactState` rollups keep exact per-bucket sets
  (switch DAU/WAU to `uniqCombinedState` at volume); queries drop `FINAL` where `uniqExact`
  over `event_id`/`canonical_user` is already duplicate-tolerant; and the `identity_map`
  query-time join becomes a ClickHouse dictionary (`dictGet`) when the map grows. All accepted
  MVP trades, recorded so they are deliberate.
  Date: 2026-07-01

- Decision: Gate implementation start on cascading the validation-pass fixes into the child
  plans. A pre-implementation validation (2026-07-01, eleven parallel reviewers) judged all
  eight child plans READY-WITH-FIXES with the decomposition sound; the blocking items are
  enumerated in Surprises & Discoveries ("Validation pass"). Each child plan's fixes must be
  applied to that plan (and this document where noted) before its status moves to In Progress.
  The four open scope questions (dashboard integration, funnel ownership, retention
  contradiction, sessionization ownership) are user decisions and remain open.
  Rationale: several findings are compile-blocking or silently corrupt metrics (EP-5's
  join_use_nulls defect, EP-6's aggregate-state reads), and fixing plans is far cheaper than
  fixing implementations; the external-dependency claims were verified against real sources so
  the plans now target actual code, not remembered APIs.
  Date: 2026-07-01

## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion. Compare
the result against the original vision.

(To be filled during and after implementation.)


## Revision Notes

- 2026-07-01: EP-2 implementation completed. Marked "Canonical event model and schema
  registry" Complete in the Exec-Plan Registry, checked the two EP-2 aggregate Progress rows,
  corrected shared event-module file paths to `api/Kansoku/Event*.hs`, and recorded the
  source-root discovery for downstream plans. Evidence is recorded in
  `docs/plans/2-canonical-event-model-and-schema-registry.md`: `cabal build all`,
  `cabal test` (11 examples, 0 failures), and `nix build` all passed.

- 2026-07-01: EP-1 implementation completed. Marked "Project skeleton and application runtime"
  Complete in the Exec-Plan Registry, checked the three EP-1 aggregate Progress rows, and added
  the Warp/threaded RTS discovery that affects EP-4's future servant/Warp server work. Evidence
  is recorded in `docs/plans/1-project-skeleton-and-application-runtime.md`: `cabal build all`,
  `cabal test`, `nix build`, and HTTP `/health` all passed.

- 2026-07-01: Initial MasterPlan authored and all seven child ExecPlans (EP-1..EP-7) drafted
  and reconciled. After the parallel drafting pass, a cross-plan consistency reconciliation
  standardized the ClickHouse migration layout (`db/clickhouse/migrations/000N_*.sql` +
  `just ch-migrate`), the `event_id` `String` type, EP-6's use of `analytics.events_resolved`,
  and the `validateEvent` list-error signature, and added EP-7 `kansoku-event` sub-library
  forward references to EP-1/EP-2. The Integration Points, Surprises & Discoveries, and
  Decision Log sections above were updated accordingly. Why: the seven plans were drafted
  concurrently for speed and needed a reconciliation step so shared artifacts agree, per
  MASTERPLAN.md's requirement that integration points be documented identically wherever they
  are touched.

- 2026-07-01: Added EP-8 (OpenAPI schema generation via the author's `openapi-hs` /
  `servant-openapi-hs`, served at `GET /openapi.json`) as a second Phase-4 plan, and changed
  EP-7 to derive its client from the shared servant API type via `servant-client` (reversing
  its initial hand-written-`http-client` decision). Introduced the shared `kansoku:kansoku-api`
  internal Cabal sub-library (holding the event model and the servant API type declarations,
  depending on `servant` only), which supersedes the earlier `kansoku-event` sub-library and is
  the reuse point for the server (handlers), EP-7 (servant-client), and EP-8 (OpenAPI). Updated
  the Exec-Plan Registry (EP-7 hard-dep now EP-2+EP-4; added EP-8 with hard-deps EP-4+EP-6),
  the Decomposition Strategy Phase 4 paragraph, the Dependency Graph, two Integration Points
  (the HTTP contract point and a new shared-API-type point) plus the cabal point, the Progress
  checklist, and the Decision Log. Why: an open-source analytics service needs a published
  OpenAPI contract, and both the SDK and the schema should be generated from one servant type so
  they cannot drift — a structure requested by the user. Child plans EP-1, EP-2, EP-4, EP-6, and
  EP-7 were updated in parallel to reference the `kansoku-api` sub-library and place their API
  types in it.

- 2026-07-01: The external dependency (shibuya first-class batch processing) shipped in
  `shibuya-core` 0.7.1.0 with all six shibuya child plans Complete. Marked the External
  Dependencies section satisfied, added a Surprises & Discoveries entry documenting the shipped
  API's small differences from the frozen spec, and updated EP-4 to target the real
  `Shibuya.Batch` API (Milestone-0 gate demoted to a precondition check; batch handler now takes
  `BatchInfo` first; `BatchConfig.batchSize`/`batchTimeout`; `withFallback` used for the
  insert-failure/dead-letter path). Why: the dependency is now real, so the plan targets actual
  code instead of frozen signatures. EP-4's Exec-Plan Registry status remains Not Started — the
  dependency is available but Kansoku's own implementation has not begun.

- 2026-07-01: Pre-implementation validation pass recorded. Eleven parallel reviewers validated
  the eight child plans (structure per PLANS.md, self-containment, integration-point
  consistency, ClickHouse semantics) and verified the external claims against the real shibuya,
  pgmq-hs, ClickHaskell, and openapi-hs/servant-openapi-hs sources, the repo working tree, and
  the product spec. Updated this document: corrected "seven child ExecPlans" to eight in the
  Decomposition Strategy, corrected the registry note's external-dependency range to shibuya
  EP-16..EP-21, added the shibuya release caveat to External Dependencies (batch API is on
  master only — the v0.7.1.0 tag and Hackage releases lack it, so the dependency must be a
  commit-pinned checkout, not a version bound), added the "Validation pass" findings to
  Surprises & Discoveries, and added a Decision Log entry gating implementation on cascading
  the fixes into the child plans. Why: the user asked for the plan to be validated before
  implementation begins; the findings live here so the fix-cascade and the open scope decisions
  (dashboard, funnel, retention, sessionization) are tracked in the coordination document.

- 2026-07-01: Fix cascade applied after the validation pass and an architecture review. All
  eight child plans were revised in place (each carries its own Revision Note): EP-1
  (camelTo2/aeson-casing and `(.=)` ambiguity compile fixes, stale claims), EP-2 (import-cycle
  restructure via `Kansoku.Event.Types`, contract-wording fixes), EP-3 (`.gitignore` narrowing
  step, ClickHaskell git-pin as primary with the Hackage-candidate caveat, nix-build honesty
  note, `ch-migrate --port`, dedup-semantics clarifications), EP-4 (commit-pinned shibuya
  Milestone-0 check, list-form `validateEvent`, snake_case verification query, helper
  definitions, archive-as-DLQ decision, `batchTimeout` 1 s → 5 s, pgmq-ceiling paragraph,
  hasql-migration fork pin), EP-5 (join_use_nulls empty-string fix in `events_resolved`/
  `mv_dau`/`mv_wau` with a never-identified fixture, stand-in regenerated from EP-3's DDL,
  FINAL-avoidance rule, dictionary and uniqCombined notes), EP-6 (uniqExactMerge/GROUP BY
  rollup reads, TimeGrain re-homed to `Kansoku.Api.Metrics`, events/page_views registry
  entries, required funnel `steps` param, basic retention and sessions implemented per the
  user's scope decisions), EP-7 (IngestAck/BatchAck client types, `EventIds` identity record
  for the helpers, sendNow resolution, stale-quote removal), EP-8 (placeholder ToSchema moved
  to an orphan instance in `Kansoku.OpenApi`, IngestAck/BatchAck naming, Tag signature and
  line-reference corrections, provisional-acceptance note). This document was updated in the
  same pass: Vision (agent systems source; seven-implemented/four-stubbed endpoint statement),
  explicit dashboard deferral in the out-of-scope paragraph, corrected `ORDER BY` in the
  Decomposition Strategy and events_raw integration point, `bytestring` added to the
  kansoku-api dependency list, Progress checklist expanded for EP-5 wording and EP-6's
  funnel/retention/sessions milestones, and three new Decision Log entries (scope resolutions,
  `.gitignore` narrowing, performance adjustments). Why: the user approved incorporating the
  validation and architecture-review fixes and resolved the three open scope questions, so the
  plans now target verified APIs and consistent shared artifacts before implementation begins.

- 2026-07-01: Adopted the project Haskell coding standards from
  `/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/core/`, which the initial plan drafts had
  omitted. Added a "Coding standards and the custom prelude" integration point and a Decision Log
  entry; EP-1 now establishes the GHC2024 `common` cabal stanza (`DeriveAnyClass`,
  `DuplicateRecordFields`, `OverloadedLabels`, `OverloadedStrings`, `MultilineStrings`) and the
  `Kansoku.Prelude` module in the `kansoku-api` sub-library, and all eight child plans were
  updated to follow the standards (postpositive qualified imports, `import Kansoku.Prelude`,
  strict fields + explicit deriving strategies, generic-lens `#label`, and MultilineStrings for
  embedded SQL/JSON). Why: these are the non-negotiable baseline standards for every Haskell
  project in this codebase, and the plans must encode them so a novice implementer produces
  compliant code.
