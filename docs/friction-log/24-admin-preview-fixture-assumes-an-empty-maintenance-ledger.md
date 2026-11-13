---
type: Friction Entry
title: "Admin preview fixture assumes an empty maintenance ledger"
description: "The aggregate admin acceptance fixture rejects completed jobs left by earlier real-erasure fixtures instead of checking that preview preserves existing state."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-13T01:38:23Z"
frictionId: FRIC-24
status: "resolved"
impact: detour
kind: tooling
origin: "mori://shinzui/kansoku"
affects: "mori://shinzui/kansoku"
plan: "docs/plans/67-read-identified-users-profiles-and-event-history.md"
workaround: "Capture existing ledger counts before preview and assert that preview changes neither count."
resolution: "The admin preview fixture now compares job and disposition counts before and after preview, preserving completed maintenance history from earlier fixtures."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-13T01:50:34Z"
    change: "Make preview acceptance compose with real user-erasure fixtures in the shared owned stores."
---
# Admin preview fixture assumes an empty maintenance ledger

## Attempted

Run the full aggregate acceptance gate after integrating real users erasure checks.

## Encountered

The admin preview assertion required maintenance_jobs and event_dispositions to have zero rows after earlier user erasures had correctly persisted completed jobs.

```text
scripts/admin_acceptance.py:248: assert count(maintenance_jobs) == 0 failed after all users and SDK/browser workflows passed.
```

## Workaround

Capture existing ledger counts before preview and assert that preview changes neither count.
