---
id: 76
slug: qualify-and-document-the-packaged-live-activity-protocol
title: "Qualify and document the packaged live activity protocol"
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

# Qualify and document the packaged live activity protocol

This ExecPlan is a living document. Update Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective as work proceeds. Record friction through the exec-plan skill and promote durable implementation decisions into docs/adr/.

## Purpose / Big Picture

Give consumers a rerunnable proof that the distributed server streams real events through a WebSocket-capable reverse proxy, survives faults explicitly and keeps credentials server-side. Hard prerequisite: the whole `docs/plans/75-serve-authenticated-activity-websockets-from-best-effort-notifications.md` is Complete. This is the release gate for IR-16 as revised by the user’s writing-first constraint; implementation-only or fake socket evidence is insufficient.

## Progress

- [ ] M1: The owned fixture runs the packaged server through a reverse proxy and validates all wire frames and multi-instance delivery.
- [ ] M2: Required failure/isolation/revocation scenarios, deployment guidance and consumer handoff satisfy the revised acceptance mapping.

## Surprises & Discoveries

## Decision Log

2026-11-13 revision: The user prioritizes unaffected writing over UI freshness. Replace durable publication with lossy, bounded, asynchronous hints. No feed I/O, visibility checks, retries, locks or acknowledgements may become a prerequisite for ingest acceptance, ClickHouse writes, queue acknowledgement or maintenance completion. Auth/tenant isolation and bounded resources remain mandatory. Original IR-16 AC-3 continuity and AC-4 no-loss wording are superseded for notification delivery; do not claim those original guarantees have been met.

2026-11-13: Qualify the actual Nix-packaged executable and a WebSocket proxy with owned disposable stores; publish a repeatable consumer fixture instead of relying on unit tests alone.

## Outcomes & Retrospective

## Context and Orientation

`scripts/cohorts_acceptance.py`, `scripts/users_acceptance.py`, `scripts/isolated_postgres.py`, `scripts/isolated_clickhouse.py`, `scripts/apple_clickhouse_fixture.py` and `scripts/test_support.py` illustrate owned fixtures and binary selection. `scripts/acceptance.py` supplies packaged acceptance patterns. `justfile`, `flake.nix` and the existing CI files own build/check entry points. `docs/guides/operations.md`, `configuration.md` and `consumer-conformance.md` are the relevant deployment documents. The new `scripts/activity_stream_acceptance.py` already contains focused query/publication/socket scenarios from preceding children.

[ADR-3](../adr/0003-api-key-authentication-and-account-scoped-analytics.md) requires service-token authorization and principal-derived tenancy. [ADR-17](../adr/0017-fenced-resumable-administration-and-applied-retention.md) requires maintenance fencing and applied retention. [ADR-25](../adr/0025-identified-user-resources-and-safe-event-projection.md) supplies safe event projection conventions, but this feed must also include anonymous events. [ADR-10](../adr/0010-owned-executable-acceptance-environments.md) requires real packaged acceptance with owned stores. These constraints remain in force.

Before using dependency APIs, run `mori registry list`, `mori registry search <package>`, `mori registry show <qualified-project> --full`, and `mori registry docs <qualified-project>`, then read the located sources. Verify released versions with the authoritative registry and upstream tags before choosing bounds. Mori registry access failed during planning; no new library version or API is asserted here. Never traverse /nix/store or the filesystem root for dependency discovery. Use Apple Container for local Linux execution, never Colima.

## Plan of Work

M1 extends the fixture with `--packaged --proxy --required`. Resolve Nix build outputs through JSON and execute those binaries directly; do not traverse /nix/store to discover code or dependencies. Provision private PostgreSQL, ClickHouse, credentials and a reverse proxy on owned ports. On macOS prefer Apple Container where Linux images are needed, never Colima. Select and pin the proxy and fixture WebSocket client only after Mori/source discovery and authoritative release verification. Test a local TLS-terminated wss endpoint using a fixture-owned CA and explicit client trust. Exercise Upgrade forwarding, subprotocol and Authorization preservation, and proxy idle timeouts longer than the heartbeat/peer deadline. Keep credentials out of proxy/access logs.

Start two API/writer processes against the same owned databases. Ingest on one, subscribe on the other and reconnect to a different process. Qualify direct mode and each advertised replicated topology; if a mode is unsupported, assert explicit rejection and document that boundary rather than claiming coverage. Measure publication-to-frame delay independently from ingest acceptance-to-persistence delay. A missing datastore, proxy, container runtime or client dependency fails required mode instead of skipping. Add `just activity-stream-acceptance` and required CI integration following existing owned-fixture conventions.

M2 runs all required cases and publishes the connection recipe in `docs/guides/consumer-conformance.md`, with operations/configuration updates. Document URL, subprotocol, Authorization header, subscribe JSON, reset and snapshot schemas, nullable fields, bot/window/order semantics, coalescing limitations, durability boundary, potentially unbounded freshness lag, authorization bound, quotas per process/fleet, close codes, retry with jitter, TLS/upgrade settings, graceful drain and upgrade order. Explicitly distinguish notification-driven refresh from timers for heartbeat, authorization, window expiry. Document reduced freshness during mixed-version rollout and require fresh snapshots after upgrades/restores. No consumer replay token is issued; an offered old position gets a fresh reset rather than a continuity claim.

Map AC-1 to unchanged isolation/credential/revocation requirements; AC-2 to healthy public ingest and bounded safe snapshots; revised AC-3 to delivered-hint handoff correctness and fresh reset on reconnect without replay or gap-free claims; revised AC-4 to bounded resources, allowed internal hint loss and no writing dependency; AC-5 to served schemas, TLS proxy and packaged fixture. Drop the final hint and prove stale UI is allowed while writing succeeds; reconnect must read fresh state. Do not report original AC-3 or the original notification no-loss requirement as passed. [ADR-27](../adr/0027-best-effort-live-activity-isolated-from-writing.md) records the proposed architecture and the user-authorized freshness tradeoff. It is not implementation evidence.

Update guide bundle metadata/index/log through its established profile tools when changing guides. Record sanitized acceptance evidence, exact revision/build identities, case counts, topology and actual latency/resource observations in the child. Review and distill the live-activity ADR and affected ADR-3/10/17 decisions before marking the parent complete. Consumer handoff references remain `mori://shinzui/kansoku-ui/plans/27-integrate-the-recent-activity-api-through-the-server-boundary` and `mori://shinzui/kansoku-ui/plans/28-build-the-live-events-and-page-views-screen`; this work does not implement or publish that UI.

## Concrete Steps

Run from the repository root `/Users/shinzui/Keikaku/bokuno/kansoku-project/kansoku`. Recipes/options described as new below must be implemented by this plan before running them.

Implement the new recipe to build/resolve packaged outputs and execute the required fixture. The fixture defaults to private resources and must not accept an ambient destructive target.

```bash
nix develop --no-write-lock-file -c just check
nix develop --no-write-lock-file -c just activity-stream-acceptance
nix develop --no-write-lock-file -c python3 scripts/activity_stream_acceptance.py --packaged --proxy --required
```

The recipe and direct invocation exercise the same required gate; run either for final evidence, not both without a reason. Expected output includes package identity, proxy/TLS mode, supported topology, per-AC pass counts, no pending cases and sanitized evidence location. Also run the existing packaged regression gate when the integration changes its harness.

## Validation and Acceptance

Verify the revised acceptance mapping with real stores and public credentials. Fault only the notification publisher/connection, stop listeners, saturate hint queues, block notifier sends and create slow sockets while ingestion continues. Assert no feed-induced write retries, acknowledgement failures, extra writer SQL or visibility waits. Kill the writer around the optional hint offer and verify existing retry semantics without notification-driven replay. Separately test real storage outages as existing writer failures, not feed-isolation evidence. Preserve auth revocation, quotas, shutdown, safe projection and fresh post-maintenance reads. Compare feature-disabled, healthy-feed, saturated-feed and failed-feed runs under the same ingest workload; record write latency percentiles, persisted events/second, queue depth, retries, memory and database connections. Use repeated interleaved runs and record noise; adopt a provisional maximum 5% throughput/p95-write-latency regression budget, tightening it when stable measurements permit. Any feed-caused blocking/retry fails regardless of aggregate performance. Exceeding the budget requires reducing feed caps or disabling it, never relaxing write guarantees. Run the fixture twice for owned cleanup, leave unrelated listeners alive and retain sanitized evidence. No runtime evidence is claimed at planning time.

## Idempotence and Recovery

Every run creates an independent private resource directory; cleanup stops only recorded processes/container IDs. Failed runs retain private diagnostic evidence but do not reuse polluted stores on retry. Never use broad process-name termination or ambient databases. Qualification is local and CI work; no production deployment or release publication is authorized by this plan.

## Interfaces and Dependencies

Consume the endpoint, limits, schemas and best-effort behavior from the completed preceding plans. Own the packaged fixture, proxy configuration, CI/just integration and deployment documentation. Any discovered contract change must update the owning child's design and the parent integration points before widening acceptance. The parent is `docs/masterplans/8-stream-recent-events-and-page-views-over-websockets.md`. Close the initiative only after actual evidence is recorded; document-only completion of this planning task does not complete implementation.
