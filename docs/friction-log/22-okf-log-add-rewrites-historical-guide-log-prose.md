---
type: Friction Entry
title: "OKF log add rewrites historical guide log prose"
description: "The log-update CLI normalized historical spacing and removed the guide provenance table while appending one entry."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-08T13:53:50Z"
frictionId: FRIC-22
status: "accepted"
impact: detour
kind: tooling
origin: "mori://shinzui/kansoku"
affects: "mori://shinzui/okf"
plan: "docs/plans/66-count-sessions-that-contain-an-event.md"
workaround: "Preserved the emitted new entry and restored all historical log content from the clean starting HEAD."
resolution: "Preserve historical log prose when using the released append command; the intended new entry and strict validation succeeded after restoring that prose."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-08T13:58:11Z"
    change: "Accepted the manual preservation workaround for this implementation; changing the external OKF CLI is outside plan 66."
---
# OKF log add rewrites historical guide log prose

## Attempted

okf log add docs/guides -m DOC-10 update

## Encountered

The new entry was written, but the existing migration provenance table was deleted and historical blank lines were collapsed.

```text
git diff --stat: docs/guides/log.md | 33 +-----
```

## Workaround

Preserved the emitted new entry and restored all historical log content from the clean starting HEAD.
