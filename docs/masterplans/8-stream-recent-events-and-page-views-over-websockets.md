---
id: 8
slug: stream-recent-events-and-page-views-over-websockets
title: "Stream recent events and page views over WebSockets"
kind: master-plan
created_at: 2026-11-13T18:03:11Z
intention: "intention_01m7b1727jef5r1827z8vqbbmw"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-11-13T18:03:11Z
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-11-13T18:16:10Z
      mode: "update"
      note: "Prioritize writing: replace durable publication with bounded best-effort hints and revise freshness acceptance."
---

# Stream recent events and page views over WebSockets

This MasterPlan coordinates the child ExecPlans below. The registry owns child status; each child owns its milestones. Implementation has not begun.

## Vision & Scope

Deliver [IR-16](../improvement-requests/stream-recent-events-and-page-views-over-websockets.md): an authenticated, account-scoped WebSocket endpoint serving a recent snapshot and pushed replacements for all events or canonical page views. Initial bounds are 100 rows over 30 minutes. Consumers receive stable IDs, occurrence timestamps, event names, page-view classification and nullable host/path without raw properties or identity payloads. The acceptance mapping below preserves security and bounds while explicitly relaxing notification completeness at the user’s direction.

Use a bounded, nonblocking in-memory offer after successful ClickHouse insertion. A separately supervised publisher sends best-effort PostgreSQL NOTIFY messages using its own connection. Every API process listens and refreshes affected subscriptions. A full queue, dead publisher, failed notification or process crash may lose hints; writing and normal queue acknowledgement continue unchanged. There is no durable change journal, new outbox transaction, replay cursor or feed-driven write retry. No periodic event-discovery query is added.

The v1 product is a bounded current-state subscription, not an every-event audit stream. Each replacement snapshot contains the latest matching rows visible to that query; intermediate states may be coalesced. Fields must distinguish top-N truncation from continuity: `truncated` says another matching row existed at that read, while `deliveryMode: "replacement-snapshot"` and `intermediateStatesMayBeCoalesced: true` explicitly deny exhaustive delivery. No frame claims that every event since its predecessor was delivered. Stable row identity is account plus event ID. Subscription-local epoch and sequence order frames independently of occurrence time. Reconnect always starts a new epoch with an explicit reset; public replay tokens are not issued in v1. Notifications are explicitly best effort; a missed final hint may leave the UI stale indefinitely until another relevant hint or reconnect. Heartbeats prove connection liveness, not feed freshness; report last successful snapshot time and no continuity guarantee.

The user explicitly accepts stale UI to protect writing. This changes the earlier IR-16 interpretation: preserve AC-1 authentication, AC-2 safe bounded snapshots under healthy delivery and AC-5 documented packaged protocol. Revise AC-3 to best-effort change discovery with fresh snapshot on reconnect, and AC-4 to allow dropped internal hints while still requiring bounded socket queues, visible freshness semantics and isolation from writing. Delivered notifications racing a snapshot must still be handled correctly; undelivered notifications carry no gap-free guarantee. Do not mark the original unamended IR-16 fully satisfied. [ADR-27](../adr/0027-best-effort-live-activity-isolated-from-writing.md) records the proposed architecture and the user-authorized freshness tradeoff. It is not implementation evidence.

The consumer boundary remains `mori://shinzui/kansoku-ui/masterplans/5-support-a-live-view-of-current-events-and-page-views`, with integration at `mori://shinzui/kansoku-ui/plans/27-integrate-the-recent-activity-api-through-the-server-boundary` and screen work at `mori://shinzui/kansoku-ui/plans/28-build-the-live-events-and-page-views-screen`. Kansoku UI owns its server relay and browser rendering. Browser credentials, permanent audit history, exactly-once delivery, external SQL writers, and production deployment are outside this initiative. Supported event mutations must pass through Kansoku; administrative hints are also best effort; fresh queries remain fenced and honor erasure/retention. Existing displayed snapshots may remain stale, as authorized.

## Decomposition Strategy

Four functional concerns have separate observable outcomes: correct bounded reads and wire types; best-effort publication and write isolation; secure socket delivery; and packaged deployment qualification. Separating transport from publication prevents a working socket from masking a dependency on writing. Query work is verified against real stores before socket breadth expands, and the first socket milestone proves the actual producer-to-consumer path.

[ADR-3](../adr/0003-api-key-authentication-and-account-scoped-analytics.md) requires service-token authorization and principal-derived tenancy. [ADR-17](../adr/0017-fenced-resumable-administration-and-applied-retention.md) requires maintenance fencing and applied retention. [ADR-25](../adr/0025-identified-user-resources-and-safe-event-projection.md) supplies safe event projection conventions, but this feed must also include anonymous events. [ADR-10](../adr/0010-owned-executable-acceptance-environments.md) requires real packaged acceptance with owned stores. These constraints remain in force.

[ADR-9](../adr/0009-bounded-complete-aggregate-responses.md) reinforces query bounds and explicit failures. It does not turn this best-effort UI into a complete event log. [ADR-27](../adr/0027-best-effort-live-activity-isolated-from-writing.md) records the proposed architecture and the user-authorized freshness tradeoff. It is not implementation evidence. The children update this proposed ADR with verified behavior during implementation; retain existing ADR-3/17 security and administrative rules.

## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|---|---|---|---|---|
| EP-73 | Snapshot and protocol contract | docs/plans/73-define-bounded-recent-activity-snapshots-and-the-websocket-contract.md | None | None | Not Started |
| EP-74 | Best-effort hints and write isolation | docs/plans/74-publish-best-effort-activity-hints-without-delaying-writes.md | EP-73 | None | Not Started |
| EP-75 | Authenticated WebSocket delivery | docs/plans/75-serve-authenticated-activity-websockets-from-best-effort-notifications.md | EP-73, EP-74 | None | Not Started |
| EP-76 | Packaged qualification and deployment guide | docs/plans/76-qualify-and-document-the-packaged-live-activity-protocol.md | EP-75 | None | Not Started |

## Dependency Graph

Execute EP-73, then EP-74, then EP-75, then EP-76. Each hard dependency requires the whole child to be Complete. EP-74 consumes the bounded-view and best-effort semantics defined in EP-73. EP-75 needs a proved publication/listener interface and snapshot query. EP-76 qualifies the complete server through a reverse proxy. There is no required parallel execution or implicit milestone bypass.

EP-74's first milestone proves a real PostgreSQL hint waking a second process after successful insertion, then proves that stopping the publisher or filling its queue leaves writer success and acknowledgement unchanged. EP-75 first proves public ingest-to-socket delivery under healthy conditions. EP-76 measures write performance and overload behavior of the packaged candidate.

## Integration Points

EP-73 owns `kansoku-api/src/Kansoku/Activity/Types.hs`, the proposed `/v1/activity` endpoint contract, subprotocol `kansoku.activity.v1`, `docs/api/activity-websocket.schema.json`, and `docs/api/activity-websocket.md`. It owns the account-scoped query in `kansoku-core/src/Kansoku/Activity/Query.hs`. EP-75 consumes those types, serves the schema and declares typed authorization; EP-76 validates actual frames against it.

EP-74 owns `Kansoku.Activity.Hints`, `Kansoku.Activity.Publisher` and `Kansoku.Activity.Listener`. It adds no durable tables. The writer offers bounded account invalidations in memory after its existing successful insertion path; it performs no publication network I/O. A separate worker sends notifications with bounded rate, connection use and retries; overflow drops hints. Notifications are hints to query, not proof of visibility or a source of event payloads. Listener reconnect causes fresh snapshots, never journal catch-up.

EP-75 owns subscription lifecycle, bounded queues, quotas, configuration and runtime wiring in `Kansoku.Server`. It uses a dedicated PostgreSQL listener session and per-account/selection sharing within each process. No transaction remains open while waiting for notifications. Timers handle heartbeat, token revalidation and rolling-window expiry; they must not become periodic event-discovery queries. A change signal may cause one coalesced query for many subscribers.

EP-74 and EP-75 keep feed work out of writer and maintenance success paths. Queries use separate small feed pools and short maintenance admission; no lease is held across socket sends or notifier I/O. Maintenance completion may offer a nonblocking hint but does not wait for notification. A missed administrative hint can leave a prior UI snapshot visible; any new query must pass the existing fence and retention/erasure rules. Auth revocation remains bounded regardless of hint loss. Shared CPU/database contention cannot be literally zero, so EP-76 measures it and requires shedding live-feed work first.

EP-76 owns `scripts/activity_stream_acceptance.py`, the new `just activity-stream-acceptance` recipe and packaged/proxy mode. EP-73/74/75 establish focused cases in that harness as their behaviors become available; EP-76 extends rather than replaces them. All commands and filenames introduced by this initiative are proposed until their owning milestone implements them.

## Progress

Plans are revised; implementation has not started. EP-73 is ready and the other children await hard prerequisites. Release acceptance uses the user-revised AC-3/4 mapping above, plus explicit writer isolation and packaged proxy coverage. Original IR-16 is not claimed satisfied unchanged.

## Surprises & Discoveries

`Kansoku.Server.maintenanceTraffic` holds admission over protected HTTP operations. Applying that wrapper unchanged to a long-lived upgraded connection could delay maintenance indefinitely; the socket needs bounded operation-level admission.

Mori discovery was unavailable because its local PostgreSQL socket refused connections. Existing canonical consumer references come from IR-16, not a fresh cross-repository inspection. See [FRIC-35](../friction-log/35-mori-registry-discovery-unavailable-during-live-activity-planning.md). No external consumer implementation is claimed verified.

## Decision Log

2026-11-13, superseded: The initial draft selected durable PostgreSQL publication before acknowledgement. The subsequent user priority rejects that write-path dependency. 2026-11-13 revision: The user prioritizes unaffected writing over UI freshness. Replace durable publication with lossy, bounded, asynchronous hints. No feed I/O, visibility checks, retries, locks or acknowledgements may become a prerequisite for ingest acceptance, ClickHouse writes, queue acknowledgement or maintenance completion. Auth/tenant isolation and bounded resources remain mandatory. Original IR-16 AC-3 continuity and AC-4 no-loss wording are superseded for notification delivery; do not claim those original guarantees have been met.

2026-11-13: Retain replacement snapshots and fresh-snapshot reconnect. Best-effort hints carry invalidations, not public event replay. This keeps the protocol bounded while explicitly allowing missed hints.

2026-11-13: Use a new intention created with the user-requested `mina ci --json` command. The originating request's intention remains historical context, not this initiative's tracking ID.

## Outcomes & Retrospective
