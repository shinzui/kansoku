---
type: Friction Entry
title: "Apple Container stalls while creating the qualification Keeper"
description: "The production-version fixture cannot create Keeper and its network cleanup also times out, blocking exact-version and image execution evidence."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-13T16:55:20Z"
frictionId: FRIC-33
status: logged
impact: blocked
kind: environment
origin: "mori://shinzui/kansoku"
affects: "https://github.com/apple/container"
plan: "docs/plans/72-keep-kansoku-starting-and-accepting-events-while-clickhouse-is-unavailable.md"
---
# Apple Container stalls while creating the qualification Keeper

## Attempted

python3 scripts/clickhouse_buffering_acceptance.py --packaged --production-fixture --case recovery

## Encountered

Owned Keeper container run timed out after 90 seconds; owned network deletion also timed out after 90 seconds, before any migrations or behavioral cases.

```text
TimeoutExpired: container run kansoku-owned-05608dd05f5b-keeper; TimeoutExpired: container network delete kansoku-owned-05608dd05f5b
```
