---
type: Friction Entry
title: "Migration fixture defaults need a separate native-test account"
description: "The migration toolkit fixture intentionally supplies hostile defaults and a read-only XML administrator, requiring additional setup before existing application native tests can run."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-08T02:02:09Z"
frictionId: FRIC-13
status: "accepted"
impact: detour
kind: interface
origin: "mori://shinzui/kansoku"
affects: "mori://shinzui/clickhouse-migrate"
plan: "docs/plans/62-run-clickhouse-migrations-on-a-replicated-cluster.md"
workaround: "Create a disposable SQL native-test user on each replica with synchronous, unbounded settings and distributed_ddl_output_mode=none; preserve the restricted app profile for migration execution."
resolution: "Keep hostile defaults for migration qualification; the owned native-query phase creates a disposable synchronous account, disables fixture table deduplication windows after parity capture, and clears owned data between groups. Production writer and maintenance qualification remains separate."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-08T02:20:28Z"
    change: "Document and automate the native-query fixture setup without weakening migration app restrictions or Hspec assertions."
---
# Migration fixture defaults need a separate native-test account

## Attempted

Run the existing query and metrics Hspec groups through the replicated fixture native port

## Encountered

Asynchronous inserts and one-row truncation invalidated ordinary test assumptions; Replicated DDL returned status rows; ALTER USER default failed with Code 495 ACCESS_STORAGE_READONLY.

```text
Code: 495. Cannot update user default in users_xml because this storage is readonly.
```

## Workaround

Create a disposable SQL native-test user on each replica with synchronous, unbounded settings and distributed_ddl_output_mode=none; preserve the restricted app profile for migration execution.
