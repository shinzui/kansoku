---
type: Friction Entry
title: "Final native gates force broad recompilation for a focused consumer fix"
description: "The content-qualified embedding wrapper recompiles the application graph and both embedded histories when rerunning a required native gate after a focused session-test fix."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-08T04:38:29Z"
frictionId: FRIC-17
status: "accepted"
impact: slowdown
kind: tooling
origin: "mori://shinzui/kansoku"
affects: "mori://shinzui/clickhouse-migrate/packages/clickhouse-migrate-embed"
plan: "docs/plans/63-keep-writes-and-maintenance-jobs-correct-on-a-replicated-cluster.md"
workaround: "Use focused Cabal targets during iteration, then pay the required complete embedding-aware build at the final validation boundary."
resolution: "Retain content-sensitive embedding safety and its required broad final builds; use focused targets for iteration."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-08T04:42:50Z"
    change: "Accept the repeated final-build cost without weakening embedding or native acceptance gates."
---
# Final native gates force broad recompilation for a focused consumer fix

## Attempted

Rerun just check and just ch-migrations-replicated after updating one native session test to the current rebuild helper.

## Encountered

Required gate commands pass -fforce-recomp with content metadata and rebuild core/test components plus both ClickHouse history modules, taking several minutes per boundary.

```text
cabal build --ghc-options=-fforce-recomp -DCHM_EMBED_INPUT_823005f1557f81b5d25f1b46ae400a02982ebb603094b7b77030ceaade840630 ...
```

## Workaround

Use focused Cabal targets during iteration, then pay the required complete embedding-aware build at the final validation boundary.
