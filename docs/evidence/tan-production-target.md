# TAN production target dossier

Selected on 2026-11-08; release remains pending. The machine-readable record is
[tan-production-release.json](tan-production-release.json). No owner decisions
have been supplied. This dossier is preparation, not managed-cloud certification.

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

## Crash disposition remains pending

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
an exhaustive assessment. Owner review of vendor disclosure, deployment exposure
and future updates remains pending. Fixture success proves no absence of vulnerabilities.

## Managed endpoint and coverage disposition remain pending

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
in TAN's inventory. Publication and IR-12 completion remain blocked until the gates pass.
