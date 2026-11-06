---
type: Friction Entry
title: "Focused acceptance helper discards ownership query output"
description: "The owned custom acceptance harness failed before server startup because its command helper returned None."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-06T05:08:03Z"
frictionId: FRIC-4
status: "resolved"
impact: detour
kind: tooling
origin: "mori://shinzui/kansoku"
affects: "mori://shinzui/kansoku"
plan: "docs/plans/60-count-unique-users-over-a-whole-query-range.md"
workaround: "Return captured stdout after checking the subprocess exit code."
resolution: "The command helper now returns stdout after checking the exit code, allowing the owned database check to run."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-06T05:11:07Z"
    change: "Fixed focused acceptance command output handling"
---
# Focused acceptance helper discards ownership query output

## Attempted

nix develop -c just custom-metrics-acceptance

## Encountered

cohorts_acceptance.py called strip on the None result of the run helper.

```text
AttributeError: 'NoneType' object has no attribute 'strip'
```

## Workaround

Return captured stdout after checking the subprocess exit code.
