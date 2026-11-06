---
type: Friction Entry
title: "OKF log append removes existing guide provenance prose"
description: "The log appender rewrote historical guide log content and dropped the adoption provenance table, requiring restoration."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-06T04:11:20Z"
frictionId: FRIC-1
status: "accepted"
impact: detour
kind: tooling
origin: "mori://shinzui/kansoku"
affects: "mori://shinzui/okf"
plan: "docs/plans/58-classify-ai-assistant-referrals-as-a-channel.md"
workaround: "Preserved the generated new entry and restored original historical log bytes from HEAD."
resolution: "Preserve historical prose after log appends until the upstream log serializer retains non-entry Markdown."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-06T04:12:16Z"
    change: "Accepted the local restoration workaround; the tool limitation remains upstream."
---
# OKF log append removes existing guide provenance prose

## Attempted

okf log add docs/guides DOC-12 --message <guide revision>

## Encountered

The new entry was added, but the existing historical Markdown provenance table was deleted.

```text
git diff docs/guides/log.md showed deletion of the adoption evidence table.
```

## Workaround

Preserved the generated new entry and restored original historical log bytes from HEAD.
