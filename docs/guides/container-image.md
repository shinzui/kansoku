---
type: Guide
title: Build the TAN container image
description: Build and inspect the immutable Linux image and retain its source, recipe and registry digest before deployment qualification.
docId: DOC-14
tags: ["container", "nix", "packaging", "deployment"]
generated:
  by: process:codex
  at: 2026-11-02T04:15:00Z
---

# Build the TAN container image

The source flake packages all four binaries for Linux amd64, using the layout
already proven by `mori://tan/tan-ng-labs`. It neither changes that deployment nor
copies its database data, credentials or retained migration identities. See
[ADR-24](../adr/0024-package-tan-images-from-the-source-flake.md).

Build from a clean committed source tree. Record its full revision and both build
outputs; a dirty tree receives the development-only `uncommitted-p1` tag.

```bash
git status --short
git rev-parse HEAD
nix build .#packages.x86_64-linux.kansoku-image --no-link --json
nix build .#checks.x86_64-linux.kansoku-image-smoke --no-link --json
```

The smoke test needs a Linux builder with the VM test's required system
features. It boots the actual image without mounting host binaries. Build and
smoke success alone do not establish database compatibility or deployment readiness.

The archive contains `gcr.io/tan-ng/kansoku:<first-12-source-characters>-p1`.
On Darwin or Linux, export the same Linux closure to a normal artifact file by
executing the native stream app. It uses the source flake's pinned Docker tools;
no manual store-file inspection or copying is needed:

```bash
nix run .#kansoku-image-stream > /tmp/kansoku-image.tar
python3 scripts/check_container_image.py \
  --archive /tmp/kansoku-image.tar \
  --engine apple --oci-archive /tmp/kansoku-image-oci.tar \
  --revision "$(git rev-parse HEAD)" \
  --report /tmp/kansoku-image-smoke.json \
  --plan-dir /tmp/kansoku-image-plans
```

Before publishing, inspect that exported archive with `skopeo inspect docker-archive:<archive>`
and retain its architecture, source/revision labels, entrypoint, command and digest.
Use a registry credential supplied through a private auth file, rather than putting
an access token in a command argument. Publish only a previously unused source tag
with `skopeo copy docker-archive:<archive> docker://<repository>:<tag>`, using that
auth file. Resolve and retain the registry's resulting `@sha256:…` reference and
verify staging-node pull access. Never overwrite a tag with different content.

The entrypoint maps `DATABASE_URL`, `CLICKHOUSE_HOST`, `CLICKHOUSE_USER` and
`CLICKHOUSE_PASSWORD` onto Kansoku's explicit names; explicit values win. It leaves
`KANSOKU_CLICKHOUSE_SECURE` and the explicit HTTP/native ports untouched. Supply
credentials at runtime through Secrets. Calling a binary by overriding the
entrypoint skips mapping; prefer passing its name as the image command.

The published image must pass the owning environment's packaged PostgreSQL/native
migration, TLS, event/query and persistent recovery rehearsal before rollout. Keep
serving and retained migration digests separate when the deployment contract requires
it. This guide publishes no image and authorizes no database mutation.

## TAN production release evidence

Plan 64 selects the managed target separately from the Darwin fixture. See
[the target dossier](../evidence/tan-production-target.md) and
[release record](../evidence/tan-production-release.json) for the pending gates.
Exported image inspection now requires a fresh private `--plan-dir`. It captures
`native-direct.json`, `native-replicated.json` and `postgres.json` twice and
requires identical stdout bytes. SHA-256 includes the terminating newline; do not
parse/reformat JSON before hashing. Direct remains 25 migrations/257 steps;
replicated is 25/254. PostgreSQL includes both appended replica coordinators.
The synthetic cluster/UUID selectors in the image report select offline history
only. They are never deployment inventory.

The image report retains `nativePlanSha256` for the direct history and adds
`replicatedNativePlanSha256` and `postgresPlanSha256`. The production consumer's
`nativePlanSha256` deliberately maps to the replicated hash. Preserve the tested
archive, build receipts, three plan files and image report privately. Record its
full clean source revision, matching Cabal/Nix toolkit revisions, package outputs,
archive/configuration hashes, loaded image ID and layers in the release candidate.

```bash
python3 scripts/check_container_image.py \
  --archive /tmp/kansoku-image.tar --engine apple \
  --oci-archive /tmp/kansoku-image-oci.tar \
  --revision "$(git rev-parse HEAD)" --report /tmp/image-report.json \
  --plan-dir /tmp/kansoku-release-plans
python3 scripts/check_tan_release.py \
  --evidence docs/evidence/tan-production-release.json \
  --artifact /tmp/tan-artifact-draft.json --image-report /tmp/image-report.json \
  --plan-dir /tmp/kansoku-release-plans --phase prepared
```

Prepared mode emits exactly eight fields with `image: null`, so the draft cannot
serve as a usable deployment record. It exits 2 for pending readiness, 1 for
invalid evidence and 0 when the requested phase passes without pending gates.
Existing output files must agree exactly; use separate draft/final output paths.
Published mode requires every disposition, explicit managed-endpoint acceptance,
prerequisite passes and retained upload/readback receipts. Accepted gates require
owner, UTC date, actual decision source, reason and candidate archive/image binding.
The validator checks consistency, not the authenticity of a human decision.

After publication, read back by manifest digest and inspect the resulting archive
with a new report/plan directory. Retain original and readback archive hashes
separately because registry representation can change. The final record belongs at
`docs/evidence/tan-production-qualified-artifact.json` only after published-phase
validation. Evidence commits follow the clean image source commit; record both.


On macOS always use Apple Container, with Rosetta for amd64; never use Colima.
Convert the normal Docker archive to an OCI archive before loading it. Run Skopeo
from the source flake's pinned nixpkgs when it is not installed:

```bash
nix shell --impure --expr 'let f = builtins.getFlake (toString ./.); pkgs = import f.inputs.nixpkgs { system = builtins.currentSystem; }; in pkgs.skopeo' \
  -c skopeo --insecure-policy copy \
  docker-archive:/tmp/kansoku-image.tar \
  oci-archive:/tmp/kansoku-image-oci.tar:gcr.io/tan-ng/kansoku:<source-tag>
```

The policy flag here permits a local unsigned archive conversion; this command
contacts no registry. Keep the original Docker archive for publication. The checker
compares the loaded OCI filesystem layers, labels, environment and command with
that archive, then binds each created container's recorded local index digest
before starting it. Each probe has no networks or host mounts. The Apple local
index digest in `imageId` is distinct from Docker's configuration ID and the
published registry manifest. `imageIdKind` identifies its meaning. Reports record
Rosetta execution as emulated; it is not native Linux behavioral acceptance.

## Published TAN production candidate

The completed Plan 64 release is `gcr.io/tan-ng/kansoku@sha256:a78b668dbc98567bfd2d031f9b3aaf3a22b1f3f4bd4fbfd3ca3605dfbf98d213`. Use the [eight-field qualified artifact](../evidence/tan-production-qualified-artifact.json) and [target dossier](../evidence/tan-production-target.md) for the approved scope and onboarding obligations. Its source is `7c1132d74c8cb4fd5702b3ba8394aa1f52f66780`; later evidence commits do not change that source identity. All three exact plan captures were reproduced from the digest-addressed registry readback. Full image-based replicated execution and the managed endpoint remain explicitly accepted risks, not certified behavior.
