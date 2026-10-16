# ClickHouse migration adoption evidence

Plan: [49](../plans/49-adopt-clickhouse-migrate-for-explicit-clickhouse-migrations.md).
External consumer reference: [Kansoku Plan 49](mori://shinzui/kansoku/plans/49-adopt-clickhouse-migrate-for-explicit-clickhouse-migrations).
Implementation is in progress. No deployment or persistent database operation is recorded.

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

## Platform and production disposition

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

The actual deployment OS/architecture, endpoint, storage and version have not been
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
remain in progress; no remote run or deployment is claimed. Private raw diagnostics stay under
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
