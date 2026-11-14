---
type: Improvement Request
title: Operate Kansoku's ClickHouse schema and maintenance on a shared server
description: Let Kansoku's ClickHouse maintenance ceremony, admin jobs and restore verification work on a ClickHouse server shared with other apps, using tenant-scoped quiesce evidence and on-demand app-database backups instead of server restarts, without reading other users' queries.
generated:
  by: process:claude-code
  at: "2026-10-19T17:02:45Z"
requestId: IR-2
status: completed
completedAt: "2026-11-14T02:27:02Z"
resolution: >-
  AC-1 through AC-5 delivered by MasterPlan 7 and ExecPlans 50–53. Owner-bound
  external drain, complete three-store recovery sets, explicit rebuilt-server
  re-binding and bounded SELECT-only renamed restore inspection pass dedicated,
  both generic shared-server and actual reviewed local Nagare acceptance. The
  Nagare proof retains signed artifact IDs, 274 fresh other-app samples, unchanged
  process identity and a no-operations grant re-plan. Final check, full packaged
  acceptance, four SDK component cases, ten-package source/embedding reconstruction
  and 108 upstream source/Nix native groups pass. Evidence is in
  docs/evidence/shared-clickhouse-maintenance.md; no production deployment or
  independent verification attestation is claimed.
targetPlan: docs/masterplans/7-operate-kansoku-clickhouse-safely-across-deployment-platforms.md
origin: mori://tan/tan-ng-labs/plans/2-deploy-kansoku-to-the-intranet-as-a-shared-analytics-service-for-nagare-apps
dependencies:
  - ref: mori://shinzui/nagare/okf/improvement-requests/concepts/IR-30
    kind: integration
    reason: Nagare-only joint verification of reviewed metadata and temporary-table grants; the actual local ceremony passes. Generic deployments independently supply equivalent roles.
  - ref: mori://shinzui/nagare/okf/improvement-requests/concepts/IR-31
    kind: integration
    reason: Nagare-only joint verification of runtime-only quiesce and signed backup/restore receipts; the actual local ceremony passes. Portable core maintenance has no Nagare dependency.
acceptanceCriteria:
  - id: AC-1
    statement: A maintenance session can accept drain evidence produced by quiescing Kansoku's own app databases, without restarting the ClickHouse server, while the migration user stays available to kansoku-ch-migrate.
    verification: On a server shared with a second app, open a session, quiesce Kansoku's runtime, record the evidence, run up and finish, and assert the second app's queries ran throughout and the server start time is unchanged.
  - id: AC-2
    statement: No Kansoku or clickhouse-migrate code path depends on seeing other users' queries in system.processes.
    verification: Run kansoku-admin retention and erasure and kansoku-ch-migrate repair with system.processes either unreadable or limited to Kansoku's own users, and assert they succeed or refuse with an explanatory message, never silently pass a drain check.
  - id: AC-3
    statement: The pre-migration consistent backup is taken with on-demand app-database backups of the PostgreSQL coordinator and both ClickHouse databases under the maintenance fence, and the guide says how to prove they form one recovery point.
    verification: Follow the guide on a shared server and assert both receipts were taken after the fence and before the first migration step.
  - id: AC-4
    statement: A restored copy whose databases carry different names (for example analytics_restore_ID) can be verified read-only against the ledger and expected schema without a separate server.
    verification: Restore a backup into scratch databases beside the live ones and run the verification; assert it reports matching schema and ledger and writes nothing.
  - id: AC-5
    statement: The ClickHouse guide lists the exact privileges each Kansoku user needs on a shared server, and a documented procedure re-binds the retained server identity after a rebuilt-server restore changes serverUUID.
    verification: Compare the guide's list with a run under only those privileges; follow the re-bind procedure on a rebuilt test server.
reviews:
  - kind: model
    reviewer: process:claude-code
    reviewed_at: "2026-10-19T17:02:45Z"
    document_timestamp: "2026-10-19T17:02:45Z"
    scope: content-and-metadata
    outcome: commented
    provider: anthropic
    model: claude-opus-5-5
    effort: unspecified
    context: >-
      Author review against Kansoku 9127c47, clickhouse-migrate v0.1.0.0, Nagare v0.7.0 app
      databases and live denials on the tan-ng-labs intranet; no independent verification
      attestation is claimed.
---

# Operate Kansoku's ClickHouse schema and maintenance on a shared server

**Authored by:** a `claude-code` session implementing
`mori://tan/tan-ng-labs/plans/2-deploy-kansoku-to-the-intranet-as-a-shared-analytics-service-for-nagare-apps`
on the `tan-ng-labs` intranet, running Nagare v0.7.0.
**Addressed to:** `shinzui/kansoku` agents.
**Created:** 2026-10-19.

**Implementation plan:** [MasterPlan 7: Operate Kansoku ClickHouse safely across deployment platforms](../masterplans/7-operate-kansoku-clickhouse-safely-across-deployment-platforms.md), through ExecPlans 50 to 53. Completed by ExecPlans 50–53 on 2026-11-14 UTC; see `resolution` and the evidence below.

This is part of the set filed with IR-1; that request lists the others.


## Resolution evidence

[The complete qualification record](../evidence/shared-clickhouse-maintenance.md)
identifies the exact source candidates, backend OCI artifact, signed backup Job
IDs and retained private artifacts. Verification is implementation-authored.

| Criterion | Accepted observation |
|---|---|
| AC-1 | Both generic shared cases and one complete actual local Nagare ceremony preserve the other app's long/fresh queries and the shared server's process; runtime-only quiesce leaves the migrator available. |
| AC-2 | Denied and operator-enforced own-user views pass; hidden earlier migration work and missing drain refuse before entry; receipt-bound repair, retention and erasure complete under fresh external evidence. |
| AC-3 | A PostgreSQL-only set refuses pending native SQL; actual signed PostgreSQL and two-database ClickHouse backups restore the common queue/coordinator/data state and all 581 original native ledger rows. |
| AC-4 | The separately declared bounded SELECT-only scratch reader verifies schema/history, attempts no writes and rejects an extra column while history remains current. |
| AC-5 | The guide publishes exact generic/platform role inventories; generic clean and interrupted rebuilt restores exercise audited identity re-bind, lost replies and idempotent recovery. |

The actual Nagare candidate is source `8cc5a7792710083092c60c2dc71777186b61a360`
of `mori://shinzui/nagare`; published v0.20.0 alone lacks the reader extensions.
The whole four-package toolkit cohort is source
`a0bf98efbffbae9def846454deef9164ecadbd9d` of `mori://shinzui/clickhouse-migrate`.
Nagare's original requests are integration prerequisites for this deployment,
not hard prerequisites for portable core maintenance. Linux application images,
stock platform bootstrap, managed cloud and production rollout remain separate.


## Why

On the labs intranet, Kansoku's `analytics` and `kansoku_migration_ledger` live on
`labs-clickhouse` (26.8.28.14). That server is shared with other apps through Nagare app
databases. Each app gets a runtime and a migration user with grants only on its own databases.
Kansoku's DDL fits the migration grant set. Its operating procedures assume it owns the server.

- **Drain by restart.** The ceremony (`mori://shinzui/kansoku/okf/guides/concepts/DOC-13`,
  ADR-0022) proves drain by stopping clients and restarting the ClickHouse server. On a shared
  server that interrupts every other app. Nagare IR-31 asks for a tenant-scoped quiesce that
  gives the same guarantee for Kansoku's users only.
- **Cross-user process reads.** Two code paths read `system.processes`. Both are unsafe to
  grant on a shared server and can break if the view is limited to Kansoku's users.
  - `kansoku-admin`'s raw-write drain check matches *any* user's INSERT text
    (`kansoku-core/src/Kansoku/Admin/ClickHouse.hs:138`). Only Kansoku's users can write to
    `analytics`, so an own-user view is enough, but that should be explicit.
  - `clickhouse-migrate` repair looks up its own query IDs
    (`ClickHouseMigrate/Repair.hs:194`). Its own comment calls the result diagnostic only.
- **Pre-migration backup.** The guides require a consistent backup of PostgreSQL and both
  ClickHouse databases before each migration (`docs/guides/clickhouse-migrations.md`,
  `docs/guides/operations.md`). Nagare's per-app backups are separate 15-minute schedules with
  no on-demand trigger, which IR-31 asks for.
- **Restore verification.** Nagare restores an app database into scratch names
  (`analytics_restore_<ID>`) beside the live ones. Kansoku hard-codes both database names in its
  configuration and steps, so `verify` cannot check a restored copy on the same server.
- **Server identity.** A Nagare rebuilt-server restore gives a new `serverUUID()`, so the
  retained `KANSOKU_CH_MIGRATION_SERVER_ID` refuses until it is re-bound. No procedure covers
  that.
- **Privileges outside v0.7.0's grant set.** The storage probes (`system.disks`,
  `system.storage_policies`), the identity cache (`system.parts`, `ENGINE = Join` temporary
  tables) and the admin mutation check (`system.mutations`) are requested from Nagare in IR-30
  rather than redesigned here.


## Requested change

- Accept Nagare quiesce evidence (IR-31) as drain evidence, and document the ceremony on a
  shared server: keep the migration user available while the runtime is quiesced, and use no
  server restart.
- Make the admin drain check and `clickhouse-migrate` repair correct when `system.processes` is
  unreadable or limited to Kansoku's own users. Rely on the PostgreSQL fence plus quiesce
  evidence, and refuse rather than pass when nothing can be observed. The library change belongs
  in `mori://shinzui/clickhouse-migrate`.
- Take the pre-migration backup as on-demand app-database backups under the fence.
- Add read-only verification of a restored copy under different database names.
- Document the per-user privilege list and the server-identity re-bind after a rebuilt restore.


## Not requested

Renaming Kansoku's live databases or rewriting immutable steps. Removing the temporary-table
design of the identity cache. Loosening the exact server version pin: the platform owner
controls that version today, and it matches.
