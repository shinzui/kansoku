---
type: Friction Entry
title: "Mori dependency discovery unavailable during portable drain implementation"
description: "Mori cannot connect to local PostgreSQL, blocking the mandatory dependency source lookup before evidence API implementation."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-13T18:05:46Z"
frictionId: FRIC-36
status: "resolved"
impact: blocked
kind: environment
origin: "mori://shinzui/kansoku"
affects: "mori://shinzui/mori"
plan: "docs/plans/50-accept-portable-drain-evidence-without-cross-user-process-visibility.md"
resolution: "The agent shell inherited a stale MORI_PG_CONNECTION_STRING and Home Manager sourced flag. Clearing __HM_ZSH_SESS_VARS_SOURCED before a fresh login shell loads the configured working socket; Mori discovery succeeds."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-13T18:10:06Z"
    change: "Corrected diagnosis: agent environment mismatch, not unavailable PostgreSQL service."
---
# Mori dependency discovery unavailable during portable drain implementation

## Attempted

mori registry list; mori registry search aeson; mori registry search clickhouse-migrate

## Encountered

NotifierConnectError: connection refused at /Users/shinzui/.local/state/sungkyung-clients/postgresql/.s.PGSQL.5432
