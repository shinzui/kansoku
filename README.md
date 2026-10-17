# 観測 · Kansoku

**A first-party, self-hosted, ClickHouse-native analytics service.**

Kansoku (観測, “observation”) accepts browser and backend events into one account-scoped event
model, writes them through a durable PostgreSQL queue to ClickHouse, resolves user identity at
query time, and serves reusable metrics through a typed HTTP API.

## What ships today

- Authenticated single, partial-batch, and browser-exit ingestion at `POST /v1/events`,
  `POST /v1/batch`, and `POST /v1/beacon`.
- Write keys for producers and service tokens for account-scoped analytics and saved resources.
- A versioned event registry published at `GET /v1/schemas` and
  [`docs/contracts/events.json`](docs/contracts/events.json).
- Immutable event acceptance, at-least-once PostgreSQL PGMQ delivery, and a supervised Shibuya
  batch writer with bounded outage recovery and replay-safe ClickHouse reads and rollups.
- Pre-acceptance validation of event schemas and native JSON storage compatibility, with
  indexed per-event rejections for batches and beacons and per-credential rate limiting.
- Multi-signal identity evidence for cookies, devices, hashed email, and expiring fingerprints,
  with conflict visibility and query-time resolution.
- Web enrichment, bot flagging, first-touch acquisition, whole-session analytics, and governed
  current person and organization traits.
- Product, rolling activity, retention, lifecycle, property, revenue, and exposure-based
  experiment metrics; event paths and page flows; sequential, strict, and any-order funnels
  with unique or nonoverlapping attempt counts and property attribution.
- Saved behavioural and static cohorts, ad-hoc and saved custom metrics, bounded AND-of-OR
  filters (including current organization traits in cohort event conditions), and organization
  counts and aggregation across member activity.
- Constrained SQL reader views and verified Grafana/GrowthBook consumption.
- Fenced, resumable administration for credentials, user erasure, applied retention, archive
  replay, and ingest rejection diagnostics.
- Explicit ClickHouse migrations through `kansoku-ch-migrate`, with an embedded checksummed
  plan, persistent maintenance sessions, and deliberate recovery after interruption.
- OpenAPI at `GET /openapi.json`, liveness at `GET /health/live`, readiness at
  `GET /health/ready`, safe correlated JSON access logs, Prometheus metrics at
  `GET /internal/metrics`, and opt-in OpenTelemetry trace export.
- A buffered Haskell producer SDK and typed Haskell metrics clients.

Browser and React SDKs are implemented in the separate
[kansoku-ts repository](mori://shinzui/kansoku-ts/repos/kansoku-ts):
[kansoku-js](mori://shinzui/kansoku-ts/packages/kansoku-js) handles browser capture, identity,
sessions, batching, retries, and exit delivery;
[kansoku-react](mori://shinzui/kansoku-ts/packages/kansoku-react) adds a provider and hooks.
Follow its [quickstart](mori://shinzui/kansoku-ts/docs/getting-started) for workspace setup and
examples. Other producers can use the documented HTTP API. A built-in dashboard UI,
experiment significance engine, and hosted/container distributions remain outside the shipped surface.

## Start here

The [documentation index](docs/README.md) separates adopter guides, generated contracts,
operations, and internal project records.
The [capability catalog](docs/capabilities/index.md) describes the current implementation with
evidence and limits; the [terminology catalog](docs/terminology/index.md) explains its vocabulary.

- [Run Kansoku locally](docs/guides/getting-started.md)
- [Send events](docs/guides/send-events.md)
- [Query metrics](docs/guides/query-metrics.md)
- [Web enrichment and acquisition](docs/guides/web-enrichment.md)
- [Use the Haskell SDK](docs/guides/haskell-sdk.md)
- [Use the browser and React SDKs](mori://shinzui/kansoku-ts/docs/getting-started)
- [Consume ClickHouse from Grafana or GrowthBook](docs/guides/consume-clickhouse.md)
- [Initialize and upgrade ClickHouse](docs/guides/clickhouse-migrations.md)
- [Configure Kansoku](docs/guides/configuration.md)
- [Measure pipeline capacity and size an outage budget](docs/guides/capacity.md)
- [Operate Kansoku](docs/guides/operations.md)
- [Administer credentials, retention, erasure, and replay](docs/guides/administration.md)
- [Develop Kansoku](docs/guides/development.md)
- [Explore the architecture atlas](docs/artifcats/kansoku-architecture.html)

Local native migration execution currently requires arm64 macOS and exactly ClickHouse
26.8.28.14. Linux qualification and the deployment target remain release gates; see the
[migration runbook](docs/guides/clickhouse-migrations.md).

Install Nix with flakes enabled and enter the checkout. The development shell supplies GHC,
Cabal, PostgreSQL, ClickHouse, and the supporting command-line tools. Start the local databases
and leave this terminal running:

```bash
nix develop
just up
```

In another `nix develop` shell, apply PostgreSQL migrations and inspect the native plan:

```bash
just migrate
just ch-migrate plan --json
```

Complete the [ClickHouse initialization runbook](docs/guides/clickhouse-migrations.md) with
retained target/server/ledger identities, a persistent maintenance session and actual external
drain. The qualified development target is ClickHouse 26.8.28.14 on arm64 macOS; Linux
qualification and the deployment target remain release gates. After initialization and session
completion, issue credentials and start the service:

```bash
just issue-key write dev "local writer"
just issue-key service dev "local reader"
just run
```

Credential issuance prints each token exactly once. The service listens at
`http://localhost:8080` by default; verify `/health/live` and `/health/ready` from a third
terminal. `just up` uses port 8081 for process control. See the
[quickstart](docs/guides/getting-started.md) for a complete accepted event and metric query,
port overrides, and reuse of an existing local database.

## Architecture

```text
Browser / backend / worker
          │
          ▼
Authenticated ingestion API
POST /v1/events · POST /v1/batch · POST /v1/beacon
          │
          ▼
PostgreSQL PGMQ durable queue
          │
          ▼
Supervised Shibuya batch writer
          │
          ▼
ClickHouse canonical facts · identity · traits · replay-safe rollups
          │
          ▼
Account-scoped typed metrics API
```

Kansoku deliberately does not use event sourcing for its write path. Analytics ingestion is
throughput-oriented and does not need aggregate ordering, so the writer amortizes one ClickHouse
insert across a batch. Raw event identity is retained while user identity is resolved from
account-scoped evidence when exact user metrics are queried.

PostgreSQL migrations explicitly install the vendored PGMQ schema without requiring the upstream
PostgreSQL extension, followed by credential, acceptance, rejection, maintenance, cohort, and
metric-definition tables. ClickHouse holds static cohort membership and derived organization
state alongside event analytics. `kansoku-ch-migrate` embeds its immutable migration plan and
records checksummed history in the separate `kansoku_migration_ledger` database, coordinated
by persistent PostgreSQL maintenance sessions. Normal server startup performs neither schema
migration.

Trusted SQL consumers use constrained reader views directly. They coordinate their own pause
during maintenance; the HTTP traffic fence does not cover external database queries.

## API status

Accepted events are durable in PostgreSQL before the HTTP 202 response; ClickHouse visibility
follows asynchronously.
Identical event-ID retries acknowledge the original acceptance, while changed producer content
conflicts. Batch and beacon responses report accepted counts and indexed rejections, so inspect
the response before retrying individual events. New events with colliding flattened JSON paths
in `properties` or `context` are rejected before acceptance. See
[Send events](docs/guides/send-events.md) for authentication, JSON constraints, limits, and retries.

Implemented metric routes are:

```text
GET /metrics/events
GET /metrics/page-views
GET /metrics/sessions
GET /metrics/acquisition
GET /metrics/paths
GET /metrics/funnel
GET /metrics/retention
GET /metrics/feature-adoption
GET /metrics/conversion
GET /metrics/users
GET /metrics/stickiness
GET /metrics/lifecycle
GET /metrics/revenue
GET /metrics/organizations
GET /metrics/custom
GET /metrics/experiments
GET /metrics/experiments/conversion
GET /metrics/experiments/funnel
```

Service-token resource APIs also provide cohort CRUD at `/cohorts`, membership replacement,
member pages and size at `/cohorts/{id}/members` and `/cohorts/{id}/size`, and saved metric
definition CRUD at `/metric-definitions`. Resource and member lists use cursor pagination;
metric queries return complete answers or errors, with a 10,000-point cap and native query budgets.

Users, funnels, retention, signup conversion, and feature adoption support organization
aggregation. Identity, current traits, cohort definitions, and current organization membership
can reclassify retained history. Default unsegmented experiment exposures retain approximate
raw-identity sketches; exact resolved populations serve the documented user and funnel queries.
See [Query metrics](docs/guides/query-metrics.md) for route parameters, semantics, and accuracy
boundaries, and [Consume ClickHouse](docs/guides/consume-clickhouse.md) for the trusted SQL contract.

## Packages

| Package | Role |
| --- | --- |
| `kansoku-api` | Canonical event and schema types, response algebra, and Servant route types. |
| `kansoku-core` | Configuration, migrations, authentication, queue/writer, ClickHouse queries, telemetry, and HTTP assembly. |
| `kansoku-server` | `kansoku-server`, PostgreSQL migrations via `kansoku-migrate`, ClickHouse migrations via `kansoku-ch-migrate`, and lifecycle operations via `kansoku-admin`. |
| `kansoku-client` | Buffered Haskell producer SDK and typed metrics, cohort, and saved-definition clients. |

The locked development environment uses GHC 9.12.4. The codebase uses GHC2024, Effectful,
Servant/Warp, PostgreSQL, PGMQ, Shibuya, and ClickHouse. A pinned ClickHaskell source snapshot
lives under `vendor/ClickHaskell` and is included in the Cabal workspace.

## Development

Run common tasks inside `nix develop`:

```bash
just build
just test
just openapi-check
just contracts-check
nix fmt
```

`just openapi` and `just contracts` regenerate the committed machine-readable references. Do not
hand-edit generated JSON. The local database processes and their state live inside the checkout;
`just ch-reset` refuses because dropping analytics alone would leave native history current.
Create a new owned stack with fresh roots and identities; preserve existing data until its owner
chooses disposal.

Contributor gates run inside the locked Nix environment:

```bash
nix develop -c just check
nix develop -c just acceptance
```

`check` builds all components with tests and validates formatting, deterministic tests, generated
contracts, OpenAPI 3.1, ADRs, capability/terminology/guide catalogs, and HTTP telemetry.
`acceptance` owns disposable databases and runs native/live tests and Hurl against the
Nix-packaged executable. `just test` can report pending storage/live cases when prerequisites
are absent; use the aggregate gates for required verification. CI also builds the server,
admin, and client packages and runs `nix flake check`. See the
[developer guide](docs/guides/development.md) and the
[HTTP acceptance suite](kansoku-api/test/hurl/README.md) for fixture and evidence handling.

## Scope

Kansoku owns event validation and ingestion, analytics credentials and account boundaries,
identity evidence, ClickHouse analytics storage, derived rollups, and semantic metrics. It does
not own application authorization, business workflows, user/account source-of-truth records,
billing, email delivery, or CRM state.

The original [product vision](docs/initial-spec.md) describes longer-term direction. Current
behavior is defined by the guides, the [OpenAPI document](docs/api/openapi.json), and the
[event schema catalog](docs/contracts/events.json).
