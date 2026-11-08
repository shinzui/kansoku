---
type: Friction Entry
title: "Migration SQL fingerprints recompile unrelated application dependencies"
description: "The embedding wrapper passes the SQL fingerprint through global GHC options, rebuilding ClickHaskell, API and core when iterating only the appended migration SQL."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-08T06:02:42Z"
frictionId: FRIC-21
status: "accepted"
impact: slowdown
kind: tooling
origin: "mori://shinzui/kansoku"
affects: "mori://shinzui/clickhouse-migrate"
plan: "docs/plans/65-stop-counting-client-errors-and-web-vitals-as-session-engagement.md"
resolution: "Keep content-qualified embedding and the required gates; use bounded SQL probes before rebuilding the complete application graph when investigating migration behavior."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-08T06:07:57Z"
    change: "Accept the content-fingerprint rebuild cost for this plan; preserve the observed recurrence of FRIC-17."
---
# Migration SQL fingerprints recompile unrelated application dependencies

## Attempted

Rebuild the native migration and proof executables after changing reconstruction SQL

## Encountered

clickhouse-migrate-embed-build rebuilds the dependency graph, including unchanged ClickHaskell and all 68 core modules, for each candidate SQL fingerprint

```text
Build log: Compiling ClickHaskell.Protocol followed by Compiling Kansoku.Ingest.QueuedEvent after only the migration SQL input hash changed
```
