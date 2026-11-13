---
id: 73
slug: define-bounded-recent-activity-snapshots-and-the-websocket-contract
title: "Define bounded recent activity snapshots and the WebSocket contract"
kind: exec-plan
created_at: 2026-11-13T18:04:02Z
intention: "intention_01m7b1727jef5r1827z8vqbbmw"
master_plan: "docs/masterplans/8-stream-recent-events-and-page-views-over-websockets.md"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-11-13T18:04:02Z
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-11-13T18:16:10Z
      mode: "update"
      note: "Prioritize writing: replace durable publication with bounded best-effort hints and revise freshness acceptance."
---

# Define bounded recent activity snapshots and the WebSocket contract

This ExecPlan is a living document. Update Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective as work proceeds. Record friction through the exec-plan skill and promote durable implementation decisions into docs/adr/.

## Purpose / Big Picture

Provide a reusable query and machine-readable contract for a current events/page-view screen. Given an authenticated account, consumers receive the newest matching retained rows with deterministic order and explicit bounds. Native query acceptance proves behavior before transport implementation. This is the first child of MasterPlan 8 and has no hard prerequisite.

## Progress

- [ ] M1: Versioned frame schemas and codecs describe replacement, reset, bounds and safe projection, with deterministic contract tests.
- [ ] M2: Real-store recent queries prove tenant isolation, selection before limiting, late arrivals, expiry and bounded failure.

## Surprises & Discoveries

## Decision Log

2026-11-13 revision: The user prioritizes unaffected writing over UI freshness. Replace durable publication with lossy, bounded, asynchronous hints. No feed I/O, visibility checks, retries, locks or acknowledgements may become a prerequisite for ingest acceptance, ClickHouse writes, queue acknowledgement or maintenance completion. Auth/tenant isolation and bounded resources remain mandatory. Original IR-16 AC-3 continuity and AC-4 no-loss wording are superseded for notification delivery; do not claim those original guarantees have been met.

2026-11-13: Use a bounded current-state contract and separate row ordering from frame ordering. No public resume cursor or exhaustive per-event delivery guarantee is introduced.

## Outcomes & Retrospective

## Context and Orientation

IR-16 is `docs/improvement-requests/stream-recent-events-and-page-views-over-websockets.md`. `kansoku-core/src/Kansoku/Users/History.hs` projects event IDs, timestamps, canonical host/path and `event_name = page_view`, but scopes to an identified user; do not reuse that scope for the account-wide feed. `kansoku-core/src/Kansoku/ClickHouse.hs` owns query pools, deadlines and topology-aware readback. `kansoku-core/src/Kansoku/Metrics/Query/Dimension.hs` owns canonical domain SQL. `analytics.events_canonical` deduplicates retained facts; raw accepted or queued events are not evidence of durable visibility. `kansoku-api/src/Kansoku/Api.hs` and `kansoku-api/src/Kansoku/Api/OpenApi.hs` own the served HTTP contract.

[ADR-3](../adr/0003-api-key-authentication-and-account-scoped-analytics.md) requires service-token authorization and principal-derived tenancy. [ADR-17](../adr/0017-fenced-resumable-administration-and-applied-retention.md) requires maintenance fencing and applied retention. [ADR-25](../adr/0025-identified-user-resources-and-safe-event-projection.md) supplies safe event projection conventions, but this feed must also include anonymous events. [ADR-10](../adr/0010-owned-executable-acceptance-environments.md) requires real packaged acceptance with owned stores. These constraints remain in force.

Before using dependency APIs, run `mori registry list`, `mori registry search <package>`, `mori registry show <qualified-project> --full`, and `mori registry docs <qualified-project>`, then read the located sources. Verify released versions with the authoritative registry and upstream tags before choosing bounds. Mori registry access failed during planning; no new library version or API is asserted here. Never traverse /nix/store or the filesystem root for dependency discovery. Use Apple Container for local Linux execution, never Colima.

## Plan of Work

M1 defines `Kansoku.Activity.Types` in the API package, adds it to the Cabal module list, and writes `docs/api/activity-websocket.md` plus `docs/api/activity-websocket.schema.json`. Choose `/v1/activity` with required `kansoku.activity.v1` subprotocol, a single subscribe message and one subscription per connection. The subscribe message selects `events` or `pageViews`, `includeBots` (default false), `limit` (default/max 100) and `windowSeconds` (default/max 1800, minimum 1). Reject unknown selection, invalid bounds and account selectors. Define subscribe, reset, snapshot, heartbeat and error schemas, including required nullable host/path. Event fields are eventId, eventName, occurredAt, isPageView, host and path; omit properties, identity, context and full URLs.

The v1 product is a bounded current-state subscription, not an every-event audit stream. Each replacement snapshot contains the latest matching rows visible to that query; intermediate states may be coalesced. Fields must distinguish top-N truncation from continuity: `truncated` says another matching row existed at that read, while `deliveryMode: "replacement-snapshot"` and `intermediateStatesMayBeCoalesced: true` explicitly deny exhaustive delivery. No frame claims that every event since its predecessor was delivered. Stable row identity is account plus event ID. Subscription-local epoch and sequence order frames independently of occurrence time. Reconnect always starts a new epoch with an explicit reset; public replay tokens are not issued in v1. There are no journal positions. Set `notificationDelivery: "best-effort"` and `continuityGuaranteed: false`; expose last successful snapshot time without promising a maximum freshness lag. Dropped notifications can leave the UI stale until another hint or reconnect.

Snapshot envelopes include protocol version, epoch, monotonically increasing sequence, serverTime, windowStart, windowEnd, limit, truncated and the normalized selection. Define `[windowStart, windowEnd)` against a single server-time sample and sort by occurrence time descending, receipt time descending, then event ID descending. Receipt time may remain internal. Heartbeats carry last successful refresh time and current stream state, not an assertion that queued ingest is persisted. Specify unsupported resume requests as explicit fresh reset, never as resumed continuity.

M2 implements `kansoku-core/src/Kansoku/Activity/Query.hs` using principal-supplied account parameters and canonical retained rows. Apply account, occurrence-time window, page-view and bot predicates before ordering and `limit + 1`; use the extra row only to set truncated. Do not scan identity-resolution history or fetch raw properties. Enforce query timeout, scanned/read bytes and output budgets through the existing native query facilities. Bound total serialized frame size later without silently clipping individual values. Empty result is success; exhausted budgets and storage errors are failures, not empty snapshots. Return an internal next-transition deadline: the earliest expiry among returned rows or entry time of the earliest matching future-dated canonical row. Obtain the latter with the same account/kind/bot predicates and bounded native query budgets. This lets the transport schedule one precise refresh even when no new write arrives.

Establish query visibility entirely in the feed read path, never by adding verification to the writer. Direct mode reads canonical persisted rows; replicated mode may lag after a hint and must document that lag with no guarantee of another notification. Reconnect always queries anew. A bounded feed-side retry may follow an observed failure, but there is no periodic discovery loop or writer wait. Use existing readback facilities only if their cost fits the separate feed query budget. [ADR-27](../adr/0027-best-effort-live-activity-isolated-from-writing.md) records the proposed architecture and the user-authorized freshness tradeoff. It is not implementation evidence.

## Concrete Steps

Run from the repository root `/Users/shinzui/Keikaku/bokuno/kansoku-project/kansoku`. Recipes/options described as new below must be implemented by this plan before running them.

Add `Kansoku.Activity.ContractSpec` and `Kansoku.Activity.QuerySpec` to the deterministic test selection, and introduce `scripts/activity_stream_acceptance.py --scenario query` using the existing owned-store helpers.

```bash
nix develop --no-write-lock-file -c just deterministic-test
nix develop --no-write-lock-file -c python3 scripts/activity_stream_acceptance.py --scenario query
nix develop --no-write-lock-file -c just check
```

Expected: nonzero contract/query example counts, no pending required cases, and a query scenario summary proving two-account selection. Capture actual counts and commands in Progress when implemented.

## Validation and Acceptance

Seed more than 100 unrelated events plus matching page views and prove page-view selection still returns those views. Include anonymous events, bots, null/invalid URLs, tied occurrence timestamps, a late persisted row inside the window, an event outside the window and an expired row. Compare exact IDs and ordering against expected rows. Replay an event and see one stable identity. No other-account row or private value may appear. Inject a native timeout and observe unavailable rather than a partial success. Test a row whose projected strings would exceed eventual wire limits; the contract must require explicit failure, not silent omission. Use a fake clock only for deterministic boundary tests; native coverage must read real stores.

## Idempotence and Recovery

This child is additive and needs no ClickHouse schema migration unless measured query behavior proves one necessary. If an index/projection is needed, append explicit migrations under the repository migration workflow; never modify applied SQL. Fixtures own disposable stores and can be rerun. Do not mark a topology supported if its visibility test fails.

## Interfaces and Dependencies

Own `ActivitySelection`, `ActivityRow`, `ActivitySnapshot`, frame codecs and `readRecentActivity` with an explicit account, time and selection input and typed unavailable/budget failures. Exact Haskell representation is an implementation choice; wire meanings above are fixed. EP-74 consumes the best-effort hint semantics, EP-75 consumes the query and codecs, and EP-76 compares served frames/schema. Dependency plans are `docs/plans/74-publish-best-effort-activity-hints-without-delaying-writes.md`, `docs/plans/75-serve-authenticated-activity-websockets-from-best-effort-notifications.md` and `docs/plans/76-qualify-and-document-the-packaged-live-activity-protocol.md`. Add frame-schema generation/drift checking without pretending OpenAPI alone describes WebSocket messages.
