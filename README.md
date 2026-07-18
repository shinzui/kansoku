# 観測 · Kansoku

**A first-party, self-hostable, ClickHouse-native analytics service.**

Kansoku is the observation layer for modern applications — it observes how users,
applications, services, campaigns, and systems behave over time, and answers product,
web, and business questions from a single unified event stream.

---

## The name

**観測（かんそく / _Kansoku_）** is Japanese for **"observation."**

The name is the thesis. Kansoku does not run your business logic, own your users, or
send your email. It *observes* — it watches what your product and its supporting
systems actually do and turns that into answerable questions:

> Are users activating? Which features engage them? Which channels convert? Where do
> users drop off? Which experiments move the needle? How do backend events correlate
> with what users see?

Other services emit facts. Kansoku observes them.

## Vision

Most analytics is bolted on from the outside: a third-party script tells you what a
browser *attempted*, disconnected from what your backend knows actually *happened*.
Kansoku collapses that gap.

- **First-party.** You self-host it. Your events, your ClickHouse, your data — no
  third-party pixel, no sampling, no data leaving your infrastructure.
- **Event-first, both sides of the wire.** Client-side analytics tells you what a user
  *tried*. Server-side analytics tells you what actually *committed*. Kansoku ingests
  both — browser SDK events *and* authoritative backend/domain events — into one
  canonical event model, so product behavior and business facts live in the same table.
- **ClickHouse-native.** A columnar store is the system of record. Raw events are
  append-only truth; materialized views and rollups make common metrics cheap.
- **Typed, not a BI tool.** Instead of exposing arbitrary SQL, Kansoku offers a
  semantic metrics layer and a typed `GET /metrics/*` query API. Metrics stay
  consistent across dashboards, product widgets, reports, and automated summaries.
- **Simple to self-host, friendly to microservices and agents.** One binary
  (`kansoku-server`), a durable queue, and ClickHouse. Opinionated enough to be
  useful out of the box; generic enough to open source.

Kansoku observes the system without becoming part of the business domain.

### What Kansoku owns — and doesn't

| Kansoku **owns** | Kansoku does **not** own |
| --- | --- |
| Event ingestion & validation | Business workflows |
| Event schema registry | User / account / org source of truth |
| Identity stitching | Billing source of truth |
| ClickHouse writes & raw storage | Email sending |
| Materialized views & rollups | Authorization |
| Semantic metrics & typed query API | CRM state |
| Product, web, and campaign analytics | |

## Architecture

The defining decision: **the write path is deliberately _not_ event-sourced.** Analytics
ingestion is throughput-bound — enormous write volume, no need for per-aggregate ordering
or replay. So Kansoku ingests through a durable queue and a **batched** writer, amortizing
each ClickHouse `INSERT` across thousands of rows.

```txt
 Browser SDK ─┐
 Backend      │
 Workers      ├──▶  Ingestion API  ──▶  pgmq durable queue  ──▶  batched writer  ──▶  ClickHouse
 Email/agents │     POST /v1/events      (PostgreSQL, via         (shibuya, one         ├─ events_raw (source of truth)
              ┘     POST /v1/batch        pgmq-hs)                 INSERT / batch,       ├─ materialized views
                                                                   via ClickHaskell)     └─ rollups
                                                                                              │
                                          Typed query API  ◀───────────────────────────────┘
                                          GET /metrics/*   ──▶ dashboards · product widgets · reports
```

- **Ingest** enqueues onto a PostgreSQL-backed [pgmq] queue via [`pgmq-hs`]. Producing
  is direct; no event-sourcing log.
- **Write** is a [shibuya] consumer (`shibuya-pgmq-adapter`) that pulls events in
  batches and performs one ClickHouse insert per batch via [ClickHaskell]. The
  ClickHouse↔queue boundary is at-least-once, so `events_raw` is a `ReplacingMergeTree`
  keyed on `event_id` and ClickHouse owns idempotency.
- **Read** resolves anonymous→known identity at query time and serves reusable metrics
  through a typed API — no raw SQL exposed.

[pgmq]: https://github.com/tembo-io/pgmq
[`pgmq-hs`]: https://github.com/shinzui/pgmq-hs
[shibuya]: https://github.com/shinzui/shibuya
[ClickHaskell]: https://github.com/KovalevDima/ClickHaskell

### Packages

A Haskell (GHC 9.12, effectful + servant + warp) codebase split by role:

| Package | Role |
| --- | --- |
| `kansoku-api` | Shared prelude, canonical event model, wire DTOs, and servant route *types* — the drift-proof API contract. |
| `kansoku-core` | Runtime, storage adapters, ingestion, batched writer, metrics, OpenAPI generation, HTTP app assembly. |
| `kansoku-server` | The `kansoku-server` executable — servant/warp HTTP application. |
| `kansoku-client` | Typed Haskell client derived from `kansoku-api` via `servant-client`. |

## Roadmap

### ✅ MVP — delivered

The MVP is coordinated by a MasterPlan (`docs/masterplans/`) decomposed into eight
ExecPlans (`docs/plans/`), all implemented:

1. **Foundation** — project skeleton & runtime; canonical event model + schema registry.
2. **Write path** — ClickHouse `analytics.events_raw` schema + batched writer;
   HTTP ingestion (`POST /v1/events`, `/v1/batch`) → pgmq queue → shibuya batched writer.
3. **Read path** — identity stitching + materialized-view rollups; semantic metrics
   layer + typed `GET /metrics/*` query API.
4. **Client & contract** — Haskell server SDK (`kansoku-client`); OpenAPI schema
   generation serving `GET /openapi.json`.

**Metrics endpoints:** seven are live — `events`, `page-views`, `sessions`, `funnel`,
`retention`, `conversion`, `users`. Four are typed routes present in the contract and
OpenAPI document but returning `501 Not Implemented` in the MVP — `acquisition`,
`feature-adoption`, `organizations`, `custom`.

### 🔜 Next — frontend & SDKs

The MVP ships the Haskell core and server SDK. Deferred to the next initiative:

- Browser / Web SDK (`kansoku-js`)
- React SDK (`kansoku-react`)
- A dashboard UI over the metrics API

### 🌌 Later scope

From the product spec (`docs/initial-spec.md`) — candidates, not commitments:

- Experimentation & feature-flag exposure tracking
- Anomaly detection & automated analytics summaries
- Natural-language metric queries
- Path analysis · richer retention cohorts · session-replay metadata
- OpenTelemetry bridge · integration-event (outbox) bridge
- Data-quality checks · privacy controls · tenant-level retention policies

## Getting started

Everything runs locally via Nix + `process-compose` (PostgreSQL + ClickHouse). Common
tasks are in the `justfile`:

```sh
nix develop            # enter the dev shell
just up                # start postgres, clickhouse, create the db
just create-database   # create the `kansoku` database (if needed)
just ch-migrate        # apply and record unapplied ClickHouse migrations
just build             # cabal build all
just test              # run the test suite
just run               # run the kansoku-server executable
```

## Documentation

- **Product spec:** [`docs/initial-spec.md`](docs/initial-spec.md) — the full vision.
- **MasterPlan:** [`docs/masterplans/1-kansoku-analytics-service-mvp.md`](docs/masterplans/1-kansoku-analytics-service-mvp.md)
- **ExecPlans:** [`docs/plans/`](docs/plans/) — the eight child plans.

---

_Kansoku observes user behavior, application behavior, and business events through one
unified layer — while staying independent of any specific product or workflow._
