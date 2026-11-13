---
type: Friction Entry
title: "OKF log append rewrites retained guide history during retention work"
description: "Updating bundle logs normalized prior entries and discarded guide adoption prose, requiring preservation of historical bytes."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-13T14:04:06Z"
frictionId: FRIC-28
status: "accepted"
impact: detour
kind: tooling
origin: "mori://shinzui/kansoku"
affects: "mori://shinzui/kansoku"
plan: "docs/plans/70-measure-retention-by-calendar-period-with-separate-start-and-return-events.md"
workaround: "Captured each original log, retained the CLI-generated new entry, and restored all historical prose and bytes."
resolution: "Retained all historical log bytes while appending generated entries; changing the shared log writer is outside this plan."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-13T14:09:55Z"
    change: "Accept the preserving append workaround."
---
# OKF log append rewrites retained guide history during retention work

## Attempted

okf log add docs/guides --message calendar-retention-contract-update

## Encountered

The log writer rewrote old spacing and removed content outside parsed log entries.

## Workaround

Captured each original log, retained the CLI-generated new entry, and restored all historical prose and bytes.
