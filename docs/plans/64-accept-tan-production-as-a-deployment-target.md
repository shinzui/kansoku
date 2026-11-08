---
id: 64
slug: accept-tan-production-as-a-deployment-target
title: "Accept TAN production as a deployment target"
kind: exec-plan
created_at: 2026-11-08T01:20:26Z
intention: "intention_01m6wbtfqqetnsv3fds3t4p84f"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-11-08T01:20:26Z
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-08T04:53:20Z
      mode: "implement"
      note: "Implement target dossier, exact image plan capture and fail-closed release validation"
---

# Accept TAN production as a deployment target

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current. Record implementation friction through `agents/skills/exec-plan/FRICTION.md`; distill durable decisions into `docs/adr/` before completion.


## Purpose / Big Picture


Give TAN a published, immutable Linux amd64 Kansoku image and a dated release decision for its one-shard, two-replica Altinity production cluster. TAN must be able to copy the image reference and migration-plan hashes into its production artifact record, verify their source, and see exactly which tests passed and which risks the Kansoku release owner accepted.

This implements [IR-12](../../docs/improvement-requests/accept-tan-production-as-a-deployment-target.md). It consumes the completed migration and runtime work in [Plan 62](../../docs/plans/62-run-clickhouse-migrations-on-a-replicated-cluster.md) and [Plan 63](../../docs/plans/63-keep-writes-and-maintenance-jobs-correct-on-a-replicated-cluster.md). Those plans are hard release dependencies: a risk acceptance about platform coverage cannot waive the underlying replicated behavior. Target research and release tooling can proceed while they are unfinished; final qualification and publication require their completed implementation and evidence in the candidate source.

This is a standalone release plan, not a child of MasterPlan 7 or of the requesting `mori://tan/tan-app-infrastructure/plans/45-onboard-kansoku-to-production-on-the-replicated-clickhouse-cluster`. TAN owns production onboarding and its proposed staging-first serving rollout. This plan publishes Kansoku's artifact and handoff evidence; it does not run migrations, alter data, or change TAN's stacks.


## Progress


- [x] (2026-11-08; immutable infrastructure/consumer rereads, patch review and separate target dossier; original fixture entry unchanged) Milestone 1: The selected TAN target and every production gate have a source-backed dossier, and the local Darwin qualification fixture still selects its original artifact.
- [x] (2026-11-08; clean 7c1132d, Linux image/VM builds, Apple Rosetta byte-repeatable 25/257, 25/254 and PostgreSQL plans, prepared draft exits 2 with four explicit pending gates; 11 negative cases pass) Milestone 2: A clean candidate containing Plans 62 and 63 yields an identifiable Linux amd64 image, reproducible direct/replicated/PostgreSQL plan hashes, and a validated draft TAN artifact record.
- [ ] Milestone 3: The exact candidate has linked replicated acceptance evidence and dated release-owner dispositions for all remaining gates, including the managed endpoint and any Linux application-image coverage gap.
- [ ] Milestone 4: The approved image is published and verified by registry digest, and the final evidence and TAN-compatible artifact record agree on source, dependency revision, plan hashes, and acceptance scope.


## Surprises & Discoveries

2026-11-08: FRIC-18 in `docs/friction-log/` records the failed emulated Docker probe: exit 137 and independently observed OOMKilled=true, even with GHCRTS=-N1. The native Linux VM smoke passes. Apple Container with Rosetta executes the same exported image and all three repeated offline plans successfully. The checker now binds each created Apple container to its inspected local OCI index before starting it; no networking or host mounts are present. A local index digest is not a registry manifest receipt.

2026-11-08: Official Altinity notes explicitly identify CVE-2026-116366 remediation in 10002 and temporarily withheld security source changes. The public release tag identifies only the public baseline, not all binary inputs. The dossier retains that limitation; security disposition remains pending. Both infrastructure and consumer master heads still match the planning snapshots.



## Decision Log

2026-11-08: The user requires Apple Container on macOS and forbids Colima. `AGENTS.md` now retains this instruction. Use the Apple backend for image smoke with Rosetta and network isolation; existing Colima prerequisite receipts are historical evidence only. No prerequisite application or dependency code changed, so those retained behavioral results remain applicable within their original scope.


2026-11-08: Preserve the existing matrix's direct Darwin candidate and add a separate selected deployment-target record. `nix/clickhouse-qualified.nix` currently uses the first `entries` element as a downloadable macOS binary. Replacing it with managed-service metadata would break local builds and confuse target selection with fixture qualification.

2026-11-08: Prefer replicated acceptance executed from the actual Linux amd64 image, while retaining IR-12's explicit alternative of a dated release-owner acceptance of the precisely described image/platform gap. Neither route substitutes for completion of Plans 62 and 63. An agent cannot accept a release risk on the owner's behalf or treat a passing offline smoke check as replicated execution.

2026-11-08: Retain direct and replicated native plan hashes separately in detailed evidence. The TAN production artifact's `nativePlanSha256` denotes the replicated offline plan; the direct hash remains available for staging compatibility. Hash exact captured output bytes, including their terminating newline, rather than formatting parsed JSON again.

2026-11-08: Build from one clean immutable source revision and commit release evidence afterwards. The evidence commit is not the image's source revision. Preserve the tested archive and publish that content; do not rebuild an image merely to incorporate its own resulting registry digest into source.


## Outcomes & Retrospective

Milestones 1 and 2 are implemented and verified. Clean source `7c1132d74c8cb4fd5702b3ba8394aa1f52f66780` yields the Linux amd64 image and passing native Linux VM smoke. Apple Container/Rosetta runs the exported image with no networks or mounts; all three plan outputs repeat exactly and the direct history matches the retained fixture. Prepared validation emits `docs/evidence/tan-production-artifact-draft.json` with `image: null` and exits 2 for the four pending owner gates. The sanitized image report is `docs/evidence/tan-production-image.json`; private archives, exact stdout, build metadata and failures remain under `.dev/acceptance/`.

`just check` passes, including the eleven negative release cases; strict ADR, guide and friction validation passes. No application/package/dependency source changed relative to `a40b20a`, so retained Plan 62/63 evidence remains applicable within its recorded scope. Full database acceptance from the Linux application image has not run. Proposed owner rationale in the target dossier is explicitly unapproved. Milestones 3 and 4 remain open: actual dated owner decisions and verified registry publication/readback are required. IR-12 remains unresolved. FRIC-18 is resolved through Apple Container; the user instruction never to use Colima is retained in `AGENTS.md`.


## Context and Orientation


A shard is one logical data partition; two replicas keep copies of that partition. Keeper is the coordination service that makes replication work. A migration ledger records applied schema operations and uncertain outcomes. Direct installations use the existing single-server ledger and checksum v1 history. Plans 62 and 63 add a separate replicated baseline, a fresh v2 ledger, complete replica identity, and all-replica maintenance/writer behavior. A migration-plan SHA-256 in this release record hashes the whole CLI JSON output; it is distinct from the individual v1/v2 migration checksums inside that output.

`docs/evidence/clickhouse-migrate-adoption.md` contains historical Darwin qualification and the 2026-11-07 dependency upgrade, but its current production disposition still says no target is selected. `db/clickhouse/qualification/matrix.json` retains the original `26.8.28.14` Darwin binary, its startup SIGSEGV caveat, and an old policy excluding replication and Cloud. Its historical `sourceRevision` is not the currently adopted toolkit revision. Preserve those facts as historical evidence while clearly identifying the new selected target and current scope. Do not leave the document's final aggregate paragraph contradicting the new disposition.

`nix/clickhouse-qualified.nix` reads `builtins.head matrix.entries` and downloads its `url`/`sha256`; unsupported systems get a failing executable. `scripts/isolated_clickhouse.py` and `scripts/clickhouse_migrations_acceptance.py` also guard the existing Darwin fixture. A managed-target record must not make those existing direct recipes silently select another server or report Linux qualification. The new replicated recipes supplied by Plans 62 and 63 are separate acceptance paths.

`cabal.project` and `flake.module.nix` pin all four migration-toolkit packages to source candidate `0.1.1.0` at `0e75c4cc1303423ba561370ee5795aa0cf2455b7`. No dependency change is selected here. Mori locates `mori://shinzui/clickhouse-migrate`; its registry currently lists no curated docs. Relevant source-relative documents, whose artifact-level URIs are pending, are `docs/user/compatibility.md`, `docs/release-evidence/2026-11-07-altinity-10002.md`, `docs/release-evidence/2026-11-07-replicated.md`, and the associated JSON receipts. The upstream evidence qualifies Darwin clients against owned Linux arm64 Altinity containers, not Linux clients or a managed endpoint. It records another Darwin pre-readiness SIGSEGV during the 10002 qualification attempt, followed by a separately passing run. The later pass does not establish the crash's cause or fix.

TAN's selected target is `tan-production`, cluster ID `11282`, Altinity.Cloud environment `topagentnetwork-5os8y`, version `26.3.60.10002.altinitystable`, one shard and two replicas in `us-west1-b` and `us-west1-c`. The shared HTTPS endpoint is `https://tan-production.topagentnetwork-5os8y.altinity.cloud:8443`; native application TLS uses the same host and explicit port `9440`. The infrastructure declares `n2d-standard-4`, 150 GB `pd-ssd`, secure transport and Altinity-managed Keeper. Infrastructure evidence records daily backups at 05:00 UTC with seven kept, without a tested restore. Provisioned disk class is not proof of ClickHouse's healthy writable Local default storage policy or its fsync settings; preserve that distinction.

The target configuration was read at `mori://tan/tan-infrastructure`, revision `ae353d303c3efa078f146de48d9ed1d2812b05cd`, project-relative `altinity/clusters/production.json` (artifact-level URI pending). Endpoint and backup context comes from `mori://tan/tan-infrastructure/plans/6-bring-the-production-clickhouse-cluster-on-altinity-cloud-into-the-repository`. The locally registered checkout lags these sources; authenticated GitHub Contents API reads supplied the committed files without changing that checkout. Refresh immutable source evidence during implementation rather than assuming this planning snapshot is current. Record the reported server architecture separately from the application's required `linux/amd64`; the configuration alone does not identify the exact managed server binary digest.

TAN's existing artifact contract was inspected at `mori://tan/tan-app-infrastructure`, revision `108a5d918d2e51f58c8cb73c8e9f080e3af6abf9`, project-relative `pulumi/apps/kansoku/qualified-artifact.json` and `docs/qualification/kansoku-image.json` (artifact-level URIs pending). The first has exactly eight fields: `image`, `sourceProject`, `sourcePackage`, `sourceRevision`, `upstreamProject`, `upstreamImplementation`, `nativePlanSha256`, and `postgresPlanSha256`. Its current values describe an older staging image and must not be copied as the new release's identity. The originating TAN Plan 45 was absent both locally and from upstream master during planning; IR-12 is the available request contract. Its unavailable plan does not prevent this self-contained Kansoku plan. Recheck its consumer expectations before handoff, keeping the canonical plan URI even if Mori cannot resolve it.

`nix/kansoku-image.nix` packages all four executables, BusyBox, a CA bundle and `packaging/entrypoint.sh`. The image tag is the first twelve source-revision characters followed by `-p1`. `flake.module.nix` exposes `packages.x86_64-linux.kansoku-image`, the Linux VM smoke check, and a native `kansoku-image-stream` exporter. `scripts/check_container_image.py` inspects a normal exported archive, verifies Linux amd64 and OCI source labels, binds the loaded layers/configuration, and executes the recorded Docker image ID with networking disabled. It currently checks only the direct 25-migration/257-step plan and hashes that output. It does not capture a PostgreSQL plan or execute replicated database acceptance. `kansoku-server/app/Migrate.hs` exposes the PostgreSQL plan command and loads application configuration even for offline inspection, so provide harmless fixture environment values through the normal entrypoint.

A registry manifest digest identifies the published image reference. The archive SHA-256, archive configuration digest and loaded Docker image ID identify different representations; loading can normalize configuration. Keep them under distinct names. Nix package output identities returned by build metadata help bind the candidate to its compiled package. Query build metadata and execute declared outputs through normal tools; never traverse `/nix/store` or inspect its files to establish provenance.

Relevant ADRs consulted are [ADR-10](../../docs/adr/0010-owned-executable-acceptance-environments.md), requiring owned, non-skipping executable acceptance; [ADR-22](../../docs/adr/0022-explicit-clickhouse-migrations-and-persistent-administrative-sessions.md), requiring immutable history, retained identity, persistent fences and explicit recovery; [ADR-23](../../docs/adr/0023-verified-tls-for-native-clickhouse-connections.md), separating verified native TLS from HTTPS migration configuration; and [ADR-24](../../docs/adr/0024-package-tan-images-from-the-source-flake.md), requiring clean immutable source, source-flake packaging and separate image versus deployment evidence. Their existing qualification statements are historical; update them only to match the newly established scope, preserving direct behavior and the absence of managed-cloud certification.


## Plan of Work


### Milestone 1 — Establish the target and gate dossier


Update the current disposition in `docs/evidence/clickhouse-migrate-adoption.md` to select the target described above and identify the source revision/date for each observation. Preserve old runs in explicitly historical sections. Add a `deploymentTargets` array to `db/clickhouse/qualification/matrix.json`, with one `tan-production` record containing provider, target name, version, topology, endpoints, application platform, declared storage and evidence references. Keep the original `entries[0]` and its download identity intact. Rewrite the top-level policy to distinguish historical direct fixture qualification, the replicated upstream candidate, and target-specific acceptance; do not turn managed acceptance into a global Cloud support claim. New target fields must state whether facts are declared, observed or pending.

Add `docs/evidence/tan-production-release.json` as the machine-readable companion for this release, initially with `status: "pending"`. It contains the selected target, prerequisite plan evidence, source/build identities, plan hashes, acceptance runs, and four stable gate keys: `startup-crash`, `security-patch-review`, `linux-amd64-image`, and `managed-endpoint`. Each gate has `status` (`pending`, `resolved` or `accepted`), evidence references, and a reason. An accepted gate also requires the release owner's identity, UTC date, and a retained source of the actual decision. These are records of an owner's decision, not cryptographic signatures or decisions inferred from model provenance. Do not insert an owner's name or approval until supplied.

For the startup crash, bring both documented failed Darwin attempts into the dossier and distinguish their platform/artifact from the selected managed server. A different platform or a later pass is not proof of a fix. For security/patch review, compare the exact selected Altinity patch with the earlier qualified Altinity candidate and any relevant original ClickHouse caveats; consult current official Altinity release notes, upstream security policy/advisories and release tags. Record date, URLs, relevant fixes/advisories, applicability and residual uncertainty. Do not assert that no security issues exist because fixtures pass. If a required fix is outside the supported version set, keep the gate pending and arrange upstream qualification followed by a new candidate; never widen the local runtime allowlist to satisfy this plan.

For the managed endpoint, document that each new migration connection must admit an expected replica UUID, exact supported version, cluster and required settings before application or ledger SQL. Full replica inventory must be independently retained. A load balancer that does not expose every expected replica can cause bounded observation failure; connection loss after submission can leave an uncertain outcome requiring fenced recovery. Admission detects mismatch and fails closed but does not certify provider routing, availability, storage durability or cluster-wide drain. Preserve normal certificate verification. Reference Plans 62 and 63 for application/runtime behavior rather than attributing all native writer guarantees to the HTTP migration toolkit.

Milestone acceptance is a complete factual dossier with no fabricated resolutions, an intact original direct candidate, and agreement between the target record and cited infrastructure sources. Pending owner decisions are allowed at this stage. Record unknown managed storage/architecture observations as such, with the remaining deployment verification obligation; do not manufacture binary hashes or per-replica observations.


### Milestone 2 — Bind the candidate image to its source and plans


After Plans 62 and 63 are implemented and verified, select a clean committed candidate containing both changes and the release tooling. Build the Linux image and VM smoke check with the existing source flake. Record the full source revision, the matching Cabal/Nix toolkit revision, build-result package identities, archive hash, loaded image ID, architecture and OCI labels. An `uncommitted` image is never a release candidate. Use an isolated detached worktree if the shared working tree contains unrelated edits; remain on the current branch for ordinary commits.

Extend `scripts/check_container_image.py` and the VM smoke check in `nix/kansoku-image.nix` to inspect both native plans. With both topology selectors absent, retain the direct 25/257 and compatibility assertions. With `KANSOKU_CH_MIGRATION_CLUSTER=fixture`, two fixed synthetic valid UUIDs in `KANSOKU_CH_MIGRATION_REPLICA_IDS`, and no `KANSOKU_CH_MIGRATION_SERVER_ID`, capture the replicated offline plan without network access. Synthetic UUIDs are only offline selectors and must never enter deployment identity records. Use the final Plan 62 manifest's expected count (planned as 25 migrations/254 steps); fail on an unexpected plan instead of changing expectations to whatever the image emits. Capture `kansoku-migrate plan --json` from the same loaded image with harmless configuration. Verify successful JSON/status, both native histories, PostgreSQL components and the required appended coordinator migrations from Plans 62 and 63. Preserve the four executables, entrypoint mapping, explicit TLS overrides and CA checks.

Capture subprocess stdout as bytes, save the three exact plan files under the private evidence directory, and hash those bytes including the final newline. Re-running the same commands in the same image must yield identical bytes; do not canonicalize JSON. Preserve existing `nativePlanSha256` as the direct value in the smoke report for compatibility and add an explicit replicated field plus `postgresPlanSha256`. The production handoff deliberately maps the replicated value to its `nativePlanSha256`. Include selectors and hash algorithm semantics in detailed evidence so a consumer can reproduce the correct hash.

Add `scripts/check_tan_release.py` to validate the dossier and emit `docs/evidence/tan-production-qualified-artifact.json` using the eight-field contract below. Provide `--evidence`, `--artifact`, `--image-report`, `--plan-dir`, and `--phase prepared|published`; prepared mode checks identity and hashes without requiring a registry digest or owner acceptance, while published mode requires the final digest, all gate dispositions and passing prerequisite evidence. A draft without a digest must never masquerade as a usable qualified artifact. The script does not accept risks or contact deployment targets. It checks source/dependency agreement, artifact field mapping, real captured hashes, acceptance-run identity and gate completeness; it cannot authenticate human decisions. Add focused tests in `scripts/test_check_tan_release.py` for a foreign source revision, swapped direct/replicated hashes, altered plan bytes, missing prerequisite evidence, missing owner/date/reason, and a Docker configuration ID substituted for the published manifest reference. Reports must distinguish validation failure from pending readiness.

The early producer/consumer proof is to export one candidate, inspect the real image's plans, and construct/validate the eight-field draft against TAN's observed contract before adding full runtime variants. Milestone acceptance requires repeatable hashes, correct mapping, passing smoke checks and negative-validator tests. A passing milestone does not yet close any live database coverage gap.


### Milestone 3 — Establish coverage and obtain actual gate dispositions


Collect the completed Plans 62 and 63 acceptance runs with their source revision, toolkit revision, server image digest/platform, client platform, topology, artifact variant, commands, nonzero case counts and failure/skip counts. Re-run affected acceptance against the final candidate whenever code or dependency changes invalidate the recorded evidence. Required migration lifecycle, two-replica observations, zero-SQL repeat, maintenance interruption/recovery, writer retry/quorum and synchronized read-back outcomes remain required. A test of another source revision needs a demonstrated unchanged relevant package identity or a fresh run; a similar version string is insufficient.

Prefer running those existing scenarios using executables from the actual exported Linux amd64 image. Extend the Plan 62 migration harness and Plan 63 `scripts/clickhouse_replicated_runtime_acceptance.py` with an explicit image execution mode, reusing their owned replica/Keeper/PostgreSQL setup and scenario assertions. Accept `--image-id` and `--docker-context`, run only the bound loaded image with `--pull=never`, and record every executed executable's artifact variant. Containers must reach only the owned fixtures through an explicit local test network or controlled proxy; do not mount host executables into the image or fall back silently to a Darwin executable. Handle container-versus-host loopback addresses deliberately and verify replica UUID admission. Run an initialization plus one cross-replica write/read from the image before expanding fault cases. Preserve direct recipes and owned-resource cleanup. Record whether amd64 execution was native or emulated; an arm64 server fixture does not become amd64 because the client image is amd64.

If the complete image-based run is unavailable, do not implement a second test framework merely to hide the limitation or report skipped tests as success. Preserve the passing prerequisite runs and enumerate exactly which scenarios ran on Darwin, Linux, the packaged image or a separate test driver. IR-12 permits the release owner to accept the remaining Linux application-image coverage gap. Prepare that concrete disposition with the exact candidate archive/configuration/image identities, known failures, omitted scenarios and rationale requested from the owner. If no acceptance is supplied, Milestone 3 and release readiness remain open while other preparatory work can continue.

Once the dossier is concrete, obtain the Kansoku release owner's dated decision for the unresolved startup-crash and patch/security gates, any uncovered Linux image gap, and the uncertified managed endpoint. The endpoint always requires explicit acceptance under IR-12 AC-4, even after successful owned endpoint tests. Resolved gates must cite evidence supporting actual resolution; accepted gates must state the residual risk and owner's reason. Record the actual decision reference without pretending that plan creation, a model review, or generic permission to implement is risk acceptance. If a decision already exists and covers this exact candidate/target, verify it and use it without asking again. Bind decisions made before publication to the preserved candidate archive and loaded image identity, then connect those to the registry digest after publication.

Update the adoption evidence and matrix with those dispositions. Amend ADR-22 for the selected deployment scope and ADR-24 for the artifact/evidence contract; preserve ADR-23's verified TLS and ADR-10's required acceptance rules. Use the repository's profiled ADR workflow, stable handles and strict validation. Milestone acceptance requires all four gates resolved or explicitly accepted as permitted, the managed-endpoint gate specifically accepted, and a release-ready dossier covering a candidate containing both prerequisite plans. Failed behavioral prerequisites are not waivable by this plan's platform-gap clause.


### Milestone 4 — Publish the accepted artifact and hand off verified identity


Publish the already-tested archive to the unused source-revision tag at `gcr.io/tan-ng/kansoku` using a private registry auth file and the existing image guide. Publication is part of implementing IR-12; plan creation itself performs no publication. Use any existing session authorization for publication. If a tool or repository policy requires an additional approval, first prepare the concrete archive, command, identities and complete dossier, then request that approval as the final publication step. Do not alter production/staging infrastructure or send messages to another team as part of this handoff.

Resolve the registry manifest digest and inspect the digest-addressed artifact. Verify Linux amd64, source/revision labels, layers/configuration and all three offline plan hashes from the retrieved artifact. The registry may normalize image representation, so compare content and recorded configuration deliberately rather than asserting the archive hash equals the registry digest. Record upload/readback receipts, final immutable `image`, and the mapping from prepublication candidate identities and owner decisions to that digest. A registry mismatch fails the milestone and must not overwrite an existing immutable tag.

Emit the final `docs/evidence/tan-production-qualified-artifact.json` with the exact eight consumer fields. Set `nativePlanSha256` to the replicated plan hash and retain the direct plan hash in `docs/evidence/tan-production-release.json` and adoption evidence. Record the evidence commit separately from the candidate source commit. Run the published-phase checker against the readback report and exact captured plans. Document reproduction and hash semantics in `docs/guides/container-image.md` and the relevant target notes in `docs/guides/clickhouse-migrations.md`.

Provide TAN with repository-local evidence paths and their canonical Kansoku project reference, plus the ready-to-copy artifact record. TAN's staging image rollout, production replica inventory/storage/grants checks, fresh ledger creation and managed migration/event-flow rehearsal remain its onboarding work. A normal staging direct-path serving rollout is not replicated acceptance and must not silently replace retained migration operation inputs. Mark IR-12 completed only when all five criteria pass; record its resolution/evidence and update the improvement-request log. Distill durable decisions and triage implementation friction before completing this plan.


## Concrete Steps


Run local commands from `/Users/shinzui/Keikaku/bokuno/kansoku-project/kansoku`, or from an isolated clean checkout of the selected candidate for builds. Use Mori to locate external sources, never search `/` or `/nix/store`. External paths in the commands below belong to the canonical projects identified in Context and Orientation; their file-level artifact URIs are pending.

```bash
mori registry search clickhouse-migrate
mori registry show shinzui/clickhouse-migrate --full
mori registry docs shinzui/clickhouse-migrate
mori path mori://shinzui/clickhouse-migrate
mori registry show tan/tan-infrastructure --full
mori registry show tan/tan-app-infrastructure --full
mori path mori://tan/tan-app-infrastructure/plans/45-onboard-kansoku-to-production-on-the-replicated-clickhouse-cluster
```

A failed artifact resolution is a registry/publication limitation, not permission to replace a canonical reference with a bare path. If registered checkouts still lag, inspect immutable committed files read-only as during planning:

```bash
gh api 'repos/topagentnetwork/tan-infrastructure/contents/altinity/clusters/production.json?ref=ae353d303c3efa078f146de48d9ed1d2812b05cd' -H 'Accept: application/vnd.github.raw+json'
gh api 'repos/topagentnetwork/tan-app-infrastructure/contents/pulumi/apps/kansoku/qualified-artifact.json?ref=108a5d918d2e51f58c8cb73c8e9f080e3af6abf9' -H 'Accept: application/vnd.github.raw+json'
```

For current release decisions, first resolve the new authoritative revision and retain it, then substitute it into these reads. Before changing any dependency pin or bound, additionally check the authoritative package registry and upstream release tags. For security disposition use the current official Altinity release notes at `https://docs.altinity.com/releasenotes/altinity-stable-release-notes/26.3/` and ClickHouse security policy at `https://github.com/ClickHouse/ClickHouse/security/policy`, follow their relevant advisory/release links, and record the review date and findings. This plan does not pre-approve the security review.

The following prerequisite recipes describe the retained historical Docker acceptance, not commands to rerun on macOS. The user now forbids Colima; a future behavioral rerun must adapt their owned fixtures to Apple Container. No application/dependency changes in this release preparation invalidate the retained runs:

```bash
export CLICKHOUSE_MIGRATE_DOCKER_CONTEXT='<isolated-local-context>'
nix develop --no-write-lock-file -c just ch-migrations-replicated
nix develop --no-write-lock-file -c just ch-runtime-replicated
nix develop --no-write-lock-file -c just ch-migrations-source
nix develop --no-write-lock-file -c just check
```

These new recipes are specified by Plans 62 and 63 and do not exist at this plan's creation. Their expected result is nonzero required case counts, zero failures and zero skips. Keep the Darwin direct regression gates and their platform limits explicit. Do not run a direct native fixture on an unsupported OS to manufacture a green check.

Build and export from the clean candidate. Replace the Docker context placeholder with an isolated local Unix-socket context; the image smoke checker refuses a remote context. Create a new evidence directory for each candidate/run and preserve failed-run evidence.

```bash
test -z "$(git status --porcelain)"
export TAN_RELEASE_REVISION="$(git rev-parse HEAD)"
export TAN_RELEASE_DIR="$(mktemp -d /tmp/kansoku-tan-release.XXXXXX)"
export TAN_RELEASE_CONTEXT='<isolated-local-context>'
nix build .#packages.x86_64-linux.kansoku-image --no-link --json > "$TAN_RELEASE_DIR/build.json"
nix build .#checks.x86_64-linux.kansoku-image-smoke --no-link --json > "$TAN_RELEASE_DIR/vm-smoke.json"
nix run .#kansoku-image-stream > "$TAN_RELEASE_DIR/image.tar"
python3 scripts/check_container_image.py \
  --archive "$TAN_RELEASE_DIR/image.tar" \
  --engine apple --oci-archive "$TAN_RELEASE_DIR/image-oci.tar" \
  --revision "$TAN_RELEASE_REVISION" \
  --report "$TAN_RELEASE_DIR/image-report.json" \
  --plan-dir "$TAN_RELEASE_DIR/plans"
python3 -m unittest discover -s scripts -p 'test_check_tan_release.py'
```

On macOS use Apple Container and convert `image.tar` to `image-oci.tar` with the pinned Skopeo recipe in `docs/guides/container-image.md` before invoking the checker. Never use Colima. The checker retains both archive hashes and reports Rosetta execution as emulated.

`--plan-dir` is added in Milestone 2. It writes `native-direct.json`, `native-replicated.json` and `postgres.json`. The report must identify `linux/amd64`, the exact source revision and three stable hashes. The VM check requires an available x86_64 Linux builder with the NixOS test features; missing build capacity remains a visible prerequisite. None of these commands starts production services.

When image execution support is ready, run the existing scenario families through it:

```bash
export TAN_RELEASE_IMAGE_ID="$(jq -r .imageId "$TAN_RELEASE_DIR/image-report.json")"
nix develop --no-write-lock-file -c python3 scripts/clickhouse_migrations_acceptance.py \
  --replicated --image-id "$TAN_RELEASE_IMAGE_ID" --docker-context "$TAN_RELEASE_CONTEXT"
nix develop --no-write-lock-file -c python3 scripts/clickhouse_replicated_runtime_acceptance.py \
  --image-id "$TAN_RELEASE_IMAGE_ID" --docker-context "$TAN_RELEASE_CONTEXT"
python3 scripts/check_tan_release.py \
  --evidence docs/evidence/tan-production-release.json \
  --artifact docs/evidence/tan-production-qualified-artifact.json \
  --image-report "$TAN_RELEASE_DIR/image-report.json" \
  --plan-dir "$TAN_RELEASE_DIR/plans" --phase prepared
```

These image-mode flags are proposed interfaces to implement or reconcile with the prerequisite harnesses, not claims about current CLI support. Default image-mode execution must run all existing required cases; focused development cases cannot qualify a whole release. Prepared validation prints the bound identities and still-pending gates, never `published` readiness. If full image execution cannot be established, record that gap for the owner instead of treating the failed command as passing.

After Milestone 3, use an auth file supplied privately for registry access. `TAN_RELEASE_AUTH_FILE` below is a path to that file, never a token value. First inspect the intended tag: only a confirmed not-found result permits new publication; authentication/network errors do not mean it is absent. An existing tag may be reused only after proving it already contains the identical candidate, without an overwrite.

```bash
export TAN_RELEASE_TAG="gcr.io/tan-ng/kansoku:${TAN_RELEASE_REVISION:0:12}-p1"
skopeo inspect --authfile "$TAN_RELEASE_AUTH_FILE" "docker://$TAN_RELEASE_TAG"
skopeo copy --authfile "$TAN_RELEASE_AUTH_FILE" \
  "docker-archive:$TAN_RELEASE_DIR/image.tar" "docker://$TAN_RELEASE_TAG"
skopeo inspect --authfile "$TAN_RELEASE_AUTH_FILE" "docker://$TAN_RELEASE_TAG" \
  > "$TAN_RELEASE_DIR/registry.json"
export TAN_RELEASE_DIGEST="$(jq -r .Digest "$TAN_RELEASE_DIR/registry.json")"
skopeo copy --authfile "$TAN_RELEASE_AUTH_FILE" \
  "docker://gcr.io/tan-ng/kansoku@$TAN_RELEASE_DIGEST" \
  "docker-archive:$TAN_RELEASE_DIR/readback.tar:$TAN_RELEASE_TAG"
python3 scripts/check_container_image.py \
  --archive "$TAN_RELEASE_DIR/readback.tar" \
  --docker-context "$TAN_RELEASE_CONTEXT" --revision "$TAN_RELEASE_REVISION" \
  --report "$TAN_RELEASE_DIR/readback-report.json" \
  --plan-dir "$TAN_RELEASE_DIR/readback-plans"
```

Execute publication commands only after the preceding tag check and gate review are satisfied; they are not an unconditional shell batch. Compare readback plans and content with the preserved candidate, populate the final evidence from actual receipts, and run:

```bash
python3 scripts/check_tan_release.py \
  --evidence docs/evidence/tan-production-release.json \
  --artifact docs/evidence/tan-production-qualified-artifact.json \
  --image-report "$TAN_RELEASE_DIR/readback-report.json" \
  --plan-dir "$TAN_RELEASE_DIR/readback-plans" --phase published
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
okf validate docs/guides --strict --profile docs/guides/profile.dhall --profile-enforce --log-enforce
okf validate docs/improvement-requests --strict --profile docs/improvement-requests/profile.dhall --profile-enforce --log-enforce
git diff --check
```

Published validation must fail for any missing digest, mismatched identity/hash, missing prerequisite evidence or unresolved gate. It prints the verified immutable image and acceptance scope on success. Keep sanitized checked-in summaries separate from private logs, credentials, archive bytes and raw plan captures. Every implementation commit uses a Conventional Commit message with `ExecPlan: docs/plans/64-accept-tan-production-as-a-deployment-target.md` and `Intention: intention_01m6wbtfqqetnsv3fds3t4p84f` trailers.


## Validation and Acceptance


IR-12 AC-1 is met when the current adoption disposition and matrix explicitly identify Altinity.Cloud `tan-production`, the exact version, one shard/two replicas and HTTPS endpoint on 8443, alongside the Linux amd64 application requirement. Historical “not selected” statements may remain only as clearly dated historical facts, not current conclusions. Preserving the first fixture entry and its source/download identity prevents this release change from replacing the Darwin development target.

AC-2 requires a dated, attributable disposition for both the startup crash and intervening patch/security review. Either resolution is supported by concrete evidence or the Kansoku release owner explicitly accepts the residual risk with a reason. A later successful run, platform difference, or model-authored risk paragraph alone fails this criterion.

AC-3 requires the published image digest, Linux amd64 identity, source and exact coverage mapping. Full replicated acceptance from that artifact satisfies it; otherwise a specific release-owner acceptance of the remaining image/platform gap is required. All required Plan 62 and Plan 63 behavioral outcomes must still pass. Identify emulation, separate test drivers and server platform honestly. Offline plan smoke, packaging or a staging direct-path rollout alone does not satisfy replicated coverage.

AC-4 requires a dated release-owner acceptance naming the uncertified single load-balanced managed endpoint, per-connection replica UUID admission and its fail-closed behavior, plus residual availability/uncertainty and independently verified-inventory obligations. Do not claim managed-cloud certification from that acceptance.

AC-5 requires an actually published and read-back-verified `gcr.io/tan-ng/kansoku@sha256:…` reference, candidate source revision, toolkit revision and exact replicated-native/PostgreSQL plan hashes. The eight-field artifact file must agree with detailed evidence and the bytes emitted by that image. A local Docker ID, archive hash or proposed tag cannot substitute for the registry digest. Negative checker cases must refuse altered or mismatched artifacts. Missing release-owner decisions, build capacity or credentials leave the relevant milestone unpassed; completed preparation is retained without declaring the release ready.


## Idempotence and Recovery


Research, dossier validation and offline image inspection are repeatable. Each acceptance run owns fresh fixtures, retains private failure evidence and stops only its recorded processes/containers. Never use staging or production as an acceptance fixture. Preserve direct history, applied SQL, ledger/session identities and all retained fences; this plan introduces no live migration or repair operation.

If the candidate source, compiled package, toolkit pin or relevant packaging changes after acceptance, build a new clean candidate/tag and re-evaluate the affected evidence and owner decisions. A docs-only evidence commit may cite the existing candidate without rebuilding it. Never attach one candidate's acceptance to a different image based only on matching version text or migration counts.

If publication fails ambiguously, inspect the intended tag and digest before retrying. Resume only if absent or demonstrably identical; never replace different contents at an existing source tag. A partially published or unverified artifact remains unqualified. Preserve its identity and failure record, and use a new source revision for changed content. Consumer rollout/rollback is TAN's separate operation; no rollback here deletes registry artifacts, resets databases, changes retained migration inputs, or clears fences.


## Interfaces and Dependencies


The release consumer artifact is JSON with these exact fields and meanings. Angle-bracket values illustrate the schema only; never commit them as final evidence:

```json
{
  "image": "gcr.io/tan-ng/kansoku@sha256:<registry-manifest-digest>",
  "sourceProject": "mori://shinzui/kansoku",
  "sourcePackage": "mori://shinzui/kansoku/packages/kansoku-server",
  "sourceRevision": "<full-clean-candidate-git-revision>",
  "upstreamProject": "mori://shinzui/clickhouse-migrate",
  "upstreamImplementation": "<toolkit-revision-used-by-cabal-and-nix>",
  "nativePlanSha256": "<sha256-of-replicated-native-plan-stdout-bytes>",
  "postgresPlanSha256": "<sha256-of-postgres-plan-stdout-bytes>"
}
```

The detailed companion evidence retains the direct native hash, output selectors, package identities, archive/configuration/loaded-image/registry digests, target observations, approval records, acceptance commands and run results. Keep credentials and deployment-bound replica/session/ledger secrets out of the image. Operator inventory is an independently verified deployment input, not something copied from synthetic offline UUIDs or inferred from the endpoint name.

Plans 62 and 63 own replicated configuration, schema, coordination and runtime semantics; this plan owns release evidence, exact-image binding and publication. Reuse their acceptance cases through an image execution adapter rather than fork their assertions. Keep the existing four-package toolkit cohort unless an evidence-backed remediation requires a separately qualified upgrade, verifying registry and upstream sources before selecting any new pin. Tools required for implementation are the existing Nix/Linux builder, Bun for plan metadata, Python, an isolated local Docker context, Skopeo, authenticated read-only GitHub access for lagging source checkouts, OKF for document validation, and privately supplied registry publishing credentials. None grants implicit authority to run a production migration or accept risk for the release owner.
