---
type: Architecture Decision Record
title: Best effort live activity isolated from writing
description: Keep live activity notifications outside writing success paths and allow stale UI when bounded best-effort hints are lost.
docId: ADR-27
status: Proposed
date: 2026-11-13
timestamp: 2026-11-13T18:15:56Z
generated:
  by: process:codex
  at: 2026-11-13T18:15:56Z
originatingPlan: docs/masterplans/8-stream-recent-events-and-page-views-over-websockets.md
---

# Best effort live activity isolated from writing

## Context

The initial live-activity plan put durable PostgreSQL publication after ClickHouse insertion and before queue acknowledgement. That makes live-feed failure a reason to retry an otherwise successful write. The user explicitly accepts stale UI to avoid affecting writing. This proposal records that priority; it does not claim deployed behavior or measured performance.

## Decision

After the existing successful insertion path, permit only a bounded nonblocking in-memory hint offer. No feed database I/O, durability barrier, visibility verification, subscriber acknowledgement or retry may gate HTTP acceptance, ClickHouse writing, queue acknowledgement or administrative completion. An offer may be dropped on contention, capacity, shutdown or failure. Keep event bodies out of the buffer.

An independently supervised publisher sends best-effort PostgreSQL notifications using its own bounded connection and rate budget. It cannot crash the writer, take writer pool capacity, hold maintenance admission, delay writer shutdown or request write retries. Each API instance listens and queries persisted canonical state on hints and on new subscriptions. No durable journal, outbox or periodic event-discovery query is required.

A missed final hint may leave a snapshot stale indefinitely until another hint or reconnect. Frames expose best-effort delivery, last successful snapshot time and no continuity guarantee. Heartbeats mean the connection is alive. Reconnect explicitly resets and reads a new bounded snapshot; there is no replay cursor. Delivered hints racing a query are handled with local dirty-state synchronization, but lost hints are not reconstructed.

The user’s scope revision relaxes original IR-16 AC-3 continuity and AC-4 no-loss requirements for internal notifications. Security, principal-derived tenancy, bounded token revocation, safe projection and socket resource bounds remain mandatory. Existing displayed data can remain stale after a missed administrative hint; every new query honors the existing maintenance fence and canonical erasure/retention. No socket send holds a traffic lease.

## Alternatives considered

Durable publication before queue acknowledgement was rejected because UI delivery would become a writing dependency. A separate durable outbox would still add mandatory persistence work; it is not justified by the accepted freshness tradeoff. Periodic ClickHouse discovery is unnecessary for this best-effort design. Unbounded fire-and-forget threads were rejected because they move backpressure into memory and scheduling.

## Consequences

There is no guarantee of zero CPU or shared database cost. Separate small pools, bounded queues, rate limits and load shedding contain the work. Qualification compares writing with the feed disabled, healthy, overloaded and failed; no feed-induced blocking, retries or acknowledgement failures are allowed. Measure latency and throughput rather than claiming zero overhead. Snapshot reads and authorization checks retain their own bounded resource cost.

Implementation and acceptance belong to [MasterPlan 8](../masterplans/8-stream-recent-events-and-page-views-over-websockets.md). [ADR-3](0003-api-key-authentication-and-account-scoped-analytics.md) continues to own authorization and [ADR-17](0017-fenced-resumable-administration-and-applied-retention.md) continues to own maintenance correctness. Accept this ADR only after the proposed isolation and failure behavior are demonstrated.
