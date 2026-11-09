---
type: Improvement Request
title: Keep Kansoku starting and accepting events while ClickHouse is unavailable
description: Make the PostgreSQL queue the buffer between Kansoku and ClickHouse in every case, so kansoku-server always starts and keeps receiving events during a ClickHouse or replica outage, where today replicated startup exits if any replica is unreachable and readiness removes the server from traffic.
generated:
  by: process:claude-code
  at: "2026-11-08T23:59:34Z"
requestId: IR-15
status: proposed
origin: mori://tan/tan-app-infrastructure/plans/45-onboard-kansoku-to-production-on-the-replicated-clickhouse-cluster
dependencies:
  - ref: mori://shinzui/kansoku/okf/improvement-requests/concepts/IR-11
    kind: hard
    reason: This request changes the replicated runtime startup and writer behaviour that IR-11 introduced.
acceptanceCriteria:
  - id: AC-1
    statement: On a replicated target with one replica stopped, a newly started kansoku-server starts, listens, answers GET /health/live with 200 and accepts valid events into the PostgreSQL queue with HTTP 202.
    verification: On the two-replica fixture, stop one replica, start the packaged server, then assert the liveness response, a 202 ingest response and the queued message.
  - id: AC-2
    statement: With every ClickHouse server unreachable, on both replicated and direct targets, a newly started kansoku-server behaves as in AC-1 and does not exit, crash-loop or wait on ClickHouse before it listens.
    verification: With all ClickHouse servers stopped, start the packaged server for each topology and assert AC-1's observations within a stated bound that does not depend on any ClickHouse timeout.
  - id: AC-3
    statement: The signal an orchestrator uses to admit traffic depends only on what ingest needs. A ClickHouse outage, an unreachable replica, a growing backlog or a stale writer flush does not remove a server that can still enqueue events from traffic. Pipeline and ClickHouse health remain observable through a separate signal or metrics.
    verification: During one-replica and full ClickHouse outages longer than KANSOKU_READY_MAX_FLUSH_AGE_SEC, with a backlog present, assert the admission signal stays successful and ingest still returns 202, while the separate health signal reports the failing check. Stopping PostgreSQL must still fail admission.
  - id: AC-4
    statement: After a server starts during an outage, the writer drains the queue once ClickHouse returns, with no restart, and every event is present exactly once on every expected replica, using the all-replica quorum policy.
    verification: Ingest during the outage, restore the replicas without restarting the server, and assert an empty queue, zero dead letters and identical logical results on both replicas.
  - id: AC-5
    statement: An observed topology or schema mismatch, such as an unexpected replica UUID, a wrong replica set or a replicated schema in direct mode, never blocks startup or ingest and never lets the writer insert. The events stay queued and the mismatch is reported through the health signal and logs, naming the nonsecret reason.
    verification: Start the server against each mismatch and assert it listens, accepts events, performs no ClickHouse insert, and reports the mismatch; correct the configuration and assert the queue drains.
  - id: AC-6
    statement: The operations guide states the buffering guarantee, the admission and health signals, how long the queue can absorb an outage, and what a deployment must configure, and the released image is handed to TAN with its digest, source revision and plan hashes.
    verification: Read the guide and the release record, which also state any probe change TAN must make.
reviews:
  - kind: model
    reviewer: process:claude-code
    reviewed_at: "2026-11-08T23:59:34Z"
    document_timestamp: "2026-11-08T23:59:34Z"
    scope: content-and-metadata
    outcome: commented
    provider: anthropic
    model: claude-opus-5-5
    effort: unspecified
    context: >-
      Author review against Kansoku 7c1132d: kansoku-server/app/Main.hs,
      kansoku-core/src/Kansoku/ClickHouse.hs, Consistency.hs, Readiness.hs, Server.hs and the
      operations guide, and tan-app-infrastructure's serving.ts. The startup and readiness
      behaviours come from reading that source. Neither was reproduced against a stopped replica
      on the managed cluster. No independent verification attestation is claimed.
---

# Keep Kansoku starting and accepting events while ClickHouse is unavailable

**Authored by:** a `claude-code` session in `mori://tan/tan-app-infrastructure`, after onboarding
Kansoku to production
(`mori://tan/tan-app-infrastructure/plans/45-onboard-kansoku-to-production-on-the-replicated-clickhouse-cluster`).
**Addressed to:** `shinzui/kansoku` agents and the Kansoku release owner.
**Created:** 2026-11-08.


## Why

TAN's requirement, from Kansoku's production owner: **Kansoku must never be blocked from starting,
because the PostgreSQL queue is the buffer between Kansoku and ClickHouse.** Production runs image
`gcr.io/tan-ng/kansoku@sha256:a78b668dbc98567bfd2d031f9b3aaf3a22b1f3f4bd4fbfd3ca3605dfbf98d213`
(source `7c1132d`) on two replicas, with one server replica. Two behaviours in that source break
the requirement.

**Startup requires every replica.** The first action in `kansoku-server/app/Main.hs:66`, before
PostgreSQL is opened or the port is bound, is `validateClickHouseTopology`.
`kansoku-core/src/Kansoku/ClickHouse.hs:135-147` tolerates an unavailable server only on a direct
target; its comment says this is to "preserve ingest availability when a direct server restarts
during a storage outage". The replicated branch calls `withReplicaConnections`, which needs every
expected UUID within 35 seconds, and throws otherwise. `Consistency.hs` reports an unreachable
replica and a real mismatch as the same `ConsistencyError`, so a caller cannot tell them apart. A
pod that restarts during a replica outage or a managed upgrade therefore crash-loops, and
ingestion stops until both replicas return. TAN has no configuration workaround, because dropping
the replica selectors enters direct mode, which refuses a replicated schema.

**Readiness removes a working server from traffic.** `Server.hs:162-169` makes readiness depend on
`clickhouse_query_reachable`, `queue_depth` and `writer_flush_stale`, as the operations guide
documents. Writes need every replica, so one stopped replica stops flushes. Once a backlog exists
and the last flush is older than `KANSOKU_READY_MAX_FLUSH_AGE_SEC` (default 120), readiness fails.
TAN uses `/health/ready` as the Kubernetes readiness probe, as that guide recommends, so Kubernetes
then removes the pod from the Service. Producers lose the server exactly when the queue should be
absorbing events. A large backlog fails readiness the same way through `queue_depth`.

IR-11 deliberately chose write unavailability during a replica stop, and this request keeps that
choice. It only requires that write unavailability stops at the writer.


## Requested change

- **Always start.** Starting and listening must not depend on ClickHouse being reachable or
  matching. Move topology and schema validation out of the startup path, and retry it where
  writes happen.
- **Separate "can accept events" from "pipeline is healthy".** Give orchestrators an admission
  signal that depends only on what ingest needs, and keep ClickHouse, backlog and flush health
  visible separately. Whether that is a changed `/health/ready` or a new endpoint is Kansoku's
  decision. These paths are stated operational contracts, so say what changes for existing
  deployments.
- **Keep the writer safe.** Distinguish an unreachable replica from an observed mismatch. Either
  way the writer must not insert until the expected topology is confirmed, and events wait in the
  queue.
- **Apply this to both topologies.** The requirement does not depend on topology. Direct mode's
  fatal startup on an observed mismatch is covered too.


## Notes

Out of scope:

- PostgreSQL outages, which are the one dependency ingest genuinely needs.
- Metric queries, which may keep returning retryable 503 during an outage.
- The maintenance fence, which deliberately rejects protected traffic while it is active.
- Deploy-time migration Jobs. They need ClickHouse by design, and a failed Job holds back the new
  image while leaving the running server in place.

The queue is finite. Queue-depth and oldest-message alerts should cover that risk rather than
removing a server from traffic. `KANSOKU_READY_MAX_QUEUE_DEPTH` may need a new role here.

TAN will consume the released image through an ordinary production image deploy and make any probe
change the release record names. Until then, TAN's runbook tells operators not to restart
`kansoku-server` during a ClickHouse outage.
