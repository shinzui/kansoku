# Changelog

## 0.3.0.0 — 2026-11-14

### Breaking Changes

- Add the `analyses` route group to `KansokuAPI` and the `hosts` route to `Users`, changing the named route record types.
- Extend the retention route with `period`, `startEvent`, `returnEvent`, and separate start and return filter parameters.

### New Features

- Add `Kansoku.Analysis.Api` and `Kansoku.Analysis.Types` for revisioned, account-owned opaque analysis documents with keyset pagination.
- Add `RetentionPeriod` for exact UTC day, Monday-week, and calendar-month retention cohorts.
- Add `UserHost` and `UserHosts` for exact per-host counts over a user's retained history, and allow filtering user event history by host.
- Add analysis problem types, including `409` revision-conflict and limit responses, to the problem catalog and generated OpenAPI.

### Bug Fixes

- Document analysis collection validation problems separately from Relay pagination errors.
- Keep the analysis document capacity independent of the configured ingest body limit.

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
