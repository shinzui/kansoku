---
type: Friction Entry
title: "Owned replica restart readiness ends before interrupted rebuild recovery"
description: "The public replicated fixture discards its operation error and ends its thirty-second restart readiness loop before all tables recover after a final-checkpoint outage."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-08T03:50:47Z"
frictionId: FRIC-16
status: "accepted"
impact: detour
kind: interface
origin: "mori://shinzui/kansoku"
affects: "mori://shinzui/clickhouse-migrate/packages/clickhouse-migrate-test-support"
plan: "docs/plans/63-keep-writes-and-maintenance-jobs-correct-on-a-replicated-cluster.md"
workaround: "Preserve typed fixture RPC failure in the local bridge; start exactly once, then independently verify the same UUID and zero read-only database/table counts within a bounded sixty-second readiness observation before resume."
resolution: "Retain the owned full-schema fixture capacity profile and explicit failure/identity observations; both final-checkpoint restart cases pass without retrying failed starts."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-08T04:14:40Z"
    change: "Accept the explicit owned capacity profile and bounded same-UUID restoration checks for full-schema recovery."
---
# Owned replica restart readiness ends before interrupted rebuild recovery

## Attempted

Restore the same owned replica after stopping it at the rebuilt checkpoint, then resume the still-fenced job.

## Encountered

startReplica returned only Owned fixture operation failed after thirty seconds, terminating the bridge and losing structured failure evidence.

```text
Owned fixture operation failed; evidence: /tmp/clickhouse-migrate-replicated-ttb7yuk7
```

## Workaround

Preserve typed fixture RPC failure in the local bridge; start exactly once, then independently verify the same UUID and zero read-only database/table counts within a bounded sixty-second readiness observation before resume.


## Investigation

A further bounded readiness observation also failed: the restarted process stayed
alive but its HTTP endpoint could not answer even SELECT 1. The public fixture's
full-schema configuration uses a global thread limit of 128 and a background
schedule pool of 8. The local owned adapter qualified a global limit of 1024 and
a background pool of 64, applied before application migration and read back from
its retained configuration. This preserves the exact image, Keeper setup,
replication, schema and account settings; it does not weaken the runtime barriers
or retry a failed restart. The original failure logs and fenced job observations
remain private acceptance evidence.

Hackage and upstream tags were rechecked on 2026-11-08: the current published
test-support release remains 0.1.0.0; Kansoku retains Plan 62's pinned 0.1.1.0 source
cohort. No dependency pin or version bound changed for this fixture adjustment.

The focused rebuild case passes both interrupted replay boundaries and missing-replica recovery from rebuilt and verified with that resource profile and no initial readiness refusals.
