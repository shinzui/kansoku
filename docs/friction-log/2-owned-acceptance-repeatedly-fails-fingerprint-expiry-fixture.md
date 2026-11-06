---
type: Friction Entry
title: "Owned acceptance repeatedly fails fingerprint expiry fixture"
description: "The unchanged native identity cache fixture failed twice before packaged AI reporting could run, requiring diagnosis of its expiry boundary."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-06T04:31:14Z"
frictionId: FRIC-2
status: "resolved"
impact: detour
kind: tooling
origin: "mori://shinzui/kansoku"
affects: "mori://shinzui/kansoku"
plan: "docs/plans/58-classify-ai-assistant-referrals-as-a-channel.md"
workaround: "Investigate the fixture clock boundary before proceeding with the full owned gate."
resolution: "Pin owned ClickHouse servers to UTC: host Pacific DST made now64 minus 180 calendar days disagree with UTC fixture arithmetic by one hour."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-06T04:34:22Z"
    change: "Make the owned test server timezone explicit to match UTC schema timestamps and expiry fixtures."
---
# Owned acceptance repeatedly fails fingerprint expiry fixture

## Attempted

just acceptance on two fresh owned stacks

## Encountered

Both runs failed Kansoku.Identity.Cache native at CacheSpec.hs:89, expecting anonymous:F but receiving user:FP after the five-second wait.

```text
589 examples, 1 failure on the corrected candidate; the new enrichment native case passed.
```

## Workaround

Investigate the fixture clock boundary before proceeding with the full owned gate.
