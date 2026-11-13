# Changelog

## 0.2.0.0 — 2026-11-12

### Breaking Changes

- Adopt named API routes, typed responses, RFC 9457 problems, and partial batch rejection accounting.

### New Features

- Provide buffered event ingestion with versioned schemas and multi-signal identifiers.
- Add typed queries for filters, whole-range aggregation, funnels, paths, cohorts, organizations, custom metrics, session selection, and resolved users.
- Fetch the public event schema catalog.

### Bug Fixes

- Retry only transport failures and retryable outages; stop retrying permanent API failures.
- Validate metric parameters against the preserved routed path.

### Other Changes

- Bound the library and test dependencies to kansoku-api ^>=0.2.0.0.
