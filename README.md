# 観測 · Kansoku

**A first-party, self-hosted, ClickHouse-native analytics service.**

Kansoku (観測, “observation”) accepts browser and backend events into one account-scoped event
model, writes them through a durable PostgreSQL queue to ClickHouse, resolves user identity at
query time, and serves reusable metrics through a typed HTTP API.

## What ships today

- Authenticated single and partial-batch ingestion at `POST /v1/events` and `POST /v1/batch`.
- Write keys for producers and service tokens for account-scoped metric reads.
- A versioned event registry published at `GET /v1/schemas` and
  [`docs/contracts/events.json`](docs/contracts/events.json).
- At-least-once PostgreSQL PGMQ delivery with a supervised Shibuya batch writer and ClickHouse
  event-ID idempotency.
- Multi-signal identity evidence for cookies, devices, hashed email, and expiring fingerprints,
  with conflict visibility and query-time resolution.
- Product, session, ordered-funnel, retention, property, revenue, and exposure-based experiment
  metrics.
- OpenAPI at `GET /openapi.json`, liveness at `GET /health/live`, readiness at `GET /health/ready`, safe correlated JSON access logs, Prometheus metrics at
  `GET /internal/metrics`, and opt-in OpenTelemetry trace export.
- A buffered Haskell producer SDK and typed Haskell metrics clients.

Browser and React SDKs, a dashboard UI, and hosted/container distributions are not yet shipped.
Non-Haskell producers use the documented HTTP API.

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
- [Configure Kansoku](docs/guides/configuration.md)
- [Operate Kansoku](docs/guides/operations.md)

The shortest local path is:

```bash
nix develop
just up
```

In another `nix develop` shell, apply both databases' migrations, issue credentials, and start
the service:

```bash
just migrate
just ch-migrate
just issue-key write dev "local writer"
just issue-key service dev "local reader"
just run
```

Credential issuance prints each token exactly once. See the
[quickstart](docs/guides/getting-started.md) for a complete accepted event and metric query.

## Architecture

```text
Browser / backend / worker
          │
          ▼
Authenticated ingestion API
POST /v1/events · POST /v1/batch
          │
          ▼
PostgreSQL PGMQ durable queue
          │
          ▼
Supervised Shibuya batch writer
          │
          ▼
ClickHouse events_raw · identity evidence · materialized rollups
          │
          ▼
Account-scoped typed metrics API
```

Kansoku deliberately does not use event sourcing for its write path. Analytics ingestion is
throughput-oriented and does not need aggregate ordering, so the writer amortizes one ClickHouse
insert across a batch. Raw event identity is retained while user identity is resolved from
account-scoped evidence when exact user metrics are queried.

PostgreSQL migrations explicitly install the vendored PGMQ schema without requiring the upstream
PostgreSQL extension, followed by Kansoku's API-key table. ClickHouse has a separate forward-only
migration ledger. Normal server startup performs neither schema migration.

## API status

Implemented metric routes are:

```text
GET /metrics/events
GET /metrics/page-views
GET /metrics/sessions
GET /metrics/acquisition
GET /metrics/funnel
GET /metrics/retention
GET /metrics/feature-adoption
GET /metrics/conversion
GET /metrics/users
GET /metrics/stickiness
GET /metrics/lifecycle
GET /metrics/revenue
GET /metrics/experiments
GET /metrics/experiments/conversion
GET /metrics/experiments/funnel
```

`GET /metrics/organizations` and `GET /metrics/custom` remain
contract placeholders and return HTTP 404 with `not_implemented`. See
[Query metrics](docs/guides/query-metrics.md) for semantics and accuracy boundaries.

## Packages

| Package | Role |
| --- | --- |
| `kansoku-api` | Canonical event and schema types, response algebra, and Servant route types. |
| `kansoku-core` | Configuration, migrations, authentication, queue/writer, ClickHouse queries, telemetry, and HTTP assembly. |
| `kansoku-server` | `kansoku-server` and the administrative `kansoku-migrate` executable. |
| `kansoku-client` | Buffered Haskell producer SDK and typed metrics clients. |

The codebase uses GHC 9.12, Effectful, Servant/Warp, PostgreSQL, PGMQ, Shibuya, and ClickHouse.

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
`just ch-reset` is development-only and destroys all local ClickHouse analytics data.

## Scope

Kansoku owns event validation and ingestion, analytics credentials and account boundaries,
identity evidence, ClickHouse analytics storage, derived rollups, and semantic metrics. It does
not own application authorization, business workflows, user/account source-of-truth records,
billing, email delivery, or CRM state.

The original [product vision](docs/initial-spec.md) describes longer-term direction. Current
behavior is defined by the guides, the [OpenAPI document](docs/api/openapi.json), and the
[event schema catalog](docs/contracts/events.json).

Contributor gates run inside the locked Nix environment:

```bash
nix develop -c just check
nix develop -c just acceptance
```

`check` validates deterministic tests, formatting, generated contracts, OpenAPI and ADRs.
`acceptance` owns disposable databases and runs native/live tests and Hurl against the
Nix-packaged executable. See [development](docs/guides/development.md) and the
[HTTP acceptance suite](kansoku-api/test/hurl/README.md) for fixture and evidence handling.
