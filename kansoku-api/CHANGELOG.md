# Changelog

## 0.2.0.0 — 2026-11-12

### Breaking Changes

- Replace positional route types with named routes and typed success and RFC 9457 problem responses.
- Require indexed rejection details in partial batch acknowledgements.
- Remove legacy monitoring endpoints from the API.

### New Features

- Publish versioned event contracts, validation, and generated OpenAPI and schema artifacts.
- Add bounded filters, grouping, whole-range and percentile aggregation, funnels, paths, acquisition, session, and experiment metrics.
- Add cohorts, saved metric definitions, organizations, identified user profiles and history, and resolved user selection.
- Declare client error and web vital events.

### Bug Fixes

- Reject storage-incompatible JSON before ingestion acceptance.
- Exclude diagnostic events from session engagement and document the users pagination minimum as one.
