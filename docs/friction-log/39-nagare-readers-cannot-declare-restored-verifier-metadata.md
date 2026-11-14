---
type: Friction Entry
title: "Nagare readers cannot declare restored-verifier metadata"
description: "Nagare reader declarations require an upstream capability extension before the local Kansoku restored-copy ceremony can run with SELECT-only credentials."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-14T00:54:37Z"
frictionId: FRIC-39
status: "resolved"
impact: detour
kind: interface
origin: "mori://shinzui/kansoku"
affects: "mori://shinzui/nagare"
affectedVersion: "0.20.0"
plan: "docs/plans/53-prove-shared-server-maintenance-across-deployment-platforms.md"
workaround: "Implement explicit SELECT-only reader metadata in the canonical Nagare source, retain names-only column observation and revoke removed metadata through review, then qualify against the owned Apple Container local cluster."
tags:
  - "shared-server"
  - "nagare"
resolution: "Nagare source ddaee801c8799a625a5320a0f41a9324da385e4d adds explicit reader metadata with SELECT(name) on system.users; final candidate 8cc5a7792710083092c60c2dc71777186b61a360 passes actual local readonly verification and final grant re-plan."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-14T02:16:02Z"
    change: "Status set to resolved."
---
# Nagare readers cannot declare restored-verifier metadata

## Attempted

Map verify-restored SELECT-only grants into Nagare 0.20.0 app-database reader declarations.

## Encountered

The closed exception list omits names-only system.users inspection and readers have no metadata exception field; manual grants would become undeclared drift.

## Workaround

Implement explicit SELECT-only reader metadata in the canonical Nagare source, retain names-only column observation and revoke removed metadata through review, then qualify against the owned Apple Container local cluster.
