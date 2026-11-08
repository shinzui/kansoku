# TAN production target dossier

Selected on 2026-11-08; release-owner acceptance recorded on 2026-11-08. The machine-readable record is
[tan-production-release.json](tan-production-release.json). All four residual risks were explicitly approved by the requesting release owner; see the
[retained decision](tan-production-release-decision.md). This does not certify the managed cloud.

## Infrastructure and consumer contract

Read-only GitHub Contents API checks on 2026-11-08 re-established the master heads:
`mori://tan/tan-infrastructure` at `ae353d303c3efa078f146de48d9ed1d2812b05cd`,
project-relative `altinity/clusters/production.json` (artifact-level URI pending),
and `mori://tan/tan-app-infrastructure` at
`108a5d918d2e51f58c8cb73c8e9f080e3af6abf9`, project-relative
`pulumi/apps/kansoku/qualified-artifact.json` (artifact-level URI pending).
The consumer record still has exactly the eight fields specified in Plan 64;
its older staging digest and dependency revision do not identify this release.
The requesting plan remains
`mori://tan/tan-app-infrastructure/plans/45-onboard-kansoku-to-production-on-the-replicated-clickhouse-cluster`.

The declared target is Altinity.Cloud `tan-production`, ID `11282`, environment
`topagentnetwork-5os8y`, version `26.3.60.10002.altinitystable`, one shard/two replicas.
HTTPS is `https://tan-production.topagentnetwork-5os8y.altinity.cloud:8443`;
native TLS uses that host on explicit port `9440`, with normal certificate verification.
The application image must be Linux amd64. The managed server architecture and
binary digest have not been observed. Declared infrastructure is `n2d-standard-4`,
150 GB `pd-ssd`, zones `us-west1-b`/`us-west1-c`, secure transport and managed Keeper.
Backup context from
`mori://tan/tan-infrastructure/plans/6-bring-the-production-clickhouse-cluster-on-altinity-cloud-into-the-repository`
records 05:00 UTC daily backups, seven retained, without restore proof.
Provisioned SSD does not prove healthy writable Local default storage or required fsync.

## Crash evidence and accepted residual risk

The producer `mori://shinzui/clickhouse-migrate`, project-relative
`docs/release-evidence.md` and `docs/release-evidence/2026-11-07-altinity-10002.md`
(artifact-level URIs pending), retains two failed Darwin native startup attempts.
The original 26.8.28.14 download SHA-256 is
`ab5a04de4a6b705e0f1f02e6a0e0a44feff8b4455b6dfcc4a03b7571f98fbb60`.
The later Nix attempt failed at `lts-native/example` before readiness with SIGSEGV.
Neither failed attempt is an Altinity managed server observation. Separately passing
runs and a platform difference do not explain or fix either crash. Owner acceptance
must name this residual uncertainty or evidence must establish a resolution.

## Patch/security review, 2026-11-08

[Altinity 26.3 release notes](https://docs.altinity.com/releasenotes/altinity-stable-release-notes/26.3/)
identify 10002 (2026-11-05) as a fix for CVE-2026-116366 compared with the earlier
qualified 10001. They state that security changes are temporarily withheld from
public source; the public tag cannot attest every byte of the published binaries.
The authoritative GitHub tag API confirms `v26.3.60.10002-1.altinitystable` at
`4d1d8cad81573563e3abece05c39fb4903fce73f`. This is a public baseline identity,
not the managed server digest or a complete reproducible-source claim.

The [ClickHouse security changelog](https://clickhouse.com/docs/resources/changelogs/security-changelog)
describes CVE-2026-116366 as possible unauthenticated network RCE and lists upstream
fixes in 26.3.62.3, 26.8.36.3, 26.9.27.3 and 26.10.3.7. Altinity's exact selected
patch declares its own backport; numerical comparison across vendor versions is
insufficient. The historical 26.8.28.14 fixture predates the listed upstream 26.8
fix and must not be presented as the production security baseline. The
[security policy](https://github.com/ClickHouse/ClickHouse/security/policy) lists
26.3 as supported for security updates; the public
[advisories](https://github.com/ClickHouse/ClickHouse/security/advisories) are not
an exhaustive assessment. The owner accepted the vendor disclosure/source limitation and deployment exposure, with
ongoing version/security review retained as an onboarding obligation. Fixture success proves no absence of vulnerabilities.

## Managed endpoint and coverage: accepted residual risks

Every migration connection must admit an expected UUID, exact supported version,
cluster and required settings before application/ledger SQL. A retained independent
inventory must establish every expected replica; endpoint names and counts cannot.
Bounded observation can fail if routing never exposes a required replica. A lost
connection after submission can leave an uncertain outcome requiring retained
fences and explicit recovery. Admission fails closed on mismatch, but does not
certify routing, uptime, durability or cluster-wide drain. TAN must verify storage,
permissions, complete inventory, external drain and the managed rehearsal itself.
Native writer/read-back/maintenance guarantees are owned by Plan 63; HTTP migration
admission is not their substitute.

Plans 62 and 63 passed with Darwin clients and Linux arm64 owned servers, including
Nix application executables and a separate Cabal native test driver. They do not
prove execution from the Linux amd64 application image. Image offline smoke checks
have no database access. Full image behavior requires an adapter for the existing
scenario families, or a dated candidate-specific owner acceptance of the precise
remaining platform/image gap. The endpoint always requires explicit owner acceptance.

A disposition must retain owner, UTC date, actual decision source, residual risk,
reason, candidate archive SHA-256 and loaded image ID. No model provenance or generic
implementation permission supplies that decision. No synthetic offline UUID belongs
in TAN's inventory. The actual decision is retained in [the approval record](tan-production-release-decision.md); publication and digest-addressed readback verification are complete; see the [final artifact](tan-production-qualified-artifact.json).

## Accepted candidate and release-owner decisions

The clean candidate is `7c1132d74c8cb4fd5702b3ba8394aa1f52f66780`, tag
`gcr.io/tan-ng/kansoku:7c1132d74c8c-p1`. Its preserved Docker archive SHA-256 is
`db8197a8161e5cf52fdd1c7a57939d19590bcbd3c7886a84f311e898264f8e86`;
the Apple local OCI index is
`sha256:783b91e441775a30189cd6d4988cfa4b5dce5fc16756546331981a112b846790`.
These are prepublication identities. The [image report](tan-production-image.json)
and [draft artifact](tan-production-artifact-draft.json) retain all three hashes.
The draft's `image: null` deliberately prevents its use as a deployment record.
No package, application source or dependency pins changed since the passing
Plan 62/63 checkpoint `a40b20a`.

All four decisions below were **accepted** by the requesting release owner on
2026-11-08. The [approval record](tan-production-release-decision.md) retains the
actual user response, context, recorded UTC date, approving participant identity
and candidate binding. The rationale column retains the reasons presented for that approval. The final registry digest is connected to this candidate through retained publication and exact readback receipts.

| Gate | Accepted residual risk | Accepted rationale |
| --- | --- | --- |
| Startup crash | Two unexplained Darwin native pre-readiness SIGSEGV attempts; neither later success nor platform difference proves a fix. | Accept the unresolved developer-fixture startup risk for this managed Altinity deployment, retaining failures and requiring any future startup failure to fail its acceptance run. |
| Patch/security | Vendor 10002 declares CVE-2026-116366 fixed, but some security source is temporarily withheld; managed binary digest has not been observed. | Select the vendor's exact security-fixed patch with its disclosed source limitation, retain exact-version admission, and require TAN to verify deployed version and follow vendor security updates. |
| Linux application image | Native Linux VM and Rosetta image smoke pass; full replicated database scenarios ran with Darwin clients/Linux ARM64 servers, not this Linux amd64 image. All image-based migration lifecycle, fault/recovery, native query parity, maintenance/drain/rebuild, writer/retry/deduplication and synchronized read-back scenarios remain omitted. | Accept this precisely bounded packaged-image/platform coverage gap using unchanged passing prerequisite behavior, while retaining TAN's managed migration and event-flow rehearsal obligation. |
| Managed endpoint | Single load-balanced endpoint remains uncertified; per-connection UUID/version/cluster/settings admission fails closed but cannot guarantee routing, availability, durable storage or complete drain. Missing replica exposure can fail bounded observation; connection loss can leave uncertain work fenced. | Accept the uncertified endpoint with independently verified full replica inventory, storage/fsync and grants, normal TLS verification, external drain and explicit uncertain-outcome recovery required during TAN onboarding. |

Apple Container 1.5.0 runs the amd64 image with Rosetta and no attached networks or
host mounts. All three exact plan outputs repeat byte-for-byte; the direct history
also matches the retained compatibility fixture. The historical Colima OOM failure
is retained in FRIC-18, resolved by Apple Container. Colima is forbidden for future
work by repository instructions. These smoke checks do not execute a live database.

## Published handoff

The verified immutable image is `gcr.io/tan-ng/kansoku@sha256:a78b668dbc98567bfd2d031f9b3aaf3a22b1f3f4bd4fbfd3ca3605dfbf98d213`.
Copy the exact eight fields from
[tan-production-qualified-artifact.json](tan-production-qualified-artifact.json).
The detailed [release record](tan-production-release.json),
[registry receipt](tan-production-publication.json) and
[readback report](tan-production-readback.json) retain separate identities and scope.
The earlier draft remains historical and intentionally unusable (`image: null`).

The owning canonical project is `mori://shinzui/kansoku`; these are repository-local
evidence files under `docs/evidence/` (artifact-level URIs pending). The release
source remains `7c1132d74c8cb4fd5702b3ba8394aa1f52f66780`; later evidence commits do
not change image contents. TAN's staging rollout, full production UUID inventory,
storage/fsync/grant checks, retained operation inputs, fresh ledger creation and
managed migration/event-flow rehearsal remain TAN onboarding work. No deployment
repository or database was changed by this release.

The publication evidence commit is `4a87822faa9e8fa8832f31551e245f21f9a28bb4`, distinct from the image source commit. It contains the completed plan, owner decision, final qualified artifact and registry/readback receipts. Later metadata-only bookkeeping does not rebuild or replace the image.
