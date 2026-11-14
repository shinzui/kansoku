---
type: Friction Entry
title: "Constrained readers reject unlimited SDK inspection results"
description: "The actual Nagare reader rejects SDK inspection because its request settings explicitly disable mandatory result ceilings."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-14T01:47:03Z"
frictionId: FRIC-40
status: "resolved"
impact: detour
kind: interface
origin: "mori://shinzui/kansoku"
affects: "mori://shinzui/clickhouse-migrate"
plan: "docs/plans/53-prove-shared-server-maintenance-across-deployment-platforms.md"
workaround: "Implement explicit bounded SELECT-only observation upstream, retaining throwing overflow modes and strict default mutation behavior."
resolution: "SDK source a0bf98efbffbae9def846454deef9164ecadbd9d adds explicit bounded SELECT-only observation with throwing overflow. Constrained success and overflow refusal pass on native candidates; Kansoku actual Nagare restore verification passes under mandatory ceilings."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-14T02:16:03Z"
    change: "Status set to resolved."
---
# Constrained readers reject unlimited SDK inspection results

## Attempted

Use the public history verifier with a readonly Nagare reader.

## Encountered

Code 452 SETTING_CONSTRAINT_VIOLATION: max_result_rows must be at least one; Observe explicitly requests zero.

## Workaround

Implement explicit bounded SELECT-only observation upstream, retaining throwing overflow modes and strict default mutation behavior.
