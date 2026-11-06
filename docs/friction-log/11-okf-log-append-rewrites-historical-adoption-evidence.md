---
type: Friction Entry
title: "OKF log append rewrites historical adoption evidence"
description: "The OKF log append command discarded the guides adoption snapshot table and rewrote unrelated old entries, requiring restoration of the retained history."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-06T14:28:45Z"
frictionId: FRIC-11
status: "accepted"
impact: detour
kind: tooling
origin: "mori://shinzui/kansoku"
affects: "mori://shinzui/okf"
plan: "docs/plans/59-filter-and-group-events-by-their-session-attributes.md"
workaround: "Restore existing log bytes from HEAD and insert only the new generated entry under the existing date heading."
resolution: "Preserve existing log bytes and adoption inventories when adding entries; the upstream OKF log parser is outside this query feature."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-06T14:35:58Z"
    change: "Accept byte-preserving local log edits as the current workaround and retain the original adoption evidence."
---
# OKF log append rewrites historical adoption evidence

## Attempted

Run okf log add docs/guides and docs/adr for the session-attribute contract updates.

## Encountered

The guides log lost its migration inventory table and both logs had unrelated formatting and escaping changes.

## Workaround

Restore existing log bytes from HEAD and insert only the new generated entry under the existing date heading.
