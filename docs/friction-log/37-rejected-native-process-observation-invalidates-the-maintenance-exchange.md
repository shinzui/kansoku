---
type: Friction Entry
title: "Rejected native process observation invalidates the maintenance exchange"
description: "Reusing the native connection after a denied process-list query caused the following maintenance exchange to fail, requiring separate diagnostic connections."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-13T18:47:00Z"
frictionId: FRIC-37
status: logged
impact: detour
kind: interface
origin: "mori://shinzui/kansoku"
affects: "mori://KovalevDima/ClickHaskell/packages/ClickHaskell"
plan: "docs/plans/50-accept-portable-drain-evidence-without-cross-user-process-visibility.md"
workaround: "Open and close dedicated native connections for supplementary process observations; keep maintenance connections separate."
---
# Rejected native process observation invalidates the maintenance exchange

## Attempted

Run portable retention resume with SELECT on system.processes denied, then verify native mutations on the same connection.

## Encountered

The process query was denied as expected, but the subsequent native mutation verification exchange also failed.

```text
Owned run .dev/acceptance/portable-drain-u_9mf4w9/prepared-job/command-23.private: verify mutations direct: native exchange failed; details redacted; maintenance fence retained
```

## Workaround

Open and close dedicated native connections for supplementary process observations; keep maintenance connections separate.
