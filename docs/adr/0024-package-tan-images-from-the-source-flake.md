---
type: Architecture Decision Record
title: Package TAN images from the source flake
description: Build independently pinned TAN images from Kansoku's own package closure while retaining the proven Labs entrypoint and keeping deployment acceptance separate.
docId: ADR-24
status: Accepted
date: 2026-11-02
timestamp: 2026-11-13T16:39:00Z
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
Published tags are immutable; deployment references the registry digest. A native
`kansoku-image-stream` app exports the exact Linux producer's arguments and closure
on Darwin or Linux into a normal artifact file. Keep archive configuration digests,
Docker's loaded image IDs and registry manifest digests under distinct field names;
Docker may normalize legacy archive configuration while loading it. The exported-image
checker binds the loaded filesystem layers/configuration before invoking its recorded ID.

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
by this check. With the qualified `0.1.0.1` source pin, the Linux image/VM and Darwin
server builds pass, preserved-time embedding remains content-qualified, and ten extracted
workspace/source-repository archives build the production CLI with all 25/257 embedded
steps after withholding SQL inputs. The native exporter also receives a separate,
network-disabled Docker smoke check against the actual exported artifact before publication.

## Consequences

Staging can build and publish a corrected image without changing Labs. The image
contains no database password, server UUID, ledger/session identity or environment
binding. Operators must supply the independently retained native operation inputs
and select a supported target. Serving-only rollouts must preserve completed
migration image/operation inputs under the downstream deployment contract.

## Production release contract

Plan 64 retains direct, replicated and PostgreSQL offline stdout separately and
hashes their exact bytes, including final newlines. The eight-field TAN production
record maps its native hash to the replicated history; the image report preserves
the direct hash under its existing name. Prepared artifacts use a null image and
cannot identify a qualified deployment. Final artifacts require a registry manifest
digest, retained readback evidence and all prerequisite/owner gate dispositions.
No model-authored dossier accepts release risk. Decisions bind the preserved clean
candidate archive and image ID before publication, then the verified registry digest.
Evidence commits follow candidate source commits and do not trigger a rebuild of
the already tested content. The selected managed target has dated release-owner acceptance of its residual
risks; local fixture qualification continues to describe its actual platform scope.

On macOS the user-selected runtime is Apple Container; Colima is forbidden by
`AGENTS.md`. Its Rosetta smoke path converts the normal exported archive to OCI,
compares loaded configuration/layers, creates each isolated container, verifies
its recorded image descriptor, then starts it. Its local OCI index digest is
identified explicitly and is not called a Docker ID or published registry receipt.
Rosetta execution remains emulated. Historical Docker receipts retain their original
platform and do not prescribe future macOS execution.

## Recorded production release disposition

On 2026-11-08 the requesting release owner explicitly approved the four documented
startup, patch/security-source, Linux application-image coverage and managed-endpoint
risks. The [decision record](../evidence/tan-production-release-decision.md) retains
the participant identity, actual approval, UTC date, reasons and immutable candidate
binding. The [qualified artifact](../evidence/tan-production-qualified-artifact.json)
is published and readback verified. Acceptance is target-specific: it does not
certify provider routing or claim full replicated execution inside the amd64 image.
TAN still owns independent production inventory, storage/fsync, grants, drain and
managed migration/event-flow rehearsal. Publication performs no database migration.

## Released migration cohorts

Retain historical commit-based toolkit evidence unchanged. New release candidates may
record `cabalToolkitRelease` and `nixToolkitRelease` instead of source-commit fields.
The validator requires the same four-part release in both fields and verifies all four
migration packages in the committed Cabal constraints and Nix Hackage declarations.
Mixing commit and release identities is refused. The eight-field deployment mapping
uses a version-qualified canonical release URI for `upstreamImplementation`, while
historical records continue to carry their original commit. Retain authoritative
registry and upstream-tag observations with the candidate; a lagging local registry
cannot establish release identity. This changes evidence representation without
rewriting historical owner decisions or transferring them to a new candidate.
