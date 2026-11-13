---
type: Friction Entry
title: "OpenAPI generation followed by the full gate rebuilds dependent components"
description: "The documented OpenAPI and check sequence changes Cabal configurations and spends several minutes recompiling dependent components."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-13T15:01:11Z"
frictionId: FRIC-31
status: "accepted"
impact: slowdown
kind: tooling
origin: "mori://shinzui/kansoku"
affects: "mori://shinzui/kansoku"
plan: "docs/plans/71-filter-a-user-s-event-history-by-site.md"
resolution: "Retain the required validation sequence and its rebuild cost; optimizing shared build flags is outside this host-filter feature."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-13T15:08:20Z"
    change: "Accept the observed recompilation cost without weakening validation."
---
# OpenAPI generation followed by the full gate rebuilds dependent components

## Attempted

nix develop --no-write-lock-file -c bash -c "just openapi && just check"

## Encountered

After a successful build-with-tests, OpenAPI generation and the check build report configuration changes and recompile the API, 77 core modules, tests and executables.

```text
Build output: kansoku-api (lib) (configuration changed); Kansoku core Compiling [1 of 77]; test Compiling [1 of 62].
```
