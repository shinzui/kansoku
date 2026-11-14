# Shared ClickHouse maintenance qualification

The owned local Nagare ceremony passed on 2026-11-14 UTC (November 13 Pacific):
one complete uninterrupted case, zero failures and zero skipped cases. This
joins the independently passing dedicated and two generic shared-server cases.
It is implementation-authored evidence, not independent review or production
qualification.

The actual platform is the unreleased source candidate of
`mori://shinzui/nagare` at commit
`8cc5a7792710083092c60c2dc71777186b61a360`, reporting package/platform version
0.20.0. Published v0.20.0 alone does not supply the newly required reader APIs.
Its reviewed local-mode inventory created both servers and the app memberships,
quiesced runtime users, paused/drained both schedules, ran backups, ingested
verified signed receipts, restored scratch databases and resumed the platform.
No manual grant substituted for reviewed declarations.

## Exact environment

Darwin arm64 packaged Kansoku clients addressed Linux arm64 data services in
Apple Container Kubernetes 1.35.5. The owned node is
`kansoku-ep53-023a75d1`, UID `639c4dec-e606-40fe-92c5-733762cb8ece`, from
`docker.io/kindest/node:v1.35.5@sha256:ce977ae6d65918d0b58a5f8b5e940429c2ce42fa3a5619ec2bbc60b949c0ac95`.
The actual ClickHouse image ID is official 26.8.28.14 index
`sha256:63e02621435cde1146ab0fde66057091ee75b312d12917c0109a6a0c99bc7ce1`;
its arm64 manifest is
`sha256:597add6eeadf0b3c562b58c9a63d9712b9a0cde4e49b68e64a697dbf2b363b25`.
The SDK independently qualifies that exact artifact. Source cohort
`a0bf98efbffbae9def846454deef9164ecadbd9d` passes all 54 declared groups in
both extracted-source and installed Nix variants (108 required groups total),
with zero failures/skips in their accepted runs. PostgreSQL uses the
platform's postgres:18 fixture. MinIO and local-path provisioning are owned
fixture infrastructure with download digests checked by the preparer.

The original schema expectation snapshot came from the qualified Darwin engine.
This real Linux restore verifies that same compiled expectation, including the
operational policy. The native protocol reports version/UUID, not an OCI digest
or operating system; the fixture separately verifies the deployment artifact.
The compiled plan digest is
`dbb1955a756b226e20dec7f918414d88f302357c94e1c4448caffbfe5ea72288` and expectation
digest is `3bb79f3f62e2a284ec678eb7b55d21ad43d482a619ebf0f7608ac365895e18fe`.

## Observations

The second app's long query remained active at every phase; at least 274 fresh
queries succeeded. Its data and grants stayed unchanged. ClickHouse remained
PID 1 with Linux start ticks 8923, Pod UID
`4c20d667-2f07-49f4-a0ad-40fdeef493d4`, restart count zero and server UUID
`e58a3c9f-48f6-400b-8900-2bf4c9900b79` throughout the ceremony.

A real writer and identity-cache metric succeeded before the persistent fence;
metrics refused after fencing. Runtime-only quiesce left an earlier migration
client alive. Missing full drain refused native entry at predecessor zero;
operator-controlled client completion and fresh owner-bound evidence then
admitted maintenance despite denied process diagnostics.

The PostgreSQL-only recovery manifest refused the first native application step.
Both actual backup artifacts and signed receipts were fetched and checked before
the complete manifest admitted that step. A committed native reply was dropped;
explicit receipt-bound repair and fresh predecessor evidence completed the same
owner. Retention and explicit event erasure then left the intended surviving row.

The scratch restores matched their common PostgreSQL session/policy/acceptance/
queue state, analytics rows and all 581 original native ledger rows. A separately
declared SELECT-only reader verified current history and physical schema under
mandatory ceilings. Captured requests were all SELECT; authentication columns,
temporary tables and mutations were denied. Adding an unreviewed scratch column
made schema verification fail while history remained current.

Kansoku's session and data jobs completed before reviewed platform resume.
The final real runtime metric succeeded and the final declaration re-plan
reported exactly `no operations`.

## Recovery artifacts

| Membership | Actual backup Job UID | Artifact SHA-256 | Signed receipt SHA-256 |
|---|---|---|---|
| PostgreSQL | `019db389-7850-439d-a13b-c73c54602a0f` | `e7cdeece8505505e46efc1d3d28983a4f4d46377c177632b4126f7b8612bfa1a` | `33322a2103809a58bda77949cfc1b0f696c45454441cbb1f52bfdf600a24ea90` |
| Both ClickHouse databases | `7fafd6b8-c425-4602-a77f-485523fc40a7` | `6d587cabdf3bb326d131ab33812c5f57afdbf10dca353bb2bd1fed6ae46740ba` | `dc0167f3df1d31bb7dbd5c3f1516ce7d1d7c5033b8eb6fa59cd7a9dc6d932f42` |

Private evidence is retained under
`.dev/nagare-ep53-qualified/ceremony-6aee31fd4cca484a95d31da8833b98ea/`, with
phase availability samples, complete artifacts/receipts, captured read-only
requests and per-role grants. Preparation and complete-run logs are
`.dev/ep53-nagare-qualified-prepare.log` and
`.dev/ep53-nagare-qualified-ceremony.log`. Earlier development failures and their
recovery are retained separately and are not passing continuous ceremonies.
The initial 36-shard upstream run exhausted host processes; the accepted final
Nagare full suite uses four explicit shards and passes all of them.

## Reproduce and scope

Discover the canonical Nagare checkout with Mori, build its tested source
candidate's `nagarectl`, then run:

```bash
NAGARE_SOURCE="$(mori path mori://shinzui/nagare | tail -n 1)"
NAGARECTL="$(nix build github:shinzui/nagare/8cc5a7792710083092c60c2dc71777186b61a360#nagarectl --no-link --print-out-paths)/bin/nagarectl"
nix develop -c python3 scripts/prepare_nagare_maintenance_fixture.py \
  --root .dev/nagare-proof --nagarectl "$NAGARECTL" \
  --nagare-source "$NAGARE_SOURCE"
nix develop -c just ch-nagare-maintenance-acceptance .dev/nagare-proof
```

The preparer requires a new private root, creates a unique owned cluster and
uses its own local context, Kubernetes credentials and saved review directories.
The source manifest is from `mori://shinzui/nagare`, project-relative
`cluster/local/minio/minio.yaml` (artifact URI pending). The preparer preserves
failed owners and evidence; it never turns a failed ceremony into a skipped pass.
All three owned local clusters were stopped after accepted proof and capture;
private inventories, data and receipts remain retained for inspection/recovery.

This proves the reviewed local-mode data-service workflow. Stock k3d/Knative
platform bootstrap, a Linux application image, managed cloud and remote CI are
separate qualification boundaries. The node has a reviewed minimal namespace
foundation and owned local storage/object storage. Rebuilt-server adoption is
proved separately by the generic fixture, preserving the shared server used for
availability evidence. Production deployment is outside this work.


Required Kansoku guide/capability/terminology/ADR/IR checks pass. A separate
stricter capability audit retains baseline missing review records (FRIC-42),
and whole Nagare user-doc validation retains its unrelated missing-frontmatter
failure. Neither whole strict audit is reported as passing; exact limitations
and logs are recorded in EP-53.
