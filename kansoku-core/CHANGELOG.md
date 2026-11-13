# Changelog

## 0.2.0.0 — 2026-11-12

### Breaking Changes

- Revise runtime interfaces and record construction conventions.
- Migrate raw event storage to schema v2 and bounded aggregate states.
- Replace legacy monitoring endpoints with shared health probes.
- Adopt typed API responses and partial batch acceptance.

### New Features

- Add immutable ingestion acceptance, replay-safe analytics, enrichment, rate limiting, and bounded outage recovery.
- Add conservative identity resolution, governed traits, organizations, cohorts, identified user profiles, and event history.
- Extend metrics with bounded filters, funnels, paths, custom definitions, exact aggregation, acquisition, sessions, experiments, and resolved user selection.
- Support native TLS, configured replica consistency, quorum writes, and fenced maintenance.
- Add resumable administrative erasure, retention, replay, tracing, pipeline metrics, and readiness checks.

### Bug Fixes

- Preserve typed query failures, native ordering, and storage-compatible JSON.
- Exclude diagnostic events from session engagement while preserving observed duration.
- Recover writer connections and drain supervised workers during shutdown.
