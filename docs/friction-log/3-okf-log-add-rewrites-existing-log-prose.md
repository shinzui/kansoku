---
type: Friction Entry
title: "OKF log add rewrites existing log prose"
description: "The OKF log writer dropped historical prose and reformatted unrelated entries while adding an implementation entry."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-06T05:06:21Z"
frictionId: FRIC-3
status: "accepted"
impact: detour
kind: tooling
origin: "mori://shinzui/kansoku"
affects: "mori://shinzui/okf"
plan: "docs/plans/60-count-unique-users-over-a-whole-query-range.md"
workaround: "Restored each log from HEAD and inserted only the new entry, preserving historical evidence."
resolution: "Preserve historical log prose when the current OKF writer rewrites it; retain only the intended entry from its output."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-06T05:11:07Z"
    change: "Accepted log writer limitation with preservation workaround"
---
# OKF log add rewrites existing log prose

## Attempted

okf log add docs/guides -m DOC-10...

## Encountered

Existing adoption evidence table disappeared from docs/guides/log.md.

## Workaround

Restored each log from HEAD and inserted only the new entry, preserving historical evidence.
