---
type: Friction Entry
title: "Read-only native inspection requires settings-compatible credentials"
description: "The public toolkit sets synchronous bounded query settings even for observation, so readonly=1 rejected the first probe and required a separately constrained readonly=2 role."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-13T20:52:14Z"
frictionId: FRIC-38
status: "resolved"
impact: detour
kind: interface
origin: "mori://shinzui/kansoku"
affects: "mori://shinzui/clickhouse-migrate/packages/clickhouse-migrate"
plan: "docs/plans/52-verify-renamed-clickhouse-restores-without-writes.md"
workaround: "Use readonly=2 with exact SELECT grants, independently assert temporary writes are denied, and capture every request to prove inspection attempts no writes."
resolution: "Qualified readonly=2 with exact SELECT grants, independent temporary-write denial and captured SELECT-only inspection; the verifier guide records the transport setting requirement."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-13T21:23:46Z"
    change: "Owned renamed current and prefix restores and all schema drift cases pass under the constrained role."
---
# Read-only native inspection requires settings-compatible credentials

## Attempted

Inspect a genuinely renamed ledger through the public Observe API with a SELECT-only readonly=1 account.

## Encountered

ClickHouse rejected the initial server probe before ledger reads because the transport sets async_insert.

```text
Code 164: Cannot modify 'async_insert' setting in readonly mode.
```

## Workaround

Use readonly=2 with exact SELECT grants, independently assert temporary writes are denied, and capture every request to prove inspection attempts no writes.
