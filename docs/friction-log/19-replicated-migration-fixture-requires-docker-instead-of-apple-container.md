---
type: Friction Entry
title: "Replicated migration fixture requires Docker instead of Apple Container"
description: "The dependency owned fixture hardcodes Docker, requiring a local Apple Container fixture to run the mandated replica acceptance."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-08T05:36:11Z"
frictionId: FRIC-19
status: "resolved"
impact: detour
kind: tooling
origin: "mori://shinzui/kansoku"
affects: "mori://shinzui/clickhouse-migrate"
plan: "docs/plans/65-stop-counting-client-errors-and-web-vitals-as-session-engagement.md"
workaround: "Provide a repository-owned Apple Container fixture preserving the exact qualified image, settings, replica inventory and CLI scenarios"
resolution: "The migration gate now uses a repository-owned Apple Container fixture with the exact qualified Linux arm64 image, retained evidence, full replica identities and 4 GiB per replica; its full native query and retained-upgrade paths pass without Docker."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-08T06:41:39Z"
    change: "Remove the Docker-specific dependency fixture from the migration execution path while preserving actual coverage and refusal behavior."
---
# Replicated migration fixture requires Docker instead of Apple Container

## Attempted

Run just ch-migrations-replicated on the required local Apple Container runtime

## Encountered

The dependency fixture requires CLICKHOUSE_MIGRATE_DOCKER_CONTEXT and invokes docker for every lifecycle operation

## Workaround

Provide a repository-owned Apple Container fixture preserving the exact qualified image, settings, replica inventory and CLI scenarios
