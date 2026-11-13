# ClickHouse migration adoption evidence

Plan: [49](../plans/49-adopt-clickhouse-migrate-for-explicit-clickhouse-migrations.md).
External consumer reference: [Kansoku Plan 49](mori://shinzui/kansoku/plans/49-adopt-clickhouse-migrate-for-explicit-clickhouse-migrations).
Implementation source checkpoint: `11d3f63` on the existing `master` branch.
Qualified local aggregate validation is complete. No deployment or persistent user-data operation is recorded.

## Hackage release adoption on 2026-11-12

All four packages from [mori://shinzui/clickhouse-migrate](mori://shinzui/clickhouse-migrate)
now use the published `0.2.0.0` cohort in Cabal and Nix. The Git source override
has been removed. Cabal's index-state advances to `2026-11-09T04:23:15Z`, after
the complete cohort was uploaded. Nix uses independently hashed Hackage archives
with upstream dependency bounds and deterministic checks enabled.

The authoritative Hackage version endpoints and upstream `v0.2.0.0` tag were
verified. The tag object is `3975904ecb3926749d0077e7ce0053823a01b7a7`, pointing
to `87f6f129242ef6f37011685ed33b7776cbd4d9b4`. Every published archive file
matches that tag byte-for-byte. Compared with the previous `0.1.1.0` source pin,
the release changes package versions, internal dependency bounds, changelogs and
documentation; the implementation is identical. The source-archive proof now
extracts the four pristine Hackage packages alongside the six workspace/pinned
source archives.

| Package | Published archive SHA-256 |
| --- | --- |
| clickhouse-migrate | 1c0eb282ac85f4b862ce5e6c6518a084fdfcdbe9300c2eaf443236fa01ce4bec |
| clickhouse-migrate-embed | 428265ae4632e327ffc3f784873659b9dce4e1e4faa23afff2e9a9fbb85fb3e8 |
| clickhouse-migrate-cli | bd618053e8d8eff2eebc9d13622960bb3778e32d86bdb200223499fabe67953a |
| clickhouse-migrate-test-support | 4c7e1b08a7e0b80a6fbb02e8d7216558a785f1695a46eb0026081f946540cb0c |

The Nix production and upgrade-proof builds pass. Comparing the new packaged
CLI with the previous compiled CLI preserves every offline JSON field for both
histories: direct has 26 migrations / 264 steps, replicated has 26 / 261.
The private before/after plans are retained under
`.dev/acceptance/clickhouse-migrate-hackage-0.2.0.0-1iqb5pwt`.

The complete Cabal workspace build with tests enabled passes, as do the
deterministic core/client/probe suites (524 / 22 / 4 cases). The actual
Nix-packaged CLI/coordinator suite passes all 18 cases with zero failures or
skips at `.dev/acceptance/ch-migrations-50ekm89x`. Both direct and replicated
source-conversion checks pass; formatting is clean.

The Hackage test-support package passes the four native component cases:
26 migrations / 264 steps, assertion cleanup, wrong-target/version refusal and
zero-SQL repeat after restart. The topology configuration suite passes all 13
cases. The source-archive proof passes at `.dev/acceptance/ch-sdist-tos3vgcb`:
all ten extracted workspace/pinned/published packages build the production CLI,
and both offline plans pass with migration inputs withheld.

The independent embedding proof passes at `.dev/acceptance/ch-embedding-pej7xc3u`:
the extracted server archive compiles against the published libraries, both
direct and replicated SQL edits with preserved timestamps trigger the expected
checksum changes, and the compiled executable still runs with source inputs
withheld. Validation logs are retained with the private before/after plans above.

## Historical source upgrade on 2026-11-07

All four packages from [mori://shinzui/clickhouse-migrate](mori://shinzui/clickhouse-migrate)
now use the `0.1.1.0` source candidate at immutable upstream revision
`0e75c4cc1303423ba561370ee5795aa0cf2455b7`, replacing `0.1.0.1` at
`00afa9fa1038f2b90e7bc5f041ac1b56649b639f`. Cabal and Nix select the same
revision; the Nix unpacked source SHA-256 is
`05f08nbqj5cq3yq0nxh10hssfgnp7bf03j8f8jc7xx33430rr6nk`.

The authoritative Hackage version endpoints for all four packages still report
only `0.1.0.0`; upstream tags still contain only `v0.1.0.0`. The selected revision
was the upstream `master` head when checked. This is a source candidate upgrade,
not a published Hackage release. The existing Cabal index-state is retained.

Upstream adds exact Altinity `26.3.60.10002.altinitystable` qualification,
replicated targets and checksum v2. Kansoku retains its direct-server target
configuration and exact SQL inputs. Direct checksum v1 remains compatible;
offline plan JSON gains additive v2 checksum fields. The historical qualification
results below describe their original candidates.

Upgrade verification passed the Nix production and upgrade-proof package builds,
the source-conversion check (25 original files / 253 exact ranges / 257 native
steps), formatting and strict guide validation. An offline comparison with the
previous compiled CLI preserved every existing JSON field, all 25 migration v1
checksums and all 257 step v1 checksums. Only the additive `checksums` objects
are new. Private before/after plans are retained under
`.dev/acceptance/clickhouse-migrate-upgrade-0.1.1.0`.

The complete Cabal workspace build with tests enabled and the deterministic
core/client/probe suites passed. The actual Nix-packaged CLI/coordinator suite
passed all 17 cases with zero failures and zero skips at
`.dev/acceptance/ch-migrations-v1ntv0vy`, including fresh/repeated migrations,
recovery, failure boundaries and administrative coordination. The public native
component suite also passed all four cases: full baseline execution, assertion
cleanup, wrong-target/version refusal and zero-SQL repeat after a same-root restart.

Archive checks passed at `.dev/acceptance/ch-embedding-55ebyafb` and
`.dev/acceptance/ch-sdist-kz_z__eo`. The first compiled an extracted server archive,
observed a preserved-timestamp SQL edit and ran with inputs withheld. The second
built the production CLI exclusively from all ten extracted workspace/pinned
package archives and verified its offline 25-migration/257-step plan after
withholding migration inputs.

## Release identity

On 2026-10-16 all four Hackage preferred-version endpoints reported 0.1.0.0.
The upstream `v0.1.0.0` tag object is `4414ed9cc39e5dbabb24ecb2f42f95eb98e953fd`,
pointing to `6a795475fdbb441d1d42ac9b932ba2205d99a393`.
Every downloaded source archive member was compared byte-for-byte with that tag.
The producer is [mori://shinzui/clickhouse-migrate](mori://shinzui/clickhouse-migrate).

| Package | Published archive SHA-256 |
| --- | --- |
| clickhouse-migrate | e57311e6b42cfb05178e5754f4146b611acf3c9a4c880d0a6e5d41649cab8ec4 |
| clickhouse-migrate-embed | ac869207abf920c646b0fd3cd6c70ee0e3b38b38592fce6539a474ced31cd355 |
| clickhouse-migrate-cli | 85852797b0094b0635a9082491e6c1a78d426f392cc3376292e867cc076e6747 |
| clickhouse-migrate-test-support | 917f7165f9792eae771a02db4ac80befb0d03fa8a985ae224a365d116f00d7bd |

Nix's `callHackageDirect` uses unpacked recursive hashes, recorded in
[flake.module.nix](../../flake.module.nix), rather than these compressed archive hashes.
Dependency bounds and deterministic dependency checks remain enabled.

## Historical platform and production disposition (2026-10-16)

The integration host is Darwin/arm64. The direct self-managed proof uses
ClickHouse 26.8.28.14, local synchronous storage and a new private data root.
The binary SHA-256 is `ab5a04de4a6b705e0f1f02e6a0e0a44feff8b4455b6dfcc4a03b7571f98fbb60`.
The macOS download self-expands beside its executable on first use. The Nix
package verifies the compressed download, expands it in the writable build
directory with `server --version`, then installs that result. No server is started
during package construction. Direct execution of the compressed artifact from an
immutable output fails with `mkstemp: Permission denied`.
The checked-in [matrix](../../db/clickhouse/qualification/matrix.json) records the
upstream qualification scope and unknown-cause pre-readiness startup SIGSEGV.
A startup failure fails acceptance; no automatic retry makes it pass.

At that historical checkpoint, the deployment OS/architecture, endpoint, storage and version had not been
selected. Ubuntu remains an existing required acceptance target with unresolved
upstream native qualification. A macOS proof does not qualify Linux or deployment.
GitHub's [runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)
was checked on 2026-10-16 and lists `macos-26` as arm64.
Remote workflow results have not been observed in this implementation.

The production candidate remains unresolved. 26.8.29.10 LTS is recorded upstream
as published but unqualified; neither its relevant fixes nor the earlier crash's
cause are established by this integration. Before deployment, the Kansoku release
owner must choose the actual target and review intervening security/bug fixes.
The upstream migration-toolkit maintainer must qualify and release support for
that exact artifact/platform; Kansoku then updates its cohort, binary matrix and
owned acceptance evidence together. Do not locally widen the version allowlist
or defer a required security fix indefinitely to keep this pin.

## Conversion verification

`python3 scripts/check_clickhouse_conversion.py` passed: all 25 original files,
253 contiguous exact source byte ranges, three recorded adaptations and the
257-step native manifest match. Original SQL is unchanged. The package owns its
inputs under `kansoku-server/migrations/clickhouse`; there is no runtime dependency
on the producer's test-support fixture paths.

## Verified integration boundaries

The public consumer passed `just ch-migrations-component`: 25 migrations / 257 native steps,
assertion cleanup, wrong UUID/version rejection and an independently counted zero-SQL repeat
after explicit same-root restart. `scripts/check_clickhouse_conversion.py` verifies all source
bytes. `scripts/check_clickhouse_embedding.py` passed extracted server-archive compilation,
preserved-timestamp rebuild detection and execution with source inputs withheld; private evidence
is `.dev/acceptance/ch-embedding-eigw9fla`.

The complete 16-case CLI boundary suite passed through Cabal at
`.dev/acceptance/ch-migrations-amqxcbdy` and actual Nix output binaries at
`.dev/acceptance/ch-migrations-6ur7jq8g`, each with zero failures and zero skipped cases.
It covers fresh/repeated history, a compiled native suffix, changed applied definitions,
wrong identity, legacy refusal, native/original schema plus raw/derived/reader observations,
interrupted initialization, selected retry/accept/resume/finalize, exact pending receipt handling,
competing administrators and HTTP/database admission across backend/process loss. A late native
INSERT remained able to submit after its cooperating PostgreSQL backend died. A killed migration
process retained its fence and recovered only after explicit drain and selected repair.

These are local integration results. Final candidate packaged service acceptance and checks
passed as recorded below; no remote run or deployment is claimed. Private raw diagnostics stay under
`.dev/acceptance`; only count/status summaries belong in sanitized uploads.

The expanded final Cabal candidate passed 17 cases at
`.dev/acceptance/ch-migrations-7iemkz0i`. The additional case kills the actual migration CLI
while its synchronous native mutation remains active. Ordinary up refuses, and even an
adversarial false quiescence assertion cannot override positive active-query evidence.
After positive mutation completion and real external drain, acceptance/finalization send zero
application SQL and retain exactly one effect. Selected retry/resume/accept/finalize requests
are independently counted at the application boundary.

The owned fixture helper passed initialization, same-identity repeat, ambient-target refusal,
and retired-runner/reset refusal at `.dev/acceptance/ch-owned-helper-2ws3i4qg`.
Strict validation passed for 22 ADRs and 13 guides, and `seihou diff` reported no managed drift.
The canonical consumer Plan URI above is intentionally retained; the current Mori registry
reported it unresolved, while the local plan/frontmatter and project identity exist.

The final Nix candidate passed all 17 cases, zero failures and zero skipped, at
`.dev/acceptance/ch-migrations-fjvm1lg4`. Production package identity is
`xi6rcpslg0ddc4r34g1x7mjcfgzykias-kansoku-server-0.1.0.0`; the separate private
proof package is `qayi24jm7najzxw9v3ap4d6aab0danva-kansoku-server-0.1.0.0`.
`scripts/check_clickhouse_sdist.py` passed at `.dev/acceptance/ch-sdist-s7eeb5jv`: all
six workspace/pinned source packages were archived, extracted and used to build
the actual production CLI. Its offline 25/257 plan still worked after all migration
inputs were withheld. The earlier preserved-time proof remains independently applicable.

`just check` passed: 409 core examples, 21 API examples, four probe tests, all
three seven-example HTTP semantic modes and four lifecycle modes. Local
`nix flake check --builders ''` passed both checks on aarch64-darwin; it does not
validate incompatible systems. Final full service/SDK and clean-clone workflow
results are recorded below.

An initial full SDK-required aggregate at `.dev/acceptance/run-jgv8fee5` failed
the SDK's exact schema-catalog assertion: its checked-in catalog omitted the
server's already-existing organization-traits v2. Native 17-case, 526-example
core, replay, query limits, public metrics and fixture-isolation checks had passed.
The shared SDK source checkout was not changed. An isolated clone of
[mori://shinzui/kansoku-ts](mori://shinzui/kansoku-ts), revision
`33d6ab8df99f7b4bb1eb5caca7df8a9c346966c6`, was prepared at
`.dev/acceptance/sdk-contract-j9sgq4jh/sdk` using its documented `sync-contracts`
command against Kansoku `11d3f63`, generated schema and normal package build.
The subsequent SDK-required aggregate uses this explicit refreshed-contract
fixture; it is not evidence that the SDK's unchanged shipped catalog is current.

The documented clean-clone ordinary workflow passed all four cases with zero
skips at `.dev/acceptance/first-use-uefk8qam`. It cloned Kansoku `11d3f63`, used
the default qualified shell, explicitly migrated PostgreSQL, retained native
identities/session counters, performed actual same-root drains, initialized
257 steps and repeated with zero application SQL. It then used the previously
accepted immutable SDK `0a4eea715b5f34fad8593e3dfd123ce407976c95` for ingestion,
duplicate retry and recovery of accepted events queued during a ClickHouse outage.
Owned stack shutdown checks passed. Its summary retains exact source identities.

## Final aggregate outcome

The SDK-required full gate passed at `.dev/acceptance/run-b1tboun9`, using the
actual Nix production binary and the explicit refreshed-contract fixture above:

```bash
KANSOKU_SDK_PROJECT="$PWD/.dev/acceptance/sdk-contract-j9sgq4jh/sdk" \
KANSOKU_REQUIRE_SDK=1 nix develop --builders '' -c just acceptance
```

It passed the 17-case native migration suite; 526 native core examples; four
production probe tests; native recovery, query limits, replay and identity;
Hurl and ingestion; all metric/trait/cohort/custom-metric and fixture-isolation
families; 22 Haskell client examples; three telemetry/privacy modes; SDK trait
tests in each mode; three SDK protocol cases; nine live SDK cases; two
vanilla/React examples; eight Chromium identity/handoff/bot cases; six Chromium
beacon cases; constrained reader privileges and all three SQL/HTTP parity recipes;
metrics-disabled behavior; and all seven packaged administration families.
Required scenarios reported no skips. Private evidence and sanitized summaries
are separate under that run root. Optional GrowthBook/Grafana paths were not
supplied; their real-consumer integrations were not rerun or claimed here.

All six plan milestones are implemented and locally verified within the qualified
development scope. The shared SDK source checkout remains clean. Existing Ubuntu
acceptance remains required and unqualified, remote CI has not been observed,
and no deployment had occurred at that checkpoint. The current target selection is below. Crash disposition and
intervening patch/security review remain production gates. No producer repository
was changed and no upstream initiative is declared complete.

## Replicated migration qualification (plan 62, 2026-11-08)

The source cohort remains `0e75c4cc1303423ba561370ee5795aa0cf2455b7`
(`0.1.1.0`, source candidate) from `mori://shinzui/clickhouse-migrate`.
The owned fixture uses Altinity `26.3.60.10002.altinitystable`, Linux/arm64,
`docker.io/altinity/clickhouse-server@sha256:7e72405bf85df6d163205ee2e56251ebc35daf6dc71142f58bdee7a461690ffb`.
These observations use a Darwin/arm64 application client with Linux containers;
they do not certify a Linux application client, a managed endpoint, or deployment permissions.

The independently built `2008b67` CLI supplies
`kansoku-server/test/fixtures/clickhouse-direct-plan-2008b67.json`.
`scripts/check_clickhouse_plans.py` recursively compares every offline field and
checks the original migration tree against that revision. Direct remains 25/257;
replicated is 25/254. Conversion evidence checks three omissions, 31 engine
adaptations and one `EMPTY` modifier on the already-empty 0020 schema inference.
The original SQL and manifest remain byte-identical.

The deterministic selector suite passes 13 cases. The retained-session upgrade
proof uses separately built `2008b67` PostgreSQL/ClickHouse CLIs, then applies the
new migration and compares every legacy field, fence, counter and receipt. A
changed topology refuses access without native application SQL.

The full Cabal CLI proof passes the 25/254 migration lifecycle, both Memory
assertion groups, matching initialized recovery, guarded currentness verification,
retained/released fences, zero-SQL repeat with unchanged ledger events, a replicated
append-only suffix, and changed-definition refusal. Direct and replicated controls
use the same app owner and exact server candidate. Table/column definitions, keys,
TTLs and view SELECTs agree after only engine-family and generated replica metadata
normalization; seeded raw, rollup and reader results agree independently. Both
replicas retain equal ordered v2 events and seeded upgrade rows. Ten fresh rejection
fixtures all refuse with a retained fence and zero application requests.

All 72 required existing query/metrics examples pass with zero failures or pending
cases. Their destructive fixtures use an explicitly separate synchronous native-test
account, complete results, no DDL status result set, disabled replicated table
deduplication windows after baseline parity capture, and owned data cleared between
groups. The restricted migration app account retains its constant engine restriction.
These controls preserve the reader assertions and do not qualify production block
deduplication, writers, or data-maintenance operations (see ADR-10 and IR-11).

Independent source packaging extracts all ten workspace/source-cohort packages,
builds the real CLI, withholds migration inputs and inspects both offline histories.
The preserved-time embedding proof mutates each history separately and confirms the
other history is unchanged. `just check` passes (500 core and 21 client deterministic
examples, four probes, generated contracts, formatting, strict documentation and
telemetry lifecycle checks). The direct native component gate passes four cases; the
Nix packaged direct CLI/coordinator gate passes 17 cases, zero failures/skips.

The final combined recipe exits zero: 13 owned cases plus one Nix-packaged full
lifecycle case, zero failures/skips. The packaged run independently repeats all
72 required query/metrics examples with zero failures/pending. It resolves the
packaged executable from Nix JSON outputs. All owned fixture containers and child
processes are stopped after acceptance. Commands from the repository root:

```bash
nix develop --no-write-lock-file -c just check
nix develop --no-write-lock-file -c just ch-migrations-component
nix develop --no-write-lock-file -c just ch-migrations-source
nix develop --no-write-lock-file -c just ch-migrations-acceptance
CLICKHOUSE_MIGRATE_DOCKER_CONTEXT=colima nix develop --no-write-lock-file -c just ch-migrations-replicated
```

No managed endpoint, production permissions, production data, or deployment
repository was contacted or changed. General replicated runtime maintenance and
Linux-client deployment acceptance remain separate qualification gates.

## Current TAN production disposition (2026-11-08)

Select Altinity.Cloud `tan-production`, version `26.3.60.10002.altinitystable`, one
shard/two replicas, HTTPS `https://tan-production.topagentnetwork-5os8y.altinity.cloud:8443`
and native TLS on the same host at explicit port `9440`; application platform is
Linux amd64. See the [source-backed target dossier](tan-production-target.md),
[machine-readable release evidence](tan-production-release.json) and unchanged
historical fixture plus separate deployment target in the qualification matrix.
Plans 62 and 63 are complete within their recorded Darwin-client/Linux-arm64-server
scope. The requesting release owner explicitly approved all four residual risks
on 2026-11-08; [the actual decision](tan-production-release-decision.md) retains
identity, date, context, reasons and candidate binding. These are accepted risks,
not fixes or managed certification. The preserved Linux amd64 image is published
and readback verified as `gcr.io/tan-ng/kansoku@sha256:a78b668dbc98567bfd2d031f9b3aaf3a22b1f3f4bd4fbfd3ca3605dfbf98d213`.
The [final eight-field artifact](tan-production-qualified-artifact.json) maps its
native hash to the replicated plan; the direct hash remains in detailed evidence.
All three captured plan byte streams, filesystem layers and source labels match
the approved source `7c1132d74c8cb4fd5702b3ba8394aa1f52f66780`. Apple Container
uses Rosetta; full replicated database tests inside this image remain an explicitly
accepted gap. TAN retains production inventory/storage/grant/drain and managed
rehearsal obligations. No production migration or infrastructure change occurred.
