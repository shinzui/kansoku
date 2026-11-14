---
type: Friction Entry
title: "Nagare reader scopes cannot name completed scratch restores"
description: "The reviewed restore creates scratch databases, but app reader validation cannot select them without trying to enroll existing unmanaged storage."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-14T01:54:10Z"
frictionId: FRIC-41
status: "resolved"
impact: detour
kind: interface
origin: "mori://shinzui/kansoku"
affects: "mori://shinzui/nagare"
affectedVersion: "0.20.0"
plan: "docs/plans/53-prove-shared-server-maintenance-across-deployment-platforms.md"
workaround: "Add an explicit restored relation tied to this app, namespace, scratch target and current accepted server revision, without enrolling restored storage."
resolution: "Nagare source 6b3a7dd390b29372608bb19603a33c71c5b62ac0 adds accepted scratch relations; 8cc5a7792710083092c60c2dc71777186b61a360 observes those exact databases. The full fresh local ceremony passes with no manual grants or storage adoption."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-14T02:16:04Z"
    change: "Status set to resolved."
---
# Nagare reader scopes cannot name completed scratch restores

## Attempted

Declare a SELECT-only verifier after the actual reviewed three-store restore.

## Encountered

Reader objects outside the app logical database set refuse; adding restored names then refuses adoption-required, and database member adoption is deliberately unsupported.

## Workaround

Add an explicit restored relation tied to this app, namespace, scratch target and current accepted server revision, without enrolling restored storage.
