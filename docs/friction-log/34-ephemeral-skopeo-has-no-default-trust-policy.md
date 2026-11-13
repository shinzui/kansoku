---
type: Friction Entry
title: "Ephemeral Skopeo has no default trust policy"
description: "Archive conversion through the pinned Nix Skopeo package fails because this host has no policy.json."
generated:
  by: "codex-cli/gpt-6.1-sol"
  at: "2026-11-13T16:59:10Z"
frictionId: FRIC-34
status: logged
impact: detour
kind: environment
origin: "mori://shinzui/kansoku"
affects: "https://github.com/containers/skopeo"
plan: "docs/plans/72-keep-kansoku-starting-and-accepting-events-while-clickhouse-is-unavailable.md"
workaround: "Use --insecure-policy only for local archive conversion, then independently compare the loaded configuration and layer hashes in the image checker."
---
# Ephemeral Skopeo has no default trust policy

## Attempted

skopeo copy docker-archive:image.tar oci-archive:image.oci.tar from the pinned Nix package

## Encountered

Error loading trust policy: no policy.json file found

```text
Searched the standard user, /etc/containers and /usr/share/containers policy locations.
```

## Workaround

Use --insecure-policy only for local archive conversion, then independently compare the loaded configuration and layer hashes in the image checker.
