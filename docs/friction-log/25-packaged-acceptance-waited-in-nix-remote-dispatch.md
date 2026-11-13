---
type: Friction Entry
title: "Packaged acceptance waited in Nix remote dispatch"
description: "The packaged acceptance Nix build spent over six minutes without observable compiler activity before a local-only retry made progress."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-13T02:06:49Z"
frictionId: FRIC-25
status: "accepted"
impact: detour
kind: environment
origin: "mori://shinzui/kansoku"
affects: "https://github.com/NixOS/nix"
plan: "docs/plans/68-select-identified-users-in-metric-queries.md"
workaround: "Retry the unchanged acceptance command with a per-process NIX_CONFIG builders override disabling remote builders; keep all packaged acceptance assertions."
resolution: "Use a per-invocation local-builder override for this acceptance run; no project or machine builder configuration changes are required."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-13T02:09:58Z"
    change: "Local compilation progressed with remote builders disabled; retain the observation without claiming an upstream Nix defect."
---
# Packaged acceptance waited in Nix remote dispatch

## Attempted

nix develop --no-write-lock-file -c just acceptance

## Encountered

The captured build stayed at package build announcements while the remote build helper had no visible compiler child; the agent interrupted that attempt.

```text
nix-daemon __build-remote remained present for over six minutes; local-only retry showed an active GHC compiler within thirty seconds.
```

## Workaround

Retry the unchanged acceptance command with a per-process NIX_CONFIG builders override disabling remote builders; keep all packaged acceptance assertions.
