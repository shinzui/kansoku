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
---

# Correct client timestamp skew and count ingest rejections

This ExecPlan is a living document. Update its living sections and durable ADRs as work
proceeds. It is a child of
`docs/masterplans/5-act-on-rev-1-close-silent-loss-paths-add-metric-filters-and-enrich-web-analytics.md`
and acts on findings A1, A2 (including its quarantine half, promoted into scope on
2026-10-15) and F1 of
`docs/reviews/2026-10-15-architecture-and-feature-set-against-comparable-products.md`.


## Purpose / Big Picture

A browser whose clock runs a minute fast will no longer lose every event it sends. Kansoku
will correct an event's `occurredAt` from an optional client `sentAt`, clamp a slightly
future timestamp to the server's receive time, and reject only timestamps beyond a documented
tolerance. Operators will see, at `GET /internal/metrics`, how many events were accepted,
how many were rejected and for which reason, and how many timestamps were adjusted, so a
producer that starts violating a declared schema is visible server-side within one scrape.
The `alias` and `group` events that both SDKs already emit will be declared in the event
catalog so their payloads are validated like every other governed event.


## Progress

- [ ] M1: An event with `sentAt` ahead of the server clock is accepted with its `occurredAt` corrected; an event without `sentAt` whose `occurredAt` is within the tolerance is accepted with `occurredAt` clamped to `receivedAt`; one beyond the tolerance is rejected with `validation_failed`. Proven by HTTP integration tests and a stored-row check.
- [ ] M2: `GET /internal/metrics` exports accepted, rejected-by-reason and adjusted-timestamp counters that move under the single, batch and all-invalid-batch paths; the operations guide documents the accepted-versus-written alert.
- [ ] M3: `alias` and `group` appear in `GET /v1/schemas` and `docs/contracts/events.json` as version 1, the golden catalog test passes, and both SDK payload shapes validate unchanged.
- [ ] M4: Rejected declared-event payloads are quarantined in PostgreSQL with their reasons, bounded by a configurable retention, and an operator can list them; the quarantine never receives accepted events or undeclared-event payloads.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Correct and clamp rather than reject. With `sentAt` present and not earlier than
  `occurredAt`, store `receivedAt - (sentAt - occurredAt)`. Without a usable `sentAt`, clamp an
  `occurredAt` that is at most `KANSOKU_INGEST_FUTURE_TOLERANCE_SEC` (default 86400) ahead of
  `receivedAt` to `receivedAt`; reject beyond that. Never move a past timestamp.
  Rationale: Segment, RudderStack and PostHog apply the same correction formula; PostHog and
  Mixpanel substitute server time for the future case; no surveyed product rejects. Rejection
  loses every event of an affected client permanently because SDKs correctly do not retry 400s.
  Date: 2026-10-15
- Decision: Keep the rejection code `validation_failed` for the beyond-tolerance case and make
  the counter label, not a new problem code, the operator-facing signal.
  Rationale: The per-index batch rejection record carries only text, and a new code would
  widen the shared response algebra for one rare case.
  Date: 2026-10-15
- Decision: Quarantine rejected declared-event payloads in PostgreSQL
  (`kansoku.ingest_rejections`), on by default, with `KANSOKU_REJECTION_RETENTION_DAYS`
  (default 14) enforced by the purge command in
  `docs/plans/37-administrative-executable-for-keys-erasure-retention-and-replay.md`.
  Rationale: Decided on 2026-10-15 after discussion: counters say that a producer is broken,
  the quarantine says exactly how, which is what a release diff against the catalog needs.
  PostgreSQL keeps the ingest path's dependency set unchanged (it already talks only to
  PostgreSQL), and a short default retention bounds the privacy exposure. Only declared-event
  rejections are kept: undeclared events are accepted anyway, and structural rejections carry
  no useful payload.
  Date: 2026-10-15


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Kansoku accepts analytics events at `POST /v1/events` (one event) and `POST /v1/batch` (a
JSON array) and validates them before enqueueing to PostgreSQL. The wire record is
`AnalyticsEvent` in `kansoku-api/src/Kansoku/Event/Types.hs`; its JSON options omit absent
fields and ignore unknown ones, so adding an optional field is backward compatible for
producers. Validation lives in `kansoku-api/src/Kansoku/Event/Validation.hs`:
`validateEventWith` returns structural errors, identifier errors and declared-schema errors,
and the `ReceivedBeforeOccurred` constructor is produced whenever `receivedAt < occurredAt`.
The ingest handler in `kansoku-core/src/Kansoku/Ingest/Handler.hs` stamps `receivedAt` with
the server clock and the authenticated account in `stampAuthenticatedEvent` before validation,
then `partitionBatch` splits a batch into accepted events and `RejectedEvent` records. The
browser SDK in `mori://shinzui/kansoku-ts` (`packages/kansoku-js`) reports a timestamp
rejection as a drop and never retries it; the Haskell client in `kansoku-client` does the same.

Prometheus instruments are registered once in `registerPipelineMetrics` in
`kansoku-core/src/Kansoku/Observability.hs` and served at `GET /internal/metrics`. Today there
are seven writer and queue instruments and no ingest instrument. The declared event registry
is `defaultRegistry` in `kansoku-api/src/Kansoku/Event/Registry.hs`; it maps an `EventName` to
a non-empty ascending list of immutable schema versions, and `just contracts` regenerates
`docs/contracts/events.json` from it with a golden test guarding the artifact.

"Clock skew" means the difference between a client's clock and the server's. "Tolerance" is
the largest future offset Kansoku will clamp rather than reject.

PostgreSQL schema is owned by the explicit pg-migrate plan in
`kansoku-core/src/Kansoku/Migrations.hs` (it installs PGMQ and `kansoku.api_keys`); normal
server startup never migrates, so a new table is a new migration step applied with
`cabal run kansoku-migrate -- up`. The ingest path depends only on PostgreSQL, never on
ClickHouse, and this plan keeps that boundary.

Relevant decisions: [ADR 1](../adr/0001-sdk-grade-ingest-contract-boundaries.md) owns the
partial-batch contract and the rule that SDKs never retry rejections; this plan extends it with
the timestamp policy. [ADR 2](../adr/0002-pipeline-observability-readiness-and-writer-recovery.md)
owns the Prometheus instrument set; extend it with the three ingest instruments.
[ADR 7](../adr/0007-versioned-event-schema-governance-and-publication.md) owns catalog
versioning; `alias` and `group` are new version-1 declarations under its rules. No
cross-repository ADR applies.


## Plan of Work

### M1: Skew correction and clamping

Add an optional `sentAt :: !(Maybe UTCTime)` field to `AnalyticsEvent` after `receivedAt`.
Add `ingestFutureToleranceSec` to the configuration record in
`kansoku-core/src/Kansoku/Config.hs`, read from `KANSOKU_INGEST_FUTURE_TOLERANCE_SEC` with
default 86400 and the existing positive-integer parser. Introduce a pure function
`normalizeOccurredAt :: NominalDiffTime -> UTCTime -> AnalyticsEvent -> (AnalyticsEvent, Maybe TimestampAdjustment)`
in a new module `kansoku-core/src/Kansoku/Ingest/Timestamp.hs`, where the tolerance and the
server receive time are inputs and `TimestampAdjustment` is `SkewCorrected | Clamped`. Call it
from `stampAuthenticatedEvent`'s caller so the adjusted event is what validation sees; the
`ReceivedBeforeOccurred` check then only fires for the beyond-tolerance case. Keep `sentAt`
out of ClickHouse; it is an ingest-time input, not a stored fact.

Regenerate the OpenAPI artifact with `just openapi` and describe `sentAt` and the policy in the
`AnalyticsEvent` schema description. Update `docs/guides/send-events.md` with a short "Clock
skew" paragraph that shows the formula and the tolerance.

Acceptance: the integration tests in M1 of Validation and Acceptance pass, and a corrected
event's stored `occurred_at` equals the formula's result to the millisecond.

### M2: Ingest outcome counters

Add three instruments to `PipelineMetrics` and `registerPipelineMetrics`:
`kansoku_ingest_events_total` as a vector counter with label `outcome` in `{accepted, rejected}`,
`kansoku_ingest_rejections_total` with label `reason` whose values are the snake-case
constructor names of `ValidationError` (for example `received_before_occurred`,
`missing_required_property`), and `kansoku_ingest_timestamp_adjustments_total` with label
`adjustment` in `{skew_corrected, clamped}`. Thread the metrics handle into the ingest handler
the same way the writer receives it, and increment in `partitionBatch`'s caller and the
single-event path. A rejected event with several errors increments the reason counter once per
distinct reason. Document the three instruments in `docs/guides/operations.md` under
"Prometheus metrics" and add the alert sentence: a sustained gap between
`rate(kansoku_ingest_events_total{outcome="accepted"})` and
`rate(kansoku_writer_events_written_total)` indicates queue growth or writer failure.

Acceptance: `ObservabilitySpec` and an HTTP test observe the counters moving for one accepted
single event, one batch with two rejections of different reasons, and one all-invalid batch.

### M3: Declare `alias` and `group`

Add `alias` version 1 with required string properties `previousId` and `newId`, and `group`
version 1 with no declared properties, to `defaultRegistry`, each with a changelog note. Both
SDKs already send exactly these shapes: `kansoku-client/src/Kansoku/Client.hs` builds `alias`
with `previousId` and `newId` pairs and `group` with the organisation in the top-level
`organizationId`; the browser SDK does the same in `packages/kansoku-js/src/identity-api.ts`.
Run `just contracts` and `just openapi`, then `just contracts-check`. Add a validation test
that an `alias` without `newId` is rejected and the SDK-shaped payloads pass.

### M4: Quarantine of rejected declared-event payloads

Add a pg-migrate step creating `kansoku.ingest_rejections` with columns `id uuid`,
`account_id text`, `received_at timestamptz`, `event_name text`, `schema_version integer`,
`reasons text[]`, `payload jsonb`, `route text`, indexed on `(account_id, received_at)`. In the
ingest handler, after `partitionBatch`, insert one row per rejected event whose event name is
declared in the registry (the `MissingRequiredProperty`, `WrongPropertyType`,
`InvalidPropertyValue` and `UnknownSchemaVersion` families), storing the payload as received
and the credential's account, through the existing PostgreSQL pool in one statement per
batch. The insert must never fail the request: on a store error, log at warning level and
count `kansoku_ingest_quarantine_failures_total`. Read `KANSOKU_INGEST_QUARANTINE` (default
`true`) to disable the feature and `KANSOKU_REJECTION_RETENTION_DAYS` (default 14) as the
documented retention that the admin purge command enforces. Document the table, the two
variables and the privacy note in `docs/guides/operations.md` ("Rejected events").


## Concrete Steps

Run everything inside `nix develop` at the repository root with the local stack up
(`process-compose up --tui=false --port 18080`, then `just migrate` and `just ch-migrate`).

```bash
cabal build all --enable-tests
cabal run kansoku-migrate -- up
cabal test kansoku-core --test-options='--match "Ingest"'
just openapi && just contracts && just openapi-check && just contracts-check
```

A manual check of M1 after `just run` with a write key in `KEY`:

```bash
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
AHEAD=$(date -u -v+90S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+90 seconds' +%Y-%m-%dT%H:%M:%SZ)
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/v1/events \
  -H "X-Api-Key: $KEY" -H 'Content-Type: application/json' \
  -d "{\"eventId\":\"skew-1\",\"eventName\":\"cta_clicked\",\"source\":\"web\",\"occurredAt\":\"$AHEAD\",\"sentAt\":\"$AHEAD\",\"receivedAt\":\"$NOW\",\"properties\":{},\"context\":{}}"
```

Expected output is `202`, and after one writer flush:

```sql
SELECT event_id, occurred_at <= received_at FROM analytics.events_raw WHERE event_id = 'skew-1'
```

returns `1` in the second column. Then `curl -s http://localhost:8080/internal/metrics | grep kansoku_ingest`
shows `kansoku_ingest_events_total{outcome="accepted"} 1` and
`kansoku_ingest_timestamp_adjustments_total{adjustment="skew_corrected"} 1`.


## Validation and Acceptance

Required acceptance, all as Hspec cases under `kansoku-core/test/Kansoku/Ingest/` and the
HTTP integration spec:

1. `sentAt` and `occurredAt` both 90 seconds ahead of the server clock: HTTP 202, stored
   `occurred_at` equals `receivedAt` minus zero seconds offset (the formula with
   `sentAt == occurredAt` yields `receivedAt`), adjustment counter `skew_corrected` increments.
2. `sentAt` 90 seconds ahead and `occurredAt` 100 seconds ahead: stored `occurred_at` equals
   `receivedAt` minus 10 seconds.
3. No `sentAt`, `occurredAt` 60 seconds ahead: HTTP 202, stored `occurred_at` equals
   `receivedAt`, counter `clamped` increments.
4. No `sentAt`, `occurredAt` two days ahead with the default tolerance: single route returns
   HTTP 400 `validation_failed`; in a batch the event appears in `rejected` and
   `kansoku_ingest_rejections_total{reason="received_before_occurred"}` increments.
5. `sentAt` earlier than `occurredAt`: `sentAt` is ignored and rule 3 or 4 applies.
6. A past `occurredAt` is never changed.
7. An all-invalid batch returns 202 with `accepted: 0`, and the accepted counter does not move.
8. The registry invariant tests and the golden catalog test pass with the two new events.
9. M4: a `page_view` missing `url` lands in `kansoku.ingest_rejections` with
   `reasons = {missing_required_property}` and the original payload; an undeclared event with
   a bad schema version and a structurally empty event id do not; with
   `KANSOKU_INGEST_QUARANTINE=false` nothing is stored and the request still returns 202.
10. M4: a PostgreSQL failure injected into the quarantine insert leaves the batch response
    unchanged and increments the failure counter.

Proposed, not required: an ingestion-warning log line per clamped event is not added; the
counter is the signal.


## Idempotence and Recovery

Every step is additive. The configuration variable has a default, so existing deployments
change behaviour only for events that were previously rejected. If the policy must be reverted,
set the tolerance to `0` to restore strict rejection without a code change; `sentAt` correction
cannot be disabled and never moves a timestamp into the future. Registry additions are new
version-1 entries and are not removable under ADR 7; if `alias` or `group` must change, add
version 2. The quarantine can be switched off by configuration and its table dropped by a
down migration without affecting ingest.


## Interfaces and Dependencies

No hard dependency on other children of the MasterPlan. `Kansoku.Ingest.Timestamp` is a new
pure module; `PipelineMetrics` in `kansoku-core/src/Kansoku/Observability.hs` gains three
fields that `docs/plans/30-pipeline-backpressure-and-storage-outage-resilience.md` also
extends, so land this plan's instruments first or merge the record edits deliberately. The
`sentAt` wire field is claimed here; the browser SDK should start sending it in a follow-up in
`mori://shinzui/kansoku-ts`, which this plan does not require. Claims the
`kansoku.ingest_rejections` table and the `KANSOKU_INGEST_QUARANTINE` and
`KANSOKU_REJECTION_RETENTION_DAYS` variables; the purge and listing commands are owned by
`docs/plans/37-administrative-executable-for-keys-erasure-retention-and-replay.md`, and the
`transport` counter label is extended by
`docs/plans/39-beacon-ingest-route-for-page-exit-delivery.md`. Libraries: `prometheus-client`
(already a dependency) for labelled vectors, `hasql` through the existing pool; no new
dependency.
