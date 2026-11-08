---
type: Friction Entry
title: "Two embedded histories amplify content-wrapper rebuild cost"
description: "The content-qualified embedding wrapper forces the entire application dependency graph to recompile during topology acceptance iteration."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-08T01:40:24Z"
frictionId: FRIC-12
status: logged
impact: slowdown
kind: tooling
origin: "mori://shinzui/kansoku"
affects: "mori://shinzui/clickhouse-migrate"
plan: "docs/plans/62-run-clickhouse-migrations-on-a-replicated-cluster.md"
---
# Two embedded histories amplify content-wrapper rebuild cost

## Attempted

Run just ch-migrations-replicated with both manifests

## Encountered

The wrapper passes -fforce-recomp globally; unrelated core modules and both immutable baselines recompile for a focused acceptance build.

```text
cabal build --ghc-options=-fforce-recomp -DCHM_EMBED_INPUT_<digest>
```
