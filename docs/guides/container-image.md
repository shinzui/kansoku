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
  --docker-context <isolated-local-context> \
  --revision "$(git rev-parse HEAD)" \
  --report /tmp/kansoku-image-smoke.json
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
