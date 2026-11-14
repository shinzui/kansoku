---
type: Friction Entry
title: "Strict capability validation lacks baseline review provenance"
description: "The stricter capability audit requires review records absent from every baseline capability page, while the repository-required capability recipe passes."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-14T02:31:49Z"
frictionId: FRIC-42
status: "accepted"
impact: detour
kind: process
origin: "mori://shinzui/kansoku"
affects: "mori://shinzui/kansoku"
affectedVersion: "unreleased"
plan: "docs/plans/53-prove-shared-server-maintenance-across-deployment-platforms.md"
workaround: "Retain the required recipe result and the stricter failed audit separately; do not invent retrospective reviewer attestations or expand this implementation into a bundle-wide provenance rewrite."
resolution: "The project-required capability validation passes. The optional stricter audit remains blocked by baseline review metadata; exact failure evidence is retained, and no review provenance was fabricated."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-14T02:31:50Z"
    change: "Status set to accepted."
---
# Strict capability validation lacks baseline review provenance

## Attempted

Run okf validate docs/capabilities --strict with the pinned profile and log enforcement.

## Encountered

All 21 pre-existing capability pages lack the profile-recommended reviews field, including unchanged pages; the documented capabilities-check recipe passes without strict.

## Workaround

Retain the required recipe result and the stricter failed audit separately; do not invent retrospective reviewer attestations or expand this implementation into a bundle-wide provenance rewrite.
