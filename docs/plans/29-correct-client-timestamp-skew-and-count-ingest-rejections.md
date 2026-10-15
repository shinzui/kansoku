---
id: 29
slug: correct-client-timestamp-skew-and-count-ingest-rejections
title: "Correct client timestamp skew and count ingest rejections"
kind: exec-plan
created_at: 2026-10-15T13:44:34Z
intention: "intention_01m4zwwdrjesytazp5tb39fe3n"
master_plan: "docs/masterplans/5-act-on-rev-1-close-silent-loss-paths-add-metric-filters-and-enrich-web-analytics.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-15T13:44:34Z
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-15T14:24:22Z
      mode: "update"
      note: "Promote beacon route (EP-39), rejection quarantine (EP-29 M4, EP-37 M5) and person properties (EP-40) into scope after owner discussion."
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-15T15:43:15Z
      mode: "update"
      note: "Reconcile first-release APIs, domain semantics, dependencies and acceptance with the source-validated MP-5 review."
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-15T15:43:15Z
      verdict: "changes-requested"
      note: "Original draft review found correctness gaps; findings corrected by the accompanying update, with native acceptance still required."
---

# Correct client timestamp skew and count ingest rejections


## Purpose / Big Picture


Accept ordinary future-clock skew without losing valid events, expose durable ingest outcomes,
and retain bounded diagnostic samples of declared-schema rejections. This plan owns the
normalization and validation path shared by single, batch and beacon delivery.

## Progress


- [ ] M1: Timestamp normalization and supported storage range pass pure and native HTTP tests.
- [ ] M2: Durable acceptance and rejection counters cover single, batch and all-invalid paths.
- [ ] M3: Alias, group and page-leave schemas validate real SDK payloads.
- [ ] M4: Quarantine records useful rejected payloads and automatically expires/caps them.

## Surprises & Discoveries


The original timestamp test used `sentAt < occurredAt` but expected subtraction in the opposite
direction. `Config.hs`'s positive parser also cannot accept the documented disable value zero.
The handler currently loses original rejected payloads when `partitionBatch` returns only
`RejectedEvent`; preserve a private rejection record rather than reconstructing payloads.

## Decision Log


On 2026-10-15 retain the specified future-only correction policy: never change a past event.
A usable send timestamp corrects a future event; otherwise the configured tolerance clamps it.
Quarantine is bounded automatically, not merely by an optional manual purge invocation.

## Outcomes & Retrospective


Planning review complete; implementation and native evidence remain outstanding.

## Context and Orientation


`kansoku-api/src/Kansoku/Event/Types.hs` defines `AnalyticsEvent`;
`Event/Validation.hs` rejects `ReceivedBeforeOccurred`. The server overwrites account and receive
time in `kansoku-core/src/Kansoku/Ingest/Handler.hs`. `Ingest/Producer.hs` enqueues to PostgreSQL.
`Observability.hs`, `Config.hs` and `Migrations.hs` own instruments, settings and explicit
PostgreSQL migrations. `kansoku-api/src/Kansoku/Event/Registry.hs` owns immutable schema versions.
Read [ADR-1](../adr/0001-sdk-grade-ingest-contract-boundaries.md),
[ADR-2](../adr/0002-pipeline-observability-readiness-and-writer-recovery.md) and
[ADR-7](../adr/0007-versioned-event-schema-governance-and-publication.md).

## Plan of Work


### M1: Timestamp policy


Add optional `sentAt :: Maybe UTCTime` to the wire type. In new
`kansoku-core/src/Kansoku/Ingest/Timestamp.hs`, define
`normalizeOccurredAt :: NominalDiffTime -> UTCTime -> AnalyticsEvent -> (AnalyticsEvent, Maybe TimestampAdjustment)`.
If `occurredAt <= receivedAt`, preserve it. Otherwise, when `sentAt >= occurredAt`, use
`receivedAt - (sentAt - occurredAt)` and label `skew_corrected`. With no usable `sentAt`, clamp
future offsets at most `KANSOKU_INGEST_FUTURE_TOLERANCE_SEC` (default 86400), label `clamped`,
and reject greater offsets. Parse tolerance as a nonnegative integer; zero disables clamping.
Validate the resulting time against the actual supported DateTime64/partition range before
queueing; choose and publish a conservative UTC range supported by the packaged ClickHouse
and native driver, with boundary roundtrips. Extreme timestamps must not poison the writer.
Retain `sentAt` only as an ingest input. Normalize once before validation/enqueue; EP-30 will
keep the first durable normalization on retries. Keep `receivedAt` server-authoritative.

### M2: Outcomes


Thread `PipelineMetrics` into the shared ingest service. Define
`kansoku_ingest_events_total{outcome,transport}`, where outcome is accepted/rejected and
transport is single/batch/beacon; `kansoku_ingest_rejections_total{reason,transport}` with fixed
constructor-derived reason labels; and `kansoku_ingest_timestamp_adjustments_total{adjustment,transport}`.
Increment accepted for newly enqueued logical events only after the queue transaction commits,
rejected once per event, and
reason once per distinct reason per event. Do not count enqueue failure as acceptance.
Never use payload values, account IDs or credential IDs as labels. EP-30 adds a duplicate
counter so operators compare newly enqueued events with writer completions without assuming
exact equality between retry-inflated counters. Document queue depth/age as the backlog signal.

### M3: Govern SDK events


Declare `alias` v1 with required nonempty strings `previousId`, `newId`; validate agreement
with top-level `anonymousId` and `userId`. Its meaning is anonymous-cookie-to-user binding,
not arbitrary user-to-user graph merging. Declare `group` v1, requiring top-level
`organizationId`; it stamps organization context and does not implement organization analytics.
Declare `page_leave` v1 with required nonnegative numeric `durationMs`; top-level URL identifies
the page. It is a lifecycle event, not an engagement event for bounce calculation.
Use the existing Haskell helpers and the SDK payloads at
`mori://shinzui/kansoku-ts/packages/kansoku-js` as fixtures. Regenerate catalog and OpenAPI;
fix helpers that allow custom properties to overwrite reserved alias IDs.

### M4: Bounded quarantine


Create `kansoku.ingest_rejections` through an explicit migration with id, authenticated account,
receive time, event name, nullable schema version, fixed reason codes, event payload and route,
indexed by `(account_id, received_at, id)`. Preserve the original event object separately from
normalization. Store only declared-schema errors, not arbitrary malformed request bodies;
never store the beacon envelope or its write key. Cover the single-event path as well as batches.
Use a separate bounded best-effort database operation with timeout; quarantine failure must not
roll back accepted queue writes or swallow asynchronous cancellation. Count failures without
logging payloads. `KANSOKU_INGEST_QUARANTINE=true` enables it; retention defaults to 14 days.
A supervised hourly cleanup also applies a configurable per-account row cap (default 10000)
and payload cap (default 16 KiB, storing truncation metadata when exceeded). Measure cleanup
lag and failed writes. EP-37 supplies manual listing and purge. Document that expiry is eventual
within the cleanup interval, including restart catch-up; it is not a hard deletion deadline.

## Validation and Acceptance


Future tests use receive time T: occurred/send both T+90 yields T; occurred T+90, send T+100
yields T-10; send earlier than occurred falls back to tolerance. A past event remains unchanged.
Test tolerance zero and extreme normalized dates. Verify stored milliseconds, not just 202.
Queue failure returns 503 and leaves accepted unchanged; all-invalid batch returns 202 with
accepted zero. Quarantine tests cover single/batch/beacon, store failure, disabled mode, caps,
automatic expiry and absence of keys in database payloads/logs. Both SDK alias/group fixtures
and page-leave payloads pass the generated catalog. Empty alias IDs and inconsistent top-level
bindings fail validation before producing identity evidence.

## Concrete Steps


Run commands from the repository root inside `nix develop`. Use the private databases owned
by `scripts/acceptance.sh` and `Kansoku.ClickHouseTestSupport`, not an ambient development
stack: native fixtures mutate tables. Extend that harness for the scenarios in this plan.

```bash
cabal build all --enable-tests
just openapi
just contracts
just check
just acceptance
```

Use focused Hspec examples while developing. Before marking Complete, require nonzero example
counts, no pending required integration tests, regenerated contract checks, and the packaged
executable acceptance above. Record only the relevant evidence here. This follows
[ADR-10](../adr/0010-owned-executable-acceptance-environments.md).

## Idempotence and Recovery


Quarantine can be disabled without affecting ingestion. Do not remove published schema versions. Migrations are explicit; no normal-startup DDL. This is pre-deployment, so test fresh installation and migration-ledger repeatability rather than inventing a compatibility release.

## Interfaces and Dependencies


No hard child dependency. EP-30 consumes this shared ingest path; EP-39 consumes its transport labels. EP-37 consumes M4. Browser producer work is `mori://shinzui/kansoku-ts/plans/8-serve-kansoku-masterplan-5-sentat-beacon-exit-flush-bot-flag-and-identifyonce`.

Revision note (2026-10-15): reviewed against the current source and revised for first deployment.
[ADR-11](../adr/0011-initial-release-analytics-contracts.md) records the proposed cross-plan
contracts; implementation must supply the acceptance evidence before those contracts become
accepted runtime guarantees.
