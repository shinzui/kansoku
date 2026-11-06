---
type: Friction Entry
title: "OpenAPI generation reconfigures the test-enabled build"
description: "Running cabal run through the documented OpenAPI target changes component flags and makes the next test-enabled build recompile much of the workspace."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-06T13:16:25Z"
frictionId: FRIC-6
status: "accepted"
impact: slowdown
kind: tooling
origin: "mori://shinzui/kansoku"
affects: "mori://shinzui/kansoku"
plan: "docs/plans/56-attribute-conversions-to-first-touch-acquisition.md"
resolution: "Keep the existing build and generation workflow for this feature; complete generation before the final test-enabled build to avoid additional flag churn."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-06T13:19:04Z"
    change: "Accept the existing rebuild cost without expanding this feature into build-tool changes"
---
# OpenAPI generation reconfigures the test-enabled build

## Attempted

Run just openapi after just build-with-tests, then run just acquisition-acceptance.

## Encountered

Cabal reported Flags changed and recompiled libraries and the core test suite after OpenAPI generation, costing several minutes.

```text
Compiling Main (app/OpenApi.hs) [Flags changed]; subsequent build-with-tests recompiled core modules and test components.
```
