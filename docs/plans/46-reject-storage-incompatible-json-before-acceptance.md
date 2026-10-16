---
id: 46
slug: reject-storage-incompatible-json-before-acceptance
title: "Reject storage-incompatible JSON before acceptance"
kind: exec-plan
created_at: 2026-10-16T17:20:48Z
intention: "intention_01m52vndmcenmvqq6w1yphfykk"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-10-16T17:20:48Z
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-16T17:46:01Z
      mode: "update"
      note: "Scope to first deployment: remove historical queue, compatibility and upgrade recovery requirements"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-16T17:49:41Z
      mode: "implement"
      note: "Implement and validate pre-acceptance native JSON path compatibility"
---

# Reject storage-incompatible JSON before acceptance

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current. Promote durable implementation decisions into the relevant ADRs before completion.

## Purpose / Big Picture


Close F1 in [REV-2](../reviews/2026-10-16-initial-release-implementation-correctness.md#f1-accepted-json-can-park-the-writer-for-every-account). A producer can currently submit valid JSON whose paths collide in ClickHouse's typed JSON representation, receive an acceptance response, and stop the shared writer indefinitely. After this change, new incompatible events receive permanent validation errors before acceptance. The service has never been deployed or used. This is its first release: there are no historical accepted events, deployed writers or old queue contents to migrate. Prevent incompatible input from entering the queue, and prove valid events from every account continue processing.

This plan has three implementation milestones. It does not change database-error logging policy. [EP-48](48-clean-acceptance-fixtures-across-telemetry-modes.md) must pass before a complete packaged acceptance result can close this plan; implementation of the writer repair does not depend on EP-48.

## Progress


- [x] M1: (2026-10-16; deterministic core 406 examples, client 21 examples, probe kit 4 tests; native corpus 42 examples, all passing.) Shared storage-shape validation rejects incompatible properties/context before a new acceptance claim, with native compatibility and transport regressions passing.
- [x] M2: (2026-10-16; `just json-storage-acceptance`, 42 native examples, 48 public permanent rejections and 154 canonical events; private evidence `.dev/acceptance/cohort-jqnf4tnc/`) Fresh-stack HTTP/native regressions prove incompatible input never enters the queue, compatible payloads survive storage, and valid events across accounts continue processing.
- [ ] M3: Packaged regression and existing recovery checks pass, and the first-release ingest contract documents supported JSON shapes and permanent rejections.

## Surprises & Discoveries


2026-10-16: Owned ClickHouse 26.8.2 probes established that exact non-null flattened leaf paths collide (code 117), but scalar/object prefixes coexist. Nulls and empty objects occupy no path; empty arrays do occupy paths. Objects inside nested or mixed arrays are validated independently for each element. The 21-case checked-in corpus preserves these distinctions for both materialized columns. Private probe evidence is under `.dev/acceptance/json-probe/`.

2026-10-16: The documentation log tool rewrites away the guide bundle's historical adoption evidence table. Restored that table after invoking the required log command and retained the new update entry.

## Decision Log


2026-10-16 (revised after deployment clarification): Reject structurally incompatible input before acceptance using local pure validation. Ingestion must not acquire a live ClickHouse dependency. The service has never been deployed or used, so historical-message isolation, old envelope compatibility, upgrade recovery and rollback procedures are outside this fix.

2026-10-16: Implement the acceptance-only fixture cleanup prerequisite in [EP-48](48-clean-acceptance-fixtures-across-telemetry-modes.md) as part of reaching this plan's required final packaged gate. Production pagination and writer recovery remain unchanged.

2026-10-16: Diagnostics return at most one fixed storage-shape error per affected field, with no producer paths or values. Traversal retains flattened paths internally; source locations are unnecessary in the public error and would expand diagnostic payloads. Exact path occupancy, rather than prefix collisions, follows native corpus evidence.

2026-10-16: Keep the existing storage-outage recovery behavior. Prevent the demonstrated deterministic insert failure at ingestion rather than adding a new dead-letter or archive recovery workflow. Native insert tests must establish that the admitted shapes are compatible with the actual materialized columns.

Revision note: Removed the assumed installed base and replaced the historical-queue milestone with fresh-stack transport and storage verification. The first-release scope remains unchanged.

## Outcomes & Retrospective


(To be filled during implementation.)

## Context and Orientation


`kansoku-api/src/Kansoku/Event/Validation.hs` owns pure event validation, rendering and fixed rejection reason codes. `kansoku-core/src/Kansoku/Ingest/Acceptance.hs` commits a new account/event-ID claim and queue publication together. An equal retry of an existing claim returns its original acceptance without publishing again; preserve this behavior. `kansoku-core/src/Kansoku/Ingest/Service.hs` applies the shared ingestion path to transports. `kansoku-core/src/Kansoku/Ingest/QueuedEvent.hs` constructs the current private queue envelope. Exercise the envelope emitted by this release; older formats are not an acceptance requirement for this repair.

`db/clickhouse/migrations/0009_typed_properties.sql` materializes native JSON from raw properties; `db/clickhouse/migrations/0019_web_enrichment.sql` also casts context. The object `{"a.b":1,"a":{"b":2}}` has distinct JSON keys but duplicate flattened native path `a.b`. The reviewed ClickHouse returned code 117 on insert. The original JSON remains meaningful even when this secondary representation cannot store it.

`kansoku-core/src/Kansoku/Writer/Batch.hs` passes decoded batches to insertion. `kansoku-core/src/Kansoku/Writer/Run.hs` wraps insertion in `recoverInsert`; `kansoku-core/src/Kansoku/Writer/Recovery.hs` parks database errors and retries the retained batch. That behavior protects accepted data during outages but cannot make an incompatible object insertable. Validation before queue publication removes the demonstrated producer-triggered failure without changing the recovery loop.

[ADR-1](../adr/0001-sdk-grade-ingest-contract-boundaries.md) requires partial batch acceptance and immutable claims. [ADR-2](../adr/0002-pipeline-observability-readiness-and-writer-recovery.md) requires storage recovery without silent loss. [ADR-4](../adr/0004-queryable-event-properties-and-identity-resolved-projection.md) preserves raw JSON and typed query semantics. [ADR-10](../adr/0010-owned-executable-acceptance-environments.md) requires disposable owned database processes for destructive native checks. These constraints remain in force.

## Plan of Work


### M1 — Reject incompatible new objects before acceptance


Add a storage-shape validator in `kansoku-api/src/Kansoku/Event/Validation.hs` or a small sibling module exported through `kansoku-api/src/Kansoku/Event.hs`. Call it from `validateEventWith`, returning structural errors for both properties and context alongside the existing event validation errors. Add a finite error constructor, rendering and telemetry reason such as `incompatible_json_paths`; bound error output and avoid copying whole payloads into diagnostics.

Before broadening the algorithm, establish native parity for the duplicate-path example in both materialized columns. Traverse nested objects and object values inside arrays, retaining source locations and the native flattened path each value occupies. Detect ambiguity within the appropriate native object/array scope rather than treating all repeated field names across array elements as duplicates. Build a compact native corpus covering scalar/object prefix collisions, empty objects and keys, nested arrays, dotted keys with and without collision, null and mixed-type values. The acceptance criterion for the implementation is that every corpus input admitted by the validator inserts successfully and compatible controls retain their values. Keep ordinary noncolliding dotted keys supported. If the native corpus disproves the proposed path model, revise it before integrating; do not ship a speculative blacklist or a rule banning all nested data.

Run this validation as part of the existing normalization/validation callback before a new ledger claim. Extend `kansoku-core/test/Kansoku/EventSpec.hs`, `kansoku-core/test/Kansoku/Ingest/AcceptanceSpec.hs`, `kansoku-core/test/Kansoku/Ingest/HandlerSpec.hs` and `kansoku-core/test/Kansoku/Ingest/BeaconSpec.hs` at their existing boundaries. M1 passes when an invalid new event leaves no acceptance row or queued message, a mixed batch accepts its valid sibling with an indexed rejection, single ingestion returns its normal permanent 400, and beacon delivery follows its existing permanent rejection contract. A corrected event with the previously rejected new ID can then be accepted. An already-claimed equal retry retains the existing idempotency result and does not republish.

### M2 — Verify ingestion through native storage on fresh stores


Add `scripts/json_storage_acceptance.py`, reusing the owned-stack lifecycle from `scripts/cohorts_acceptance.py` where appropriate, with a callable HTTP verifier. Add `json-storage-acceptance` to `justfile` and invoke the verifier from `scripts/acceptance.py` against the packaged executable. Use newly initialized PostgreSQL and ClickHouse stores with all migrations applied. Add the native shape corpus to `kansoku-core/test/Kansoku/Writer/BatchSpec.hs` or a dedicated native test module and wire it into the owned required harness. Missing prerequisites must fail the run.

Submit the collision object through single, batch and beacon ingestion, using the actual response semantics of each transport. A mixed batch must reject the incompatible index and write its valid sibling. Repeat for context and nested object/array cases. Verify rejected IDs have neither ledger claims nor queue messages, then submit corrected content under those IDs and prove it is accepted and written. Test retries of valid accepted events to preserve idempotency and canonical counts. Inspect compatible dotted-key controls through native storage so a successful HTTP response alone is insufficient evidence.

After each incompatible submission, send a valid event for a second account and query until it appears within a bounded timeout. The writer must not enter a persistent parked state. Use the current envelope emitted by ingestion. There is no historical payload seeding, old-version replay or deployment-upgrade scenario. M2 is complete when the public/native regression proves the invalid payload never reaches insertion and the valid workload continues. Keep all new fixtures isolated from existing saved definitions and pagination scenarios.

### M3 — Verify the packaged candidate and document the contract


Run the deterministic and packaged gates, including existing writer recovery tests and the focused outage smoke proof. These checks must preserve outage retry, cancellation and lost-confirmation behavior; there is no planned change to acknowledgement or recovery semantics. If implementation nevertheless changes writer recovery, record why and run the full existing outage proof before completion.

Update `docs/guides/send-events.md` to describe supported JSON shapes, permanent single-event errors, indexed batch rejections and correction of an event that was rejected before acceptance. Update ADR-1 and ADR-4 to document the supported input/native representation boundary. Maintain changed documentation bundle timestamps/logs and validate their profiles. No migration, compatibility adapter or historical-data recovery runbook is required for an undeployed service.

## Concrete Steps


Run from the repository root. Start with the deterministic gate after adding regressions; use the new focused target once M3 supplies it. Never point native fixtures at ambient databases.

```bash
nix develop -c just check
nix develop -c just json-storage-acceptance
nix develop -c python3 scripts/outage-acceptance.py --smoke
```

After EP-48 is complete, run the final candidate gates. If recovery or acknowledgement behavior changes during implementation, additionally run `nix develop -c just outage-acceptance`, the existing ten-minute proof.

```bash
nix develop -c just acceptance
nix develop -c just guides-check
nix develop -c just adr-check
nix develop -c just reviews-check
git diff --check
```

All commands must exit zero with nonzero executed regression examples and no pending integration prerequisites. Preserve private evidence under the existing `.dev/acceptance/` convention and record concise results here. Do not mark F1 resolved merely because pure tests pass.

## Validation and Acceptance


The critical HTTP batch contains the collision object and an ordinary valid event. It returns 202 with accepted count one and exactly the invalid index rejected. Test the same object in context and at nested object/array locations, and controls with compatible dotted keys and repeated object shapes in different array elements. Query the valid event and a later second-account event until they appear within the existing bounded acceptance timeout. Verify the invalid new ID has no claim, then accept corrected content under that ID.

Valid accepted retries must not enqueue another copy. Existing checks for database unavailability, missing schema, cancellation, lease-renewal failures and lost insert confirmation must remain passing. No unknown database error may silently delete accepted input. Record unresolved native shape cases as blockers rather than claiming general compatibility from one example. All acceptance evidence comes from a fresh installation of this first-release candidate.

## Idempotence and Recovery


Use fresh owned database directories for integration runs; retain their private evidence and stop only owned processes. Rejected new input has no immutable claim, so corrected content may reuse its event ID. Successfully accepted events retain the existing equal-retry and conflicting-content rules. Failed disposable runs can be repeated from clean stores. There is no deployed state to migrate or restore, and no historical queue repair to implement.

## Interfaces and Dependencies


The shared API is a pure storage-shape check used by event validation before acceptance. New rejections use the existing response/error algebra and fixed telemetry reasons. The current queue envelope and native insert path are exercised end to end; this work adds no old-format compatibility requirements. No new library or dependency bound is required. EP-48 removes the unrelated full-suite fixture failure; EP-47 can be implemented independently.
