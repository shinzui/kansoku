---
type: Friction Entry
title: "Mori registry unavailable during calendar retention implementation"
description: "The local Mori PostgreSQL socket refused registry connections during dependency and reference discovery."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-13T13:57:04Z"
frictionId: FRIC-27
status: "accepted"
impact: nuisance
kind: environment
origin: "mori://shinzui/kansoku"
affects: "mori://shinzui/mori"
plan: "docs/plans/70-measure-retention-by-calendar-period-with-separate-start-and-return-events.md"
workaround: "No dependency changes are required; repository-owned implementation and existing APIs supply the needed context."
resolution: "The registry outage is external to retention; no dependency changes were needed and unresolved external references remain explicitly qualified."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-13T14:09:54Z"
    change: "Accept registry availability boundary for this plan."
---
# Mori registry unavailable during calendar retention implementation

## Attempted

mori registry list

## Encountered

The registered PostgreSQL socket refused connections.

```text
NotifierConnectError: connection to .s.PGSQL.5432 failed: Connection refused
```

## Workaround

No dependency changes are required; repository-owned implementation and existing APIs supply the needed context.
