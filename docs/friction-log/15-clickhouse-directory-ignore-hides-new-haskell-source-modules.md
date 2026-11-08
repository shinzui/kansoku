---
type: Friction Entry
title: "ClickHouse directory ignore hides new Haskell source modules"
description: "The unanchored clickhouse directory ignore also matches Kansoku/ClickHouse on a case-insensitive filesystem and excludes new modules from Nix source."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-08T03:18:47Z"
frictionId: FRIC-15
status: "resolved"
impact: detour
kind: tooling
origin: "mori://shinzui/kansoku"
affects: "mori://shinzui/kansoku"
plan: "docs/plans/63-keep-writes-and-maintenance-jobs-correct-on-a-replicated-cluster.md"
workaround: "Remove the redundant unanchored ignore, preserve /clickhouse/, and stage new sources before packaging."
resolution: "The redundant unanchored ignore is removed; the anchored root ClickHouse ignore remains and new native modules are tracked and packaged."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-08T04:14:40Z"
    change: "Resolve the case-insensitive source exclusion with the scoped ignore and tracked native modules."
---
# ClickHouse directory ignore hides new Haskell source modules

## Attempted

Run just ch-migrations-replicated while adding shared core native modules.

## Encountered

Cabal succeeds locally but Nix cannot find Kansoku/ClickHouse/Consistency because the new sources are ignored.

```text
Cabal-7554: cannot find source for Kansoku/ClickHouse/Consistency
```

## Workaround

Remove the redundant unanchored ignore, preserve /clickhouse/, and stage new sources before packaging.
