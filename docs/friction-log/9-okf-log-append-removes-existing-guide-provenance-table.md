---
type: Friction Entry
title: "OKF log append removes existing guide provenance table"
description: "The okf log add command rewrote existing history and removed the guide migration provenance table, requiring restoration around the generated new entry."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-06T13:55:08Z"
frictionId: FRIC-9
status: "accepted"
impact: detour
kind: tooling
origin: "mori://shinzui/kansoku"
affects: "mori://shinzui/okf"
plan: "docs/plans/57-declare-client-error-and-web-vital-events.md"
workaround: "Preserved the command-generated entry and restored the prior history and table from HEAD."
resolution: "Preserve existing log prose and adoption tables around generated appends; upstream log rewrite work is outside this event-contract change."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-06T13:57:17Z"
    change: "Accept the documented preservation workaround, as also required by FRIC-7 in a previous plan"
---
# OKF log append removes existing guide provenance table

## Attempted

okf log add docs/guides -m DOC-11-update

## Encountered

The command appended the requested entry but dropped the existing Markdown provenance table from log.md.

```text
git diff showed removal of the guide migration table after okf log add.
```

## Workaround

Preserved the command-generated entry and restored the prior history and table from HEAD.
