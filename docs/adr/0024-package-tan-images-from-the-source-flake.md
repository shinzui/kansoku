---
type: Architecture Decision Record
title: Package TAN images from the source flake
description: Build independently pinned TAN images from Kansoku's own package closure while retaining the proven Labs entrypoint and keeping deployment acceptance separate.
docId: ADR-24
status: Accepted
date: 2026-11-02
timestamp: 2026-11-02T04:15:00Z
originatingPlan: mori://tan/tan-app-infrastructure/plans/42-qualify-kansoku-artifacts-and-the-staging-clickhouse-contract
generated:
  by: process:codex
  at: 2026-11-02T04:15:00Z
---

# Package TAN images from the source flake

## Context

The existing Linux image in `mori://tan/tan-ng-labs` is pinned for its own service.
Staging needs the verified TLS runtime and independently qualified native library,
without moving the Labs source pin or reusing its migration identities. A separate
Docker compilation path would duplicate dependency choices already fixed by the
source flake.

## Decision

Expose `packages.x86_64-linux.kansoku-image` from the source flake, built with the
same `kansoku-server` derivation as the operator tools. Reuse the Labs
`dockerTools.buildLayeredImage` layout: all four executables, BusyBox, a CA bundle,
a writable temporary directory, and `/entrypoint.sh` with `kansoku-server` as the
default command. Preserve the mapping of generic database variables to Kansoku's
names; explicit Kansoku variables take precedence. Native TLS remains an explicit
selector and port under [ADR-23](0023-verified-tls-for-native-clickhouse-connections.md).

Use `gcr.io/tan-ng/kansoku`, a source-revision tag with packaging revision `p1`, and
OCI source/revision labels. A publishable build must come from a clean immutable
commit; `uncommitted` artifacts are development outputs. Changes to packaging are
committed alongside source, so the image retains one exact source and recipe identity.
Published tags are immutable; deployment references the registry digest.

The Linux image smoke test boots the image in its own Docker VM without host
mounts, checks all four executable paths, the embedded plan, CA bundle and complete
environment mapping including explicit TLS values. It is required packaging proof,
not migration, managed endpoint or event-flow acceptance. Those gates remain under
[ADR-22](0022-explicit-clickhouse-migrations-and-persistent-administrative-sessions.md)
and the originating staging plan.

## Validation

On 2026-11-02, both the Linux amd64 image build and the owned NixOS Docker VM
smoke test passed on the configured Linux builder. The actual image executed its
embedded 25-migration plan, supplied all four executable paths, retained explicit
TLS/port variables and explicit credential overrides, rejected a missing required
mapping, and contained the configured CA bundle. This used the development image
tag while authoring the recipe; a clean source revision and final qualified native
dependency must be built again before immutable publication. No image was published
by this check.

## Consequences

Staging can build and publish a corrected image without changing Labs. The image
contains no database password, server UUID, ledger/session identity or environment
binding. Operators must supply the independently retained native operation inputs
and select a supported target. Serving-only rollouts must preserve completed
migration image/operation inputs under the downstream deployment contract.
