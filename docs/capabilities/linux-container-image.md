---
type: Capability
title: "Source-built Linux container image"
description: "Build a Linux amd64 image of the Kansoku executables from the source flake with provenance labels, embedded migration plans and a smoke check."
timestamp: 2026-11-11T16:18:51Z
generated:
  by: process:claude-code
  at: "2026-11-11T16:18:51Z"
capabilityId: CAP-21
provider: mori://shinzui/kansoku
status: shipped
stability: experimental
since: unreleased
packages:
  - "kansoku-server"
interface:
  - ".#packages.x86_64-linux.kansoku-image"
  - ".#checks.x86_64-linux.kansoku-image-smoke"
  - ".#kansoku-image-stream"
tags: [operations]
requires:
  - CAP-20
evidence:
  - kind: conformance
    resource: "scripts/check_container_image.py"
    proves: "Checks an exported image's labels, layout, environment mapping and embedded plan outputs without database access."
  - kind: guide
    resource: "docs/guides/container-image.md"
    proves: "Specifies clean-tree builds, export, inspection, immutable-tag publication and release evidence."
  - kind: guide
    resource: "docs/adr/0024-package-tan-images-from-the-source-flake.md"
    proves: "Records the decision to package images from the source flake."
---

# Source-built Linux container image

Package the server, PostgreSQL migration, ClickHouse migration and administration executables into a Linux amd64 image from the source flake, labelled with the full source revision. A VM smoke check boots the actual image; an exported archive can be qualified locally with Apple Container and compared against its embedded migration plans. The entrypoint maps common database variables onto Kansoku's explicit names, with explicit values winning. See [the container image guide](../guides/container-image.md).

## Compatibility

Available in the current checkout. No release tags establish a released version, so since is unreleased. This experimental interface has no stable compatibility promise; pin the server and clients to a reviewed revision and regenerate contracts together.

## Limits

Only Linux amd64 is built. A dirty tree receives a development-only tag; publish only previously unused immutable tags. The image carries no credentials, data or migration identities. The current tag, layout and release dossier follow one adopter's deployment contract; build and smoke success do not establish database compatibility or deployment readiness, so each environment must rehearse migrations, TLS, queries and recovery before rollout.

## Requires

- [CAP-20 — Explicit ClickHouse migrations](explicit-clickhouse-migrations.md).

## Evidence

- [check_container_image.py](../../scripts/check_container_image.py) — Checks an exported image's labels, layout, environment mapping and embedded plan outputs without database access.
- [container-image.md](../../docs/guides/container-image.md) — Specifies clean-tree builds, export, inspection, immutable-tag publication and release evidence.
- [0024-package-tan-images-from-the-source-flake.md](../../docs/adr/0024-package-tan-images-from-the-source-flake.md) — Records the decision to package images from the source flake.
