---
type: Friction Entry
title: "OKF log updates discard adoption evidence outside parsed entries"
description: "Updating the guide bundle log rewrote old history and removed its adoption-provenance table, requiring restoration from Git before completion."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-08T02:31:03Z"
frictionId: FRIC-14
status: "accepted"
impact: detour
kind: tooling
origin: "mori://shinzui/kansoku"
affects: "mori://shinzui/okf"
plan: "docs/plans/62-run-clickhouse-migrations-on-a-replicated-cluster.md"
workaround: "Keep the entry emitted by okf log add, restore all previous log bytes from Git, and rerun strict profile/log validation."
resolution: "Preserve the generated new entry and restore prior log bytes before strict validation, as for the earlier FRIC-11 occurrence; the upstream log parser remains outside this migration plan."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-08T02:31:32Z"
    change: "Restore the complete guide adoption inventory and accept byte-preserving log updates as the recurring workaround."
  - by: process:codex
    at: "2026-11-08T03:36:19Z"
    change: "Link consolidated upstream BUG-2 and preview improvement IR-15; retain the accepted local workaround."
---
# OKF log updates discard adoption evidence outside parsed entries

## Attempted

okf log add docs/guides DOC-13 -m replicated-migration-update

## Encountered

The log writer retained parsed entries but dropped the existing adoption paragraph and provenance table.

```text
git diff docs/guides/log.md showed the adoption-evidence table removed alongside the new 2026-11-08 entry.
```

## Workaround

Keep the entry emitted by okf log add, restore all previous log bytes from Git, and rerun strict profile/log validation.

## Upstream follow-up

Tracked with the other occurrences in
`mori://shinzui/okf/okf/bug-reports/concepts/BUG-2` (adoption evidence lost during
log additions) and
`mori://shinzui/okf/okf/improvement-requests/concepts/IR-15` (preview the exact edit
before writing). The local workaround remains accepted; the upstream bug is
confirmed and the improvement is proposed, with neither implemented yet.
