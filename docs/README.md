# Kansoku documentation

Kansoku is a self-hosted analytics service with authenticated event ingestion, a durable
PostgreSQL queue, ClickHouse storage, identity resolution, and an account-scoped metrics API.
Start with the quickstart, then use the guides for the part of Kansoku you are integrating.

## Adopt Kansoku

The [guide catalog](guides/index.md) groups these pages by reader intent under the shared
OKF documentation profile, with stable `DOC-N` handles. Run `just guides-check` to validate
the bundle and its migration log.

1. [Run Kansoku locally](guides/getting-started.md) — start the dependencies, migrate both
   databases, issue credentials, send an event, and query it.
2. [Send events](guides/send-events.md) — use the HTTP contract, versioned event schemas,
   batches, identity signals, and retry semantics correctly.
3. [Query metrics](guides/query-metrics.md) — call the live product, funnel, retention,
   property, revenue, and experiment endpoints.
4. [Use the Haskell SDK](guides/haskell-sdk.md) — add the client package, buffer events,
   flush safely, pin schema versions, and use typed experiment clients.
5. [Configure Kansoku](guides/configuration.md) — set database, writer, CORS, ingest,
   readiness, telemetry, and server options.
6. [Operate Kansoku](guides/operations.md) — use health, readiness, Prometheus metrics,
   traces, migration commands, credential revocation, and recovery procedures.

- [Consume ClickHouse](guides/consume-clickhouse.md) documents the constrained SQL reader, exact recipes and verified Grafana/GrowthBook integrations.

- [Initialize and upgrade ClickHouse](guides/clickhouse-migrations.md) covers retained native
  identities, maintenance sessions, external drain, first initialization, and explicit recovery.
  Native execution currently requires the qualified arm64 macOS artifact; Linux qualification
  and the deployment target remain release gates.

- [Web enrichment and acquisition](guides/web-enrichment.md) documents first-touch sessions, device/bot rules and optional trusted country lookup.

## Contract references

- [OpenAPI 3 document](api/openapi.json) is generated from the served route types and is also
  available from a running server at `GET /openapi.json`.
- [Event schema catalog](contracts/events.json) is generated from Kansoku's versioned event
  registry and is also available without credentials at `GET /v1/schemas`.
- [Event schema governance](event-schema-governance.md) explains how maintainers add and
  version event contracts.

Regenerate the references with `just openapi` and `just contracts`. CI-style checks are
available as `just openapi-check` and `just contracts-check`. Do not edit either generated JSON
file by hand.

## Operations and project records

- [Developer guide](guides/development.md) describes compiler, record, route and generated-contract conventions.

- [Architecture atlas](artifcats/kansoku-architecture.html) is a self-contained, light-theme
  visual guide to the current system, from high-level data flow to contracts, storage,
  identity resolution, metric queries, operations, and source modules.
- [Identity data deletion and fingerprint retention](runbooks/identity-data-deletion.md) is the
  destructive-data runbook for identity erasure and fingerprint retention.
- [Product vision](initial-spec.md) describes Kansoku's direction. It is not a list of shipped
  APIs; the guides and generated references above describe the current release.
- [Architecture decisions](adr/) capture durable design constraints.
- [Capabilities](capabilities/index.md) catalog what the current checkout provides, with
  compatibility limits and source/test evidence. Run `just capabilities-check` to validate it.
- [Terminology](terminology/index.md) defines the project's vocabulary by reader journey,
  including consequential distinctions around identity, retention and analytical populations.
  Run `just terminology-check` to validate it.
- [Reviews](reviews/) record artifact examinations under the shared OKF review profile.
  Run `just reviews-check` to validate the bundle and its log.
- [MasterPlans](masterplans/) and [ExecPlans](plans/) are implementation history. Completed
  plans can describe an earlier state and are not user documentation.

[Back to the repository README](../README.md)
