# Changelog

## 0.2.1.0 — 2026-11-14

### New Features

- Require complete recovery sets before native ClickHouse migration and support audited adoption of a verified rebuilt direct server.
- Verify renamed ClickHouse restores read-only against the embedded schema expectation and trusted retention policy.
- Require per-entry diagnostic persistence before owner-bound repair authorization.
- Run on kansoku-core 0.3.0.0, including ClickHouse outage buffering, analyses, calendar retention, and user host counts.

### Bug Fixes

- Require fresh owner-bound drain authority before native maintenance.

### Other Changes

- Pin the clickhouse-migrate toolkit to a qualified source revision that provides the external-drain API.
- Add ClickHouse recovery and schema contract test suites and Nix-native outage buffering qualification.
- Publish this package through GitHub tags and releases only. The runnable distribution is the TAN container image.

## 0.2.0.0 — 2026-11-12

### Breaking Changes

- Adopt the revised core runtime and explicit PostgreSQL and ClickHouse migration requirements.

### New Features

- Ship server, administration, PostgreSQL migration, and ClickHouse migration executables.
- Select and fence direct or replicated migration targets with embedded migration histories.
- Add API key issuance, ingestion CORS, telemetry, readiness, and graceful shutdown.
- Support configured replica consistency and qualified replicated runtime operation.

### Bug Fixes

- Coordinate server and writer lifetimes and preserve graceful draining.
- Rebuild retained sessions without counting diagnostic events as engagement.

### Other Changes

- Use the released clickhouse-migrate 0.2.0.0 cohort.
- Publish this package through GitHub tags and releases only. The runnable distribution is the TAN container image.
