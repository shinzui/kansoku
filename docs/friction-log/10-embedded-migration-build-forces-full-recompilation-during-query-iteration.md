---
type: Friction Entry
title: "Embedded migration build forces full recompilation during query iteration"
description: "The build-with-tests wrapper forces all components to recompile and changing to a focused Cabal build changes flags again, adding several minutes to a query-only iteration."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-06T14:22:31Z"
frictionId: FRIC-10
status: "accepted"
impact: slowdown
kind: tooling
origin: "mori://shinzui/kansoku"
affects: "mori://shinzui/kansoku"
plan: "docs/plans/59-filter-and-group-events-by-their-session-attributes.md"
resolution: "Preserve the migration embed build contract; use a stable focused Cabal configuration during iteration and share the final build across Just targets."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-06T14:35:51Z"
    change: "Accept the full-recompile cost for the required migration-aware final gate; keep focused iterations on stable flags."
---
# Embedded migration build forces full recompilation during query iteration

## Attempted

Run just build-with-tests, fix a test helper name clash, then build the focused test executable.

## Encountered

The wrapper invokes cabal build all --enable-tests with -fforce-recomp and an embed macro; a focused build without these flags recompiled dependencies and the full test tree again.

```text
cabal build --ghc-options=-fforce-recomp -DCHM_EMBED_INPUT_ff5197ab7196f9c5341dab7e79986fc523d100975d7c4ca757e5f636a6d5c74a all --enable-tests
```
