---
type: Improvement Request
title: Keep writes, reads and maintenance jobs correct on a replicated cluster
description: Make the writer's durability, read-after-write behaviour and the erase/retention maintenance jobs' quiesce and mutation checks hold across every replica of a replicated ClickHouse cluster reached through one load-balanced endpoint, where today each check sees only the replica its connection landed on.
generated:
  by: process:claude-code
  at: "2026-11-08T00:00:15Z"
requestId: IR-11
status: proposed
origin: mori://tan/tan-app-infrastructure/plans/45-onboard-kansoku-to-production-on-the-replicated-clickhouse-cluster
dependencies:
  - ref: mori://shinzui/kansoku/okf/improvement-requests/concepts/IR-10
    kind: hard
    reason: These behaviours can only be exercised against the replicated baseline and target IR-10 introduces.
acceptanceCriteria:
  - id: AC-1
    statement: Before a maintenance job runs native SQL on a replicated target, its raw-write quiesce check finds no in-flight insert into analytics.events_raw on any replica, not only on the replica its connection reached.
    verification: On the two-replica fixture, hold an insert open on one replica while the job's connection is pinned to the other, and assert the job keeps its fence and does not proceed until that insert ends.
  - id: AC-2
    statement: After erase-user and retention mutations, and after the projection TRUNCATE-and-INSERT rebuild, the job verifies completion on every replica and its canonical/public row-count check reads a state that includes all replicas' completed work.
    verification: On the two-replica fixture, run erase-user and retention jobs while one replica is lagging or briefly stopped, and assert the job either waits for both replicas or retains its fence with a named reason; it never reports success with an unfinished mutation on either replica.
  - id: AC-3
    statement: The writer's insert durability on a replicated target is an explicit, documented choice (for example insert_quorum covering both replicas, or a stated single-replica acknowledgement), and a writer retry after an ambiguous failure neither loses nor duplicates events, including in materialized-view targets.
    verification: On the two-replica fixture, stop one replica during writer batches and retry an acknowledged-but-unconfirmed batch; assert events_raw and every view target hold each event exactly once on both replicas after recovery, and the operations guide states the chosen setting.
  - id: AC-4
    statement: The read path's consistency on a replicated target is stated in the guides, and any Kansoku-owned check that reads back what it just wrote (smoke and verification flows, maintenance row counts) reads a replica that includes that write.
    verification: A fixture test writes through one replica and immediately reads through the other using the same settings the check uses, and the guide's operations section documents the setting.
reviews:
  - kind: model
    reviewer: process:claude-code
    reviewed_at: "2026-11-08T00:00:15Z"
    document_timestamp: "2026-11-08T00:00:15Z"
    scope: content-and-metadata
    outcome: commented
    provider: anthropic
    model: claude-opus-5-5
    effort: unspecified
    context: >-
      Author review against Kansoku 2008b67: kansoku-core/src/Kansoku/Admin/ClickHouse.hs
      (quiesceRawWrites, verifyMutations, the projection rebuild) and Admin/Jobs.hs call sites,
      and kansoku-core/src/Kansoku/ClickHouse.hs connection settings. The replica-local
      behaviour of system.processes and system.mutations is ClickHouse's documented behaviour;
      the writer and materialized-view deduplication concerns are hypotheses for AC-3 to settle,
      not observed failures. No independent verification attestation is claimed.
---

# Keep writes, reads and maintenance jobs correct on a replicated cluster

**Authored by:** a `claude-code` session in `mori://tan/tan-app-infrastructure`, planning
Kansoku's production onboarding
(`mori://tan/tan-app-infrastructure/plans/45-onboard-kansoku-to-production-on-the-replicated-clickhouse-cluster`).
**Addressed to:** `shinzui/kansoku` agents.
**Created:** 2026-11-08.

This is the second of three requests filed together. It needs IR-10's replicated baseline.


## Why

In production, Kansoku reaches `tan-production` (one shard, two replicas) through one Altinity
endpoint that load-balances connections across the replicas. Each connection lands on one
replica. Several of Kansoku's safety checks query system tables that only describe the replica
they run on.

- **The quiesce check sees one replica.** `quiesceRawWrites`
  (`kansoku-core/src/Kansoku/Admin/ClickHouse.hs:133-140`) waits until `system.processes` shows
  no insert into `analytics.events_raw`. It is called before a maintenance job's native work
  (`kansoku-core/src/Kansoku/Admin/Jobs.hs:95`). `system.processes` lists only the local
  server's queries, so an insert still running on the other replica is invisible. The comment
  that justifies the check, "any write that can still commit data is already registered in
  system.processes", holds for one server but not for a cluster.
- **The mutation check sees one replica.** `verifyMutations` (`Admin/ClickHouse.hs:121-123`)
  checks `system.mutations` for unfinished or failed mutations in `analytics`. It runs after
  erase-user and retention work (`Admin/Jobs.hs:132`) and after the projection rebuild
  (`Admin/ClickHouse.hs:96`). Mutations on Replicated tables run on each replica, and
  `system.mutations` reports the local replica's view. So one replica can pass while the other
  is still working, or has failed.
- **The rebuild and its row counts may read a lagging replica.** The projection rebuild runs
  `TRUNCATE` and then `INSERT … SELECT`, and then compares `count()` of `events_canonical` and
  `events_resolved` (`Admin/ClickHouse.hs:93-99`). On a replicated cluster, those reads can come
  from a replica that has not caught up. That gives a false "lost canonical facts" failure, or
  a pass that is false.
- **The writer's durability on two replicas is not chosen.** The writer disables async inserts
  (`kansoku-core/src/Kansoku/ClickHouse.hs:146`) but sets no quorum. An insert acknowledged by
  one replica can be lost if that replica fails before the other fetches the part.
  `ReplicatedMergeTree` also deduplicates identical inserted blocks, which non-replicated
  `MergeTree` does not do by default. Whether that interacts badly with retries and with
  materialized views that write to a `TO` target is a question for AC-3 to answer, not a
  defect anyone has seen.

None of this shows up on a single server, which is why staging and the current acceptance
suite cannot catch it. Erase-user is a privacy operation. Reporting it done while one replica
still holds the data is the failure that matters most.


## Requested change

- **Make the quiesce and mutation checks cluster-wide on replicated targets.** Examples are
  `clusterAllReplicas('<cluster>', system.processes)` and `… system.mutations`, or connecting
  to each replica in turn. Reuse the cluster name and replica set IR-10 adds. Prefer to fail
  closed: if a replica cannot be reached, keep the fence and name the replica.
- **Wait for every replica's mutations.** Run maintenance mutations with settings that wait
  for all replicas (`mutations_sync=2`, `alter_sync=2`, as clickhouse-migrate's replicated
  profile does), and read the checks with sequential consistency.
- **Choose and document the writer's insert durability.** Write the choice in the operations
  guide, then prove retries stay exactly-once in `events_raw` and the view targets on both
  replicas.
- **State read consistency.** Say what read consistency queries get on a replicated target,
  and make Kansoku's own read-back checks use a setting that sees their writes.
- **Add the cases to the two-replica acceptance recipe from IR-10.** Pin connections, stop a
  replica, and hold an insert open.


## Notes

The `system.parts` read in `kansoku-core/src/Kansoku/Identity/Cache.hs:61-62` (sizing the
identity cache) is replica-local as well. It looks like an estimate, not a safety check, so this
request does not ask for it to change. Mention it in the guide if that is wrong.

IR-2 in this bundle, *Operate Kansoku's ClickHouse schema and maintenance on a shared server*,
is related but separate. It is about other apps' queries on the same server. This request is
about Kansoku's own work spread across replicas.
