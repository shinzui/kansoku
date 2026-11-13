# Changelog

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
