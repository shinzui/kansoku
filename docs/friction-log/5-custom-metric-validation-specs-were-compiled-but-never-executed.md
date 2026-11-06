---
type: Friction Entry
title: "Custom metric validation specs were compiled but never executed"
description: "The explicit Hspec runner omitted CustomSpec, so deterministic checks passed without running the advertised custom-definition tests."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-06T12:38:06Z"
frictionId: FRIC-5
status: "resolved"
impact: detour
kind: tooling
origin: "mori://shinzui/kansoku"
affects: "mori://shinzui/kansoku"
plan: "docs/plans/55-add-percentile-aggregation-to-custom-metrics.md"
workaround: "Register CustomSpec in the explicit Hspec runner, rebuild, and require its examples in the deterministic transcript."
resolution: "CustomSpec is registered in the Hspec runner and all eight custom metric examples now execute in the deterministic gate."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-06T12:41:13Z"
    change: "Registered the omitted custom metric test group and verified it in the passing deterministic transcript."
---
# Custom metric validation specs were compiled but never executed

## Attempted

Run nix develop -c just deterministic-test and inspect the percentile examples.

## Encountered

CustomSpec was listed in the Cabal test modules but absent from test/Spec.hs imports and normalTests; the suite reported no Custom metrics examples.

```text
475 examples, 0 failures; no Custom metrics group in the transcript
```

## Workaround

Register CustomSpec in the explicit Hspec runner, rebuild, and require its examples in the deterministic transcript.
