---
type: Friction Entry
title: "OKF log append drops preserved prose and tables"
description: "Appending bundle log entries with okf log add removed the existing guide provenance table and whitespace, requiring restoration around the new entries."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-08T05:48:21Z"
frictionId: FRIC-20
status: "accepted"
impact: detour
kind: tooling
origin: "mori://shinzui/kansoku"
affects: "mori://shinzui/okf"
plan: "docs/plans/65-stop-counting-client-errors-and-web-vitals-as-session-engagement.md"
workaround: "Keep the generated new entries and restore every preexisting byte from the clean working-tree baseline"
resolution: "Preserve all existing bundle log bytes around generated append entries; retain the known log-writer limitation rather than changing the documentation tool during this implementation."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-08T06:06:53Z"
    change: "Accept the local preservation workaround; this occurrence repeats the log-writer behavior recorded in FRIC-3."
---
# OKF log append drops preserved prose and tables

## Attempted

Run okf log add docs/guides DOC-10 -m to record a meaningful guide revision

## Encountered

The writer regenerated the log and omitted the existing adoption evidence table

## Workaround

Keep the generated new entries and restore every preexisting byte from the clean working-tree baseline
