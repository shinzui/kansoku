---
type: Friction Entry
title: "Emulated amd64 image plan exhausts local Docker memory"
description: "The ARM64 Colima Docker host OOM-kills the packaged amd64 CLI before offline plan output, preventing exported-image qualification."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-08T05:06:24Z"
frictionId: FRIC-18
status: "resolved"
impact: blocked
kind: environment
origin: "mori://shinzui/kansoku"
affects: "mori://shinzui/kansoku"
plan: "docs/plans/64-accept-tan-production-as-a-deployment-target.md"
resolution: "Use Apple Container with Rosetta; the same image completes all repeated offline plan probes. Repository instructions forbid future Colima use."
amended:
  - by: "codex-cli/gpt-6.1-sol"
    at: "2026-11-08T05:10:44Z"
    change: "Resolve local image execution through the user-selected Apple Container backend; retain the OOM failures as historical evidence."
---
# Emulated amd64 image plan exhausts local Docker memory

## Attempted

Run check_container_image.py against clean ad644f524d62b0617fba9395fc93374875a748b1 in colima, then diagnose with GHCRTS=-N1

## Encountered

Both native-plan probes exited 137 without stdout; retained diagnostic container State.OOMKilled=true after 4.16 GiB use on a 5.77 GiB Docker host. Native Linux VM smoke passes.

```text
Docker host architecture aarch64; diagnostic ExitCode=137, OOMKilled=true; native Linux build and VM smoke passed.
```
