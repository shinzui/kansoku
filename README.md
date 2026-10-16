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
- Multi-signal identity evidence for cookies, devices, hashed email, and expiring fingerprints,
  with conflict visibility and query-time resolution.
- Web enrichment, bot flagging, first-touch acquisition, whole-session analytics, and governed
  current person and organization traits.
- Product, rolling activity, retention, lifecycle, property, revenue, and exposure-based
  experiment metrics; event paths and page flows; sequential, strict, and any-order funnels
  with unique or nonoverlapping attempt counts and property attribution.
- Saved behavioural and static cohorts, ad-hoc and saved custom metrics, bounded AND-of-OR
  filters, and organization counts and aggregation across member activity.
- Constrained SQL reader views and verified Grafana/GrowthBook consumption.
- Fenced, resumable administration for credentials, user erasure, applied retention, archive
  replay, and ingest rejection diagnostics.
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
- [Configure Kansoku](docs/guides/configuration.md)
- [Operate Kansoku](docs/guides/operations.md)
- [Administer credentials, retention, erasure, and replay](docs/guides/administration.md)
- [Explore the architecture atlas](docs/artifcats/kansoku-architecture.html)

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
state alongside event analytics, with a separate forward-only migration ledger. Normal server
startup performs neither schema migration.

Trusted SQL consumers use constrained reader views directly. They coordinate their own pause
during maintenance; the HTTP traffic fence does not cover external database queries.

## API status

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
| `kansoku-server` | `kansoku-server`, explicit migrations via `kansoku-migrate`, and lifecycle operations via `kansoku-admin`. |
| `kansoku-client` | Buffered Haskell producer SDK and typed metrics, cohort, and saved-definition clients. |

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
