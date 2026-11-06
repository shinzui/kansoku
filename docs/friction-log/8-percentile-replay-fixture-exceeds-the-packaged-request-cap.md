---
type: Friction Entry
title: "Percentile replay fixture exceeds the packaged request cap"
description: "The existing percentile replay sends its complete sample population in one batch despite the packaged 4 KiB cap, blocking full acceptance after acquisition HTTP succeeds."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-06T13:31:22Z"
frictionId: FRIC-8
status: "resolved"
impact: detour
kind: tooling
origin: "mori://shinzui/kansoku"
affects: "mori://shinzui/kansoku"
plan: "docs/plans/56-attribute-conversions-to-first-touch-acquisition.md"
workaround: "Replay the identical reversed sample population in batches of three, matching its initial delivery and preserving all assertions and the server request cap."
resolution: "The percentile fixture now replays the same reversed population in three-event batches; packaged fixture isolation passed both full repetitions and both injected failure scenarios within the 4 KiB request cap."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-06T13:39:50Z"
    change: "Resolve the oversized replay fixture after packaged public acceptance verifies all preserved assertions"
---
# Percentile replay fixture exceeds the packaged request cap

## Attempted

Run nix develop --no-write-lock-file -c just acceptance through its existing custom metric fixture-isolation workflow.

## Encountered

scripts/custom_metrics_acceptance.py line 157 sends every reversed sample row together and receives HTTP 413 Request Entity Too Large.

```text
urllib.error.HTTPError: HTTP Error 413: Request Entity Too Large at send(base, write_key, list(reversed(sample_rows)))
```

## Workaround

Replay the identical reversed sample population in batches of three, matching its initial delivery and preserving all assertions and the server request cap.
