---
type: Friction Entry
title: "Embedded migration build recompiles the graph for calendar query checks"
description: "The required build-with-tests wrapper forces full dependency and application recompilation even for query-only changes."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-13T14:06:17Z"
frictionId: FRIC-29
status: "accepted"
impact: slowdown
kind: tooling
origin: "mori://shinzui/kansoku"
affects: "mori://shinzui/clickhouse-migrate"
plan: "docs/plans/70-measure-retention-by-calendar-period-with-separate-start-and-return-events.md"
workaround: "Used ordinary focused Cabal builds during iteration and retained the required wrapper for the final gate."
resolution: "Kept focused Cabal iteration and paid the required final wrapper cost; build-wrapper optimization is separate work."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-13T14:09:55Z"
    change: "Accept the required gate recompilation cost."
---
# Embedded migration build recompiles the graph for calendar query checks

## Attempted

just check, whose build-with-tests prerequisite invokes clickhouse-migrate-embed-build

## Encountered

The wrapper applied global -fforce-recomp and migration fingerprint GHC flags, recompiling ClickHaskell, API, core, server and tests.

## Workaround

Used ordinary focused Cabal builds during iteration and retained the required wrapper for the final gate.
