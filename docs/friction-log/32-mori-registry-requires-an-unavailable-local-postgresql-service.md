---
type: Friction Entry
title: "Mori registry requires an unavailable local PostgreSQL service"
description: "Registry dependency discovery fails because the local Sungkyung PostgreSQL socket refuses connections."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-13T16:19:56Z"
frictionId: FRIC-32
status: logged
impact: detour
kind: environment
origin: "mori://shinzui/kansoku"
affects: "mori://shinzui/mori"
plan: "docs/plans/72-keep-kansoku-starting-and-accepting-events-while-clickhouse-is-unavailable.md"
workaround: "Read checked-in dependency sources and specific local checkouts after attempting Mori; do not change dependency bounds."
---
# Mori registry requires an unavailable local PostgreSQL service

## Attempted

mori registry list; mori registry search servant-health; mori registry search shibuya

## Encountered

NotifierConnectError: local PostgreSQL socket connection refused

## Workaround

Read checked-in dependency sources and specific local checkouts after attempting Mori; do not change dependency bounds.
