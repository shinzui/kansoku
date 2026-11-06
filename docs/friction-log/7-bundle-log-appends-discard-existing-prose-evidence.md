---
type: Friction Entry
title: "Bundle log appends discard existing prose evidence"
description: "okf log add rewrote the guides log and removed its adoption provenance table, requiring preservation of the original body."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-06T13:17:43Z"
frictionId: FRIC-7
status: "accepted"
impact: detour
kind: tooling
origin: "mori://shinzui/kansoku"
affects: "mori://shinzui/okf"
plan: "docs/plans/56-attribute-conversions-to-first-touch-acquisition.md"
workaround: "Restored the committed log bodies and inserted only this plans new entries, preserving all prior evidence."
resolution: "Preserve original log bodies when appending generated records; the CLI rewrite behavior is outside the acquisition feature scope."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-06T13:19:05Z"
    change: "Retain all prior prose evidence and accept a preservation step around log appends"
---
# Bundle log appends discard existing prose evidence

## Attempted

Append DOC-10 and ADR update records with okf log add as prescribed by the plan skill.

## Encountered

The command normalized spacing and removed the guides adoption provenance table from the existing log.

```text
git diff docs/guides/log.md showed deletion of the adoption evidence table after okf log add.
```

## Workaround

Restored the committed log bodies and inserted only this plans new entries, preserving all prior evidence.
