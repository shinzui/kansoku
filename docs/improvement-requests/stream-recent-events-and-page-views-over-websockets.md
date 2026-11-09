---
type: Improvement Request
title: Stream recent events and page views over WebSockets
description: Provide an authenticated account-scoped WebSocket subscription with a bounded recent snapshot and live updates so consumers can display current events and page views without polling.
requestId: IR-16
status: proposed
timestamp: "2026-11-09T13:37:41Z"
generated:
  by: process:codex
  at: "2026-11-09T13:37:41Z"
origin: mori://shinzui/kansoku-ui/masterplans/5-support-a-live-view-of-current-events-and-page-views
acceptanceCriteria:
  - id: AC-1
    statement: A documented versioned WebSocket endpoint authenticates service tokens, derives tenancy only from the authenticated principal, rejects write keys and invalid credentials, and enforces a documented revocation bound for established subscriptions.
    verification: Public socket tests use two accounts, invalid and write credentials, and revoke an established subscriber's token; no cross-account row is observed and revocation closes access within the declared bound.
  - id: AC-2
    statement: Events and canonical page-view subscriptions provide a bounded initial recent snapshot and subsequent live updates with stable identity, event timestamps, host/path, explicit ordering and window semantics, and documented bot selection.
    verification: An isolated public ingest-to-WebSocket fixture receives one ordinary event and one page view without repeated HTTP reads; page-view selection occurs before limiting, including when unrelated events fill the unfiltered limit.
  - id: AC-3
    statement: The snapshot-to-live handoff has no silent gap; duplicate delivery is identifiable, and reconnect either resumes within a documented retention bound or explicitly resets to a fresh bounded snapshot.
    verification: Inject events during snapshot creation, disconnect and reconnect, replay a duplicate, deliver a late event, and expire a resume token; assert identities, ordering and an explicit reset where continuity cannot be preserved.
  - id: AC-4
    statement: Heartbeats, message and queue limits, slow-consumer handling, connection quotas, error/close semantics and backend-unavailable behavior are documented and bounded without blocking ingestion or silently dropping rows.
    verification: Slow and idle consumers, malformed messages, quota exhaustion, backend outages and server restart prove bounded queues and explicit reset or closure; healthy subscribers and ingestion continue.
  - id: AC-5
    statement: The served protocol and deployment guide include authentication, version negotiation, payload schemas, time and completeness guarantees, TLS/upgrade and idle-timeout requirements, and a rerunnable consumer acceptance fixture.
    verification: Run the fixture against the packaged server through a WebSocket-capable reverse proxy and verify initial snapshot, subsequent updates, heartbeat and reconnect; compare emitted frames with the documented schemas.
reviews:
  - kind: model
    reviewer: process:codex
    reviewed_at: "2026-11-09T13:37:41Z"
    document_timestamp: "2026-11-09T13:37:41Z"
    scope: content-and-metadata
    outcome: commented
    provider: openai
    model: gpt-6-astra
    effort: unspecified
    context: Author consistency review against the current Kansoku API surface and the consumer MasterPlan; protocol requirements are proposed, and no runtime implementation or independent review is claimed.
---

# Stream recent events and page views over WebSockets

Requested by `mori://shinzui/kansoku-ui/masterplans/5-support-a-live-view-of-current-events-and-page-views` under intention `intention_01m707rxfzep9s4n3jfjc1xa2v`. This is one endpoint-and-protocol request: snapshot, streaming, recovery and bounds must agree to deliver a usable feed.

## Why

The UI needs a Live screen showing individual current events and page views. The current `Kansoku.Api` in `mori://shinzui/kansoku/packages/kansoku-api` exposes ingest and aggregate/resource reads, but no event subscription. Aggregate metric buckets cannot supply individual event rows. The user explicitly selected WebSockets instead of the initial HTTP-polling proposal.

## Requested behavior

Kansoku owns the endpoint path, implementation and exact versioned wire schema. Support a subscription selecting all events (including page views) or canonical page views alone. The initial consumer asks for the latest 100 matching rows within the last 30 minutes; enforce finite server bounds and apply selection before limiting. Return stable event IDs, occurrence times, event names, page-view classification, and nullable host/path. Include server time, window bounds and truncation information; omit arbitrary raw properties and sensitive identity payloads from this first contract.

Send an initial snapshot followed by pushed updates. Specify how additions, removals, aging out of the rolling window and corrections are represented; a bounded replacement snapshot is acceptable as an update, as are explicit deltas with equivalent semantics. Define a race-free snapshot/live boundary and an ordering or sequence mechanism distinct from occurrence time, so equal timestamps and late arrivals cannot silently disappear. Define when a row is publishable (for example after query visibility), including failed/retried ingestion and replay behavior. Do not label queued but unpersisted activity as durable. Explicitly document delivery and ingestion latency boundaries; no exactly-once or permanent audit-log guarantee is requested.

On reconnect, support either bounded replay from a scoped opaque position or an explicit fresh-snapshot reset. Never silently claim continuity after retained history expires, a process restarts, or a slow consumer exceeds its queue. Position tokens, if provided, must be scoped to account and subscription and validated on reuse. Initial subscription may start fresh; unlimited history and lossless offline catch-up are excluded. State any multi-instance restrictions and prove the supported deployment path: attaching to a different process must not silently miss events.

Use service-token authentication on the server-to-server upgrade, preserving [ADR-3](../adr/0003-api-key-authentication-and-account-scoped-analytics.md). Kansoku UI will connect from its server and expose a separate same-origin browser WebSocket; the browser will not receive Kansoku credentials. No query-string token transport or broader browser CORS policy is requested. Document authentication failure before upgrade, terminal authorization failure after upgrade, and revocation checks for long-lived subscriptions.

Bound frame bytes, event batches, per-connection buffered data, connection counts and subscription counts. Slow consumers must trigger an explicit resync/reset or closure, without unbounded memory growth or blocking ingestion. Specify heartbeats and deadlines, unsupported protocol handling, retryable versus permanent errors, safe error payloads, graceful shutdown and retry guidance. Provide enough application-visible liveness information for a browser relay to distinguish a quiet feed from a dead connection.

## Acceptance and ownership

AC-1 through AC-5 are required together. Publish the schema and a packaged real-service fixture; a fake-only socket or an endpoint that requires the UI to poll metrics does not satisfy this request. Implementation remains in this repository. The consumer handoff is `mori://shinzui/kansoku-ui/plans/27-integrate-the-recent-activity-api-through-the-server-boundary`; the screen is `mori://shinzui/kansoku-ui/plans/28-build-the-live-events-and-page-views-screen`.

The UI owns its credential-preserving relay, browser lifecycle and rendering. This request does not require a particular broker, streaming library or storage topology. Choose the smallest backend design that meets the documented delivery boundary and deployment behavior.
