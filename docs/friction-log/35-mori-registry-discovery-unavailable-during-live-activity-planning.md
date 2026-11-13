---
type: Friction Entry
title: "Mori registry discovery unavailable during live activity planning"
description: "The registry could not connect to its local PostgreSQL service, preventing consumer and dependency discovery during planning."
generated:
  by: "codex-cli/gpt-6-astra"
  at: "2026-11-13T18:04:11Z"
frictionId: FRIC-35
status: logged
impact: detour
kind: environment
origin: "mori://shinzui/kansoku"
affects: "mori://shinzui/mori"
plan: "docs/masterplans/8-stream-recent-events-and-page-views-over-websockets.md"
workaround: "Use checked-in Kansoku sources and canonical consumer references already supplied by IR-16; require fresh Mori discovery before choosing dependency APIs or versions."
---
# Mori registry discovery unavailable during live activity planning

## Attempted

mori registry search kansoku-ui; mori registry concepts --search WebSocket --json

## Encountered

NotifierConnectError: local PostgreSQL socket connection refused.

## Workaround

Use checked-in Kansoku sources and canonical consumer references already supplied by IR-16; require fresh Mori discovery before choosing dependency APIs or versions.
