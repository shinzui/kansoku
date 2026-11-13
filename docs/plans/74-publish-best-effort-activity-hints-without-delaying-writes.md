---
id: 74
slug: publish-best-effort-activity-hints-without-delaying-writes
title: "Publish best effort activity hints without delaying writes"
kind: exec-plan
created_at: 2026-11-13T18:04:03Z
intention: "intention_01m7b1727jef5r1827z8vqbbmw"
master_plan: "docs/masterplans/8-stream-recent-events-and-page-views-over-websockets.md"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-11-13T18:04:03Z
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-11-13T18:16:10Z
      mode: "update"
      note: "Prioritize writing: replace durable publication with bounded best-effort hints and revise freshness acceptance."
---

# Publish best effort activity hints without delaying writes

This ExecPlan is a living document. Update Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective as work proceeds. Record friction through the exec-plan skill and promote durable implementation decisions into docs/adr/.

## Purpose / Big Picture

Wake interested API processes after writes without making live delivery a writing dependency. A hint is a lossy signal that current activity may have changed. This plan must prove that publisher failure, saturation or shutdown cannot change writer success, retries or acknowledgement. Hard prerequisite: the whole `docs/plans/73-define-bounded-recent-activity-snapshots-and-the-websocket-contract.md` is Complete.

## Progress

- [ ] M1: Healthy best-effort notifications refresh a second process; stopped or saturated publishers leave writing and acknowledgement unchanged.
- [ ] M2: Publisher/listener resource caps, independent supervision and lossy restart behavior pass real-store failure tests.

## Surprises & Discoveries

## Decision Log

2026-11-13 revision: The user prioritizes unaffected writing over UI freshness. Replace durable publication with lossy, bounded, asynchronous hints. No feed I/O, visibility checks, retries, locks or acknowledgements may become a prerequisite for ingest acceptance, ClickHouse writes, queue acknowledgement or maintenance completion. Auth/tenant isolation and bounded resources remain mandatory. Original IR-16 AC-3 continuity and AC-4 no-loss wording are superseded for notification delivery; do not claim those original guarantees have been met.

## Outcomes & Retrospective

## Context and Orientation

`kansoku-core/src/Kansoku/Writer/Run.hs` defines `insertCurrent`: under `withTraffic`, it rewrites queued events for current dispositions and invokes `insertWriterEvents`. `kansoku-core/src/Kansoku/Writer/Batch.hs` acknowledges only when its insertion callback returns successfully. `kansoku-core/src/Kansoku/Writer/Recovery.hs` retries that callback and renews leases. `kansoku-core/src/Kansoku/Ingest/Acceptance.hs` atomically claims stable identity and enqueues accepted payloads; do not publish live rows at that earlier boundary. `kansoku-core/src/Kansoku/Migrations.hs` owns PostgreSQL migrations. `kansoku-core/src/Kansoku/Admin/Jobs.hs`, `Admin/Coordination.hs` and `Maintenance.hs` coordinate erasure/retention with a persisted fence.

[ADR-3](../adr/0003-api-key-authentication-and-account-scoped-analytics.md) requires service-token authorization and principal-derived tenancy. [ADR-17](../adr/0017-fenced-resumable-administration-and-applied-retention.md) requires maintenance fencing and applied retention. [ADR-25](../adr/0025-identified-user-resources-and-safe-event-projection.md) supplies safe event projection conventions, but this feed must also include anonymous events. [ADR-10](../adr/0010-owned-executable-acceptance-environments.md) requires real packaged acceptance with owned stores. These constraints remain in force.

Before using dependency APIs, run `mori registry list`, `mori registry search <package>`, `mori registry show <qualified-project> --full`, and `mori registry docs <qualified-project>`, then read the located sources. Verify released versions with the authoritative registry and upstream tags before choosing bounds. Mori registry access failed during planning; no new library version or API is asserted here. Never traverse /nix/store or the filesystem root for dependency discovery. Use Apple Container for local Linux execution, never Colima.

## Plan of Work

M1 implements `kansoku-core/src/Kansoku/Activity/Hints.hs`, `Publisher.hs` and `Listener.hs`. After the existing insert operation completes successfully, offer a compact affected-account hint to a bounded in-memory buffer. Do not add PostgreSQL transactions, readback queries or delivery waits to `insertCurrent`, `writerBatchHandler`, ingest acceptance or queue acknowledgement. Preserve the original writer outcome; a synchronous exception from the hint helper is contained, but normal cancellation semantics remain unchanged. A feed failure must not enter `recoverInsert`, dead-letter a batch, renew its queue lease or withhold acknowledgement.

The offer must have bounded CPU/allocation and no blocking lock acquisition, waiting STM retry, disk access, per-event thread spawning or subscriber iteration. Use a nonblocking bounded queue or try-lock/drop operation, including under contention, with bounded account extraction from the already bounded writer batch. Default to at most 1024 queued hints and 256 KiB total encoded-equivalent routing data; drop oversized/full offers and increment a bounded aggregate metric. Do not retain event bodies. Verify these mechanics in the actual library source before choosing an API.

A separately supervised publisher drains/coalesces hints and sends PostgreSQL NOTIFY through its own connection, never the ingest/writer pool. Use a maximum of one publisher connection/process, ten sends/second, bounded payloads below the server notification limit, one-second send timeout and bounded backoff. Do not accumulate a durable backlog or retry individual hints indefinitely. Failures lose hints and increment metrics; shutdown discards remaining hints without waiting for delivery. Publisher failure must not participate in the writer's StopAllOnFailure supervision tree or server readiness requirement. All defaults are proposed caps to verify under load, not measured capacity claims.

Each API instance has a dedicated LISTEN session and waits on socket readability, not periodic discovery SELECTs. Commit LISTEN before snapshot initialization. Do not keep a transaction open while idle. A notification marks affected local subscriptions dirty; duplicates/order do not matter because readers replace their snapshots. Establish a fresh snapshot on reconnect; missed notifications are never replayed. Follow PostgreSQL's initialization sequence at https://www.postgresql.org/docs/18/sql-listen.html after verifying client APIs through Mori. No new PostgreSQL schema or durable position is needed.

M2 tests isolation and contains resource use during failure. Kill only the fixture-owned publisher while ingestion and the writer continue; fill its buffer, reject notifier connections, stall sends and restart it. Separate notification-specific failure from a whole PostgreSQL outage, which already prevents ordinary ingestion and acknowledgement. Do not claim the feature makes existing storage failures harmless. Duplicate, delayed and absent notifications are permitted. A crash after insertion but before offering a hint may leave the UI stale; the queue must follow its original acknowledgement/retry rules, not retry to repair UI delivery.

Administrative completion may make the same nonblocking offer after the existing transition succeeds, including a global hint when necessary. Never alter fence-release transactions or wait for publication. Missed erasure/retention hints can leave a previous displayed snapshot stale; all new reads still honor the maintenance fence and canonical retained facts. Hint payloads contain only routing metadata, never raw properties, identities or credentials. Unsubscribe, discard and reconnect behavior remains bounded. Update ADR-27 with actual measured limitations before accepting implementation.

## Concrete Steps

Run from the repository root `/Users/shinzui/Keikaku/bokuno/kansoku-project/kansoku`. Recipes/options described as new below must be implemented by this plan before running them.

Extend the new owned fixture with publication and isolation modes and add deterministic bounded-offer/listener state tests.

```bash
nix develop --no-write-lock-file -c just deterministic-test
nix develop --no-write-lock-file -c python3 scripts/activity_stream_acceptance.py --scenario publication
nix develop --no-write-lock-file -c python3 scripts/activity_stream_acceptance.py --scenario isolation
nix develop --no-write-lock-file -c just check
```

The fixture must launch a separate listener process, not invoke a local handler directly. Expected output names each crash interval, queue saturation and writer acknowledgement isolation, with no skips.

## Validation and Acceptance

With healthy services a notification wakes two API processes and the resulting snapshots read persisted canonical facts. With the publisher stopped, failed, blocked or saturated, compare normal writer acknowledgements, retries, queue depth and ClickHouse event identities against the feature-disabled control. No feed-induced write retry or acknowledgement failure is allowed. Drop the only final hint and explicitly observe a potentially stale UI until reconnect; reconnect returns a fresh snapshot. Duplicate notifications remain harmless. A quiet connection issues no discovery SELECT. Feed queue bytes, thread counts, connection counts and retry rate stay within caps. Prove a notifier fault cannot terminate the writer or server and that shutdown does not wait for notification delivery.

## Idempotence and Recovery

No new durable migration is required. The feature can be disabled without changing ingestion correctness. Restart loses all hints intentionally and reconnect obtains a fresh snapshot. Rollout may temporarily reduce freshness when old writers emit no hints; it must not alter write semantics. Fixtures use private stores and recorded PIDs. Never compensate for missing UI notifications by replaying already successful writes.

## Interfaces and Dependencies

Expose a bounded nonblocking `offerActivityHint` and independently owned publisher/listener lifecycle. Names describe proposed local interfaces, not external library APIs. Outcomes are offered/dropped for the producer and changed/disconnected for the consumer; there is no durable generation, journal cursor or catch-up operation. EP-75 consumes these interfaces only after this child is accepted. [ADR-27](../adr/0027-best-effort-live-activity-isolated-from-writing.md) records the proposed architecture and the user-authorized freshness tradeoff. It is not implementation evidence.