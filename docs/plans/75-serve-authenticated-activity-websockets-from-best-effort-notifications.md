---
id: 75
slug: serve-authenticated-activity-websockets-from-best-effort-notifications
title: "Serve authenticated activity WebSockets from best effort notifications"
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

# Serve authenticated activity WebSockets from best effort notifications

This ExecPlan is a living document. Update Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective as work proceeds. Record friction through the exec-plan skill and promote durable implementation decisions into docs/adr/.

## Purpose / Big Picture

Let an authorized server connect once and receive current account activity as it changes, with bounded resources and explicit recovery. Hard prerequisites are the complete `docs/plans/73-define-bounded-recent-activity-snapshots-and-the-websocket-contract.md` and `docs/plans/74-publish-best-effort-activity-hints-without-delaying-writes.md`. This child exposes the real public socket; the following child qualifies its packaged deployment.

## Progress

- [ ] M1: Public ingest wakes a real authenticated WebSocket through best-effort hints, including correct handling of delivered hints during snapshot creation.
- [ ] M2: Revocation, quotas, slow consumers, expiry, shutdown, maintenance and backend failures have bounded tested outcomes.

## Surprises & Discoveries

## Decision Log

2026-11-13 revision: The user prioritizes unaffected writing over UI freshness. Replace durable publication with lossy, bounded, asynchronous hints. No feed I/O, visibility checks, retries, locks or acknowledgements may become a prerequisite for ingest acceptance, ClickHouse writes, queue acknowledgement or maintenance completion. Auth/tenant isolation and bounded resources remain mandatory. Original IR-16 AC-3 continuity and AC-4 no-loss wording are superseded for notification delivery; do not claim those original guarantees have been met.

2026-11-13: Use one subscription per socket and shared per-process refresh workers keyed by authenticated account and normalized selection. The public reconnect policy is always explicit fresh reset.

## Outcomes & Retrospective

## Context and Orientation

`kansoku-core/src/Kansoku/Server.hs` assembles typed Servant routes, request middleware, operational probes and the maintenance gate. `kansoku-core/src/Kansoku/Auth/Handler.hs` and `Auth/Store.hs` implement service-token checks and revoked-key exclusion. `kansoku-core/src/Kansoku/Config.hs` owns server settings; `kansoku-server/app/Main.hs` owns process lifetime. The new Activity query, schema, publisher and listener from the prerequisites are authoritative. A subscription epoch is a fresh identity for one socket's delivery history; its frame sequence is not an event timestamp or durable replay cursor.

[ADR-3](../adr/0003-api-key-authentication-and-account-scoped-analytics.md) requires service-token authorization and principal-derived tenancy. [ADR-17](../adr/0017-fenced-resumable-administration-and-applied-retention.md) requires maintenance fencing and applied retention. [ADR-25](../adr/0025-identified-user-resources-and-safe-event-projection.md) supplies safe event projection conventions, but this feed must also include anonymous events. [ADR-10](../adr/0010-owned-executable-acceptance-environments.md) requires real packaged acceptance with owned stores. These constraints remain in force.

Before using dependency APIs, run `mori registry list`, `mori registry search <package>`, `mori registry show <qualified-project> --full`, and `mori registry docs <qualified-project>`, then read the located sources. Verify released versions with the authoritative registry and upstream tags before choosing bounds. Mori registry access failed during planning; no new library version or API is asserted here. Never traverse /nix/store or the filesystem root for dependency discovery. Use Apple Container for local Linux execution, never Colima.

## Plan of Work

M1 discovers the released WebSocket/WAI integration through Mori and verifies versions before adding dependencies. Declare authentication in the route type with a distinct principal wrapper, preserving ADR-3; do not bypass the typed route via an unauthenticated global upgrade wrapper. Add the versioned route and serve the protocol schema. Before upgrade, require Bearer service token, reject write keys and invalid credentials, negotiate the subprotocol, and enforce admission quotas. Query-string credentials are invalid. The browser receives no Kansoku token and no broader CORS permission.

Implement `kansoku-core/src/Kansoku/Activity/Server.hs` and a bounded subscription hub. Register local interest before the initial snapshot query. Delivered hints set a local dirty flag; after snapshot completion refresh again if dirty, using an atomic check/clear operation so locally received notifications are not accidentally lost. Emit reset then snapshot. This prevents a local handoff bug, but does not promise delivery of hints dropped before the listener. No committed generation or journal is consulted. Frames explicitly declare best-effort notification delivery and no continuity guarantee. A query reads persisted canonical state; a hint is never itself an event payload or durability proof.

M2 establishes concrete default bounds: one subscription/socket, 100 rows, 1800 seconds, 16 KiB incoming message, 1 MiB outgoing message, at most two queued outgoing data frames/2 MiB per socket, 10 sockets/account/process and 200 sockets/process. Limits include encoding buffers, fragmented messages, control messages and the in-flight send. Bound shared worker/cache counts and query concurrency separately; use a proposed cap of two concurrent feed queries per process with bounded admission. Reject excess subscriptions or quotas explicitly. Document that per-process quotas multiply by instance count and make the deployment's aggregate bound explicit.

Use a five-second send deadline and five-second initial-subscribe deadline; heartbeat every 15 seconds with a 30-second peer-response deadline. Revalidate the stored token hash every 15 seconds with a five-second lookup deadline and independently enforce a maximum 20-second authorization age, including while sends or queries stall. Revocation, principal change and lookup uncertainty stop further data delivery and close access within that bound. Do not retain the raw credential. Never log credentials, hashes, private event data or raw backend exception text.

Use bounded socket queues with closure on overflow; do not silently drop already queued frames. Loss of internal change hints is separately permitted by the best-effort contract. Coalescing before a snapshot is computed is the advertised replacement policy, whereas losing an already queued frame is an overload requiring closure/reset. Authentication errors after upgrade are terminal; overload, listener loss, maintenance and backend outages are retryable with explicit safe errors and bounded closure. If a client cannot receive an error, forcibly close by the send deadline. Define close codes and retry guidance in the protocol; use standard codes where appropriate and documented application codes for terminal authorization, maintenance and reset-required conditions.

Window expiry uses a timer scheduled for the next known row expiry. On expiry recompute the bounded snapshot to include any eligible replacement rows. Use the query-provided next-entry deadline for future-dated matching rows as well, so they become eligible without a new write. Recompute the next deadline after every refresh; an empty snapshot may still have a future entry deadline. No repeating event-discovery query is allowed. Wall-clock movement must not break monotonic deadlines. Heartbeats and auth checks remain timers, not event polling.

Use a separate, small feed query pool and separate feed auth/notification connections with bounded admission; never reserve writer/ingest pool slots for a socket. Cap feed queries at two concurrent/process with a one-second native deadline initially, then measure cost. Shed/defer feed refreshes when budgets are exhausted rather than increasing pressure. Scope maintenance admission only to the short query, never to socket sends, heartbeats or notifier operations. Administrative hints are best effort: purge cache and refresh on a received hint, while a missed hint may leave an old displayed snapshot until reconnect. New queries must respect the existing maintenance fence and canonical retention/erasure. Keep auth revocation checks independent and mandatory. Graceful shutdown stops socket work within its deadline and discards hints without delaying writer shutdown. A dead publisher/listener must not crash the server or writer, disable ingest readiness or trigger write retries. [ADR-27](../adr/0027-best-effort-live-activity-isolated-from-writing.md) records the proposed architecture and the user-authorized freshness tradeoff. It is not implementation evidence.

## Concrete Steps

Run from the repository root `/Users/shinzui/Keikaku/bokuno/kansoku-project/kansoku`. Recipes/options described as new below must be implemented by this plan before running them.

Extend the owned fixture and deterministic scheduler tests. Add a CLI scenario selector rather than requiring a manual token or ambient service.

```bash
nix develop --no-write-lock-file -c python3 scripts/activity_stream_acceptance.py --scenario socket
nix develop --no-write-lock-file -c python3 scripts/activity_stream_acceptance.py --scenario lifecycle
nix develop --no-write-lock-file -c just deterministic-test
nix develop --no-write-lock-file -c just check
```

Expected: an initial snapshot, a later snapshot following public ingest without repeated HTTP reads, heartbeat, and explicit reset after reconnect. Required failure scenarios must report nonzero case counts.

## Validation and Acceptance

Use two accounts and invalid/write/service credentials. Revoke an established token through the actual admin command and measure closure within 20 seconds even with a stalled query or send. Exercise malformed/oversized/fragmented messages, unsupported protocol, missing subscribe, quotas and slow readers; ingestion and a healthy socket continue. Verify page views when unrelated events exceed the limit, bot selection, duplicate ingest, late arrivals, timestamp ties, expiry and maintenance deletion. Disconnect the listener and restart the server; known listener loss and server restart lead to reset/closure; an undetectably missed hint may leave a stale snapshot with continuity explicitly disclaimed. Simultaneously ingest through instance A and subscribe through B. During idle steady state, event-discovery query count stays flat; auth/heartbeat and expiry activity are measured separately. Compare every application frame with the committed schema and assert that no private fields escape.

## Idempotence and Recovery

All socket resources need bracketed cancellation-safe cleanup. Overflow closes one consumer without blocking the writer. Mixed-version writers may reduce freshness until they emit hints; document this without imposing a write-path gate. Use bounded retry with jitter for recovery and fresh reset on reconnect. Keep existing HTTP behavior and startup-outage tests passing; a failed socket feature must not change ingest acceptance semantics.

## Interfaces and Dependencies

Consume the API types/query from EP-73 and best-effort publisher/listener from EP-74. Own connection quotas, timers, frame sequencing, typed route, startup/shutdown wiring and configuration documentation. EP-76 consumes the working public endpoint and extends acceptance to the Nix executable and reverse proxy. `docs/api/activity-websocket.md` is the normative close/error/limit contract; implementation changes must update codecs, served schema, docs and tests together.
