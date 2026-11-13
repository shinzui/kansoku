---
type: Friction Entry
title: "Mori registry unavailable during users implementation"
description: "The local Mori registry PostgreSQL socket refuses connections, preventing dependency source discovery."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-13T00:29:21Z"
frictionId: FRIC-23
status: "accepted"
impact: detour
kind: environment
origin: "mori://shinzui/kansoku"
affects: "mori://shinzui/mori"
plan: "docs/plans/67-read-identified-users-profiles-and-event-history.md"
workaround: "Use existing repository dependency integration patterns without changing dependency APIs or bounds."
resolution: "Implementation reused existing dependency integration patterns without new APIs or bounds; registry service restoration remains an environment concern."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-13T00:48:39Z"
    change: "Accept the existing-pattern workaround for this plan; no dependency changes require registry access."
---
# Mori registry unavailable during users implementation

## Attempted

mori registry list; mori registry search relay-pagination; mori doctor

## Encountered

PostgreSQL connection refused on the sungkyung-clients socket

## Workaround

Use existing repository dependency integration patterns without changing dependency APIs or bounds.
