---
type: Friction Entry
title: "Required validation commands rebuild unchanged Cabal components"
description: "The required check and acceptance sequence repeatedly recompiles the Cabal graph because embedding and telemetry commands use different compiler flags."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-13T05:30:32Z"
frictionId: FRIC-26
status: "accepted"
impact: slowdown
kind: tooling
origin: "mori://shinzui/kansoku"
affects: "mori://shinzui/kansoku"
plan: "docs/plans/69-save-named-analyses-for-an-account.md"
resolution: "Retain the required embedding and telemetry validation; accept their repeated compilation cost for this implementation."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-13T05:32:49Z"
    change: "Accept the observed gate cost without weakening validation or expanding this saved-analysis feature into build-tool changes."
---
# Required validation commands rebuild unchanged Cabal components

## Attempted

Run just check followed by just analyses-acceptance on the same candidate.

## Encountered

The embedding prerequisite forces recompilation with -fforce-recomp; telemetry invokes Cabal without those flags, and the following acceptance prerequisite recompiles the graph again, costing several minutes on unchanged components.

```text
clickhouse-migrate-embed-build invokes cabal build --ghc-options=-fforce-recomp -DCHM_EMBED_INPUT_85e29564d443c0cf19c518a0d019183bcd0a8243678598ff5e43eceec1518691 all --enable-tests; telemetry then reports configuration/Flags changed; the next prerequisite repeats the full build.
```
