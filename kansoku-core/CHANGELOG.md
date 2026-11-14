# Changelog

## 0.3.0.0 — 2026-11-14

### Breaking Changes

- Build against kansoku-api 0.3.0.0 and revise administration and runtime interfaces for owner-bound maintenance.
- Separate admission readiness from pipeline health in health probes.

### New Features

- Persist revisioned account-owned analysis documents with atomic shared editing, account quotas, and bidirectional keyset pages.
- Compute exact calendar-period retention with separately scoped start and return activity.
- Filter user event history by host and report exact host counts.
- Start independently of ClickHouse and keep accepting and buffering events through ClickHouse outages and topology mismatches.
- Bind portable drain attestations to maintenance owners and require complete three-store recovery sets before native migration.
- Retain owner-bound repair observations before repair authorization.

### Bug Fixes

- Require fresh owner-bound drain authority for native maintenance and recheck expiry at entry and completion.
- Retain migration entry proofs atomically so audit failure prevents native entry.
- Preserve cancellation during analysis account lock waits and complete analysis schema conformance.
- Keep analysis document capacity independent of the ingest body limit.

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
