---
id: 49
slug: adopt-clickhouse-migrate-for-explicit-clickhouse-migrations
title: "Adopt clickhouse-migrate for explicit ClickHouse migrations"
kind: exec-plan
intention: "intention_01m5356w2megxs0ej4dzfgb20j"
created_at: 2026-10-16T20:05:39Z
provenance:
  created_by:
    model: "gpt-6.1-sol"
    harness: "codex-cli"
    at: 2026-10-16T20:05:39Z
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-16T20:10:42Z
      mode: "other"
      note: "Complete adoption plan and link the intention created with mina ci; preserve release, platform, coordination and cutover gates"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-16T21:51:05Z
      mode: "update"
      note: "Assess adoption readiness; verify published cohort and defer supported cutover pending platform fit, drain safety and legacy evidence"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-16T22:15:10Z
      mode: "implement"
      note: "Implement released dependency wiring, reviewed embedded component and native administration integration"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-17T00:55:03Z
      mode: "update"
      note: "Clarify that the unfinished review outcome predates completed native adoption; audit and correct README and operational reuse/recovery guidance"
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-16T21:51:05Z
      verdict: "comments"
      note: "Revised plan supports gated integration; immediate adoption is not recommended until deployment qualification and caller-owned safety evidence exist"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-16T22:01:56Z
      verdict: "comments"
      note: "User confirms no deployment: recommend pre-deployment adoption without legacy import; platform qualification and native recovery remain prerequisites"
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-16T22:06:28Z
      verdict: "approved"
      note: "Ready to implement fresh-install integration on the qualified development target; deployment qualification and required CI remain explicit gates"
---

# Adopt clickhouse-migrate for explicit ClickHouse migrations

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current. Promote durable implementation decisions into docs/adr/ before completion. Follow agents/skills/exec-plan/PLANS.md and agents/skills/exec-plan/ADR.md when executing it.


## Purpose / Big Picture


Replace Kansoku's filename-only shell migration runner with a packaged `kansoku-ch-migrate` executable. Operators will initialize a fresh installation from the compiled migration plan, detect changed native history after first use, and recover deliberately after an interrupted step. Normal server startup will continue to require separately applied PostgreSQL and ClickHouse migrations.

Success means the actual packaged executable can execute the reviewed 25-migration baseline on an empty owned database, repeat without application SQL, and execute an appended migration. A lost response must block ordinary execution until explicit recovery. All ClickHouse administration must share exclusion with Kansoku's existing maintenance jobs. Kansoku has not been deployed, so there is no deployed shell-runner history to import. The plan adopts the native runner before first deployment and rehearses initialization and subsequent native upgrades on disposable databases. Existing development databases are not imported; use new owned roots and retain any old data until its owner explicitly chooses disposal. No persistent data deletion, package publication or deployment is authorized by this plan update.

### Adoption recommendation — revised after deployment clarification, 2026-10-16


Adopting before first deployment is advisable: it avoids building a legacy-history importer and removes a later production cutover. Implement the native runner and make it the supported path once fresh-install, native-upgrade and failure-recovery acceptance pass on the supported environment. All four 0.1.0.0 packages are published, their downloaded source members match the release tag, and the captured Kansoku SQL matches this repository. This source/evidence review found no unresolved library defect, but did not rerun native qualification or exhaustively audit the library.

The remaining prerequisite is platform fit. The sole qualified server is an exact macOS/arm64 artifact, whereas Kansoku currently runs packaged acceptance on Ubuntu. Integration can proceed on the qualified development environment; Linux acceptance and a Linux deployment require upstream qualification. Do not silently narrow support or turn the Ubuntu gate green by skipping it. Record the intended deployment target before declaring deployment readiness. The reported startup SIGSEGV and exact-patch upgrade policy also require an operational disposition before deployment.

The safety work remains necessary for first-use failures and all future native migrations: target-wide administrator exclusion, persistent traffic fencing, explicit initialization, external drain and deliberate repair. Legacy snapshot/export, filename-history adoption and live legacy cutover are outside scope. The previous recommendation to defer adoption was based partly on an existing-installation assumption; the user's clarification supersedes it. Implementation and deployment remain distinct from this review/update session.

## Progress


- [x] M1 (2026-10-16): The released 0.1.0.0 cohort built through Cabal and Nix without relaxing bounds or disabling its deterministic checks. The hash-verified Darwin/arm64 artifact executes as 26.8.28.14; owned probes reject unsupported versions and wrong server UUIDs. Deployment target selection, crash disposition, patch review and Linux qualification remain explicit gates in `docs/evidence/clickhouse-migrate-adoption.md`.
- [x] M2 (2026-10-16): The package-owned 25-migration/257-step component passed fresh execution, assertion cleanup and an independently counted zero-application-SQL repeat after server restart and explicit evidence through the public runner. The same four-case run rejected wrong server UUID and unsupported version before application SQL. `just ch-migrations-component` passed; exact conversion verification also passed. `scripts/check_clickhouse_embedding.py` also passed extracted-archive compilation, a preserved-timestamp SQL change and inspection with all source inputs withheld (private evidence `.dev/acceptance/ch-embedding-eigw9fla`).
- [x] M3 (2026-10-16): Separate-process proofs passed at `.dev/acceptance/ch-coordination-0d_jpe0k`: backend loss left a native INSERT able to submit later; ordinary migration entry stayed blocked until real external drain; HTTP and database-side traffic admission refused; new/resumed data jobs and competing migration processes were excluded; process death retained the marker and explicit recovery completed. The integrated Cabal suite subsequently passed all 16 cases with zero skipped at `.dev/acceptance/ch-migrations-amqxcbdy`.
- [x] M4 (2026-10-16): The mounted Cabal and Nix CLI passed all 16 original boundary cases, including inspection, first use, suffix upgrade, initialization recovery, every repair operation and persisted exact receipts. The final expanded Cabal candidate passed 17 cases at `.dev/acceptance/ch-migrations-7iemkz0i`, adding an actual synchronous mutation surviving migration-client SIGKILL: ordinary up and false-attestation repair were refused, positive completion/drain then allowed zero-SQL acceptance/finalization. The final Nix candidate also passed 17 cases, zero failures and zero skipped at `.dev/acceptance/ch-migrations-fjvm1lg4`. The final full application aggregate also passed as recorded in M5.
- [x] M5 (2026-10-16): Supported entry points use the native CLI and the shell/reset entry points refuse. The final packaged migration gate passed 17 cases without skips. Full SDK-required packaged acceptance passed at `.dev/acceptance/run-b1tboun9`: 526 core examples, native recovery/limits/replay/identity, Hurl, all three telemetry modes, live SDK/Chromium, constrained reader parity and all seven administration families. The explicit SDK fixture has refreshed contracts; the unchanged SDK catalog mismatch from the first aggregate is retained in evidence. The clean-clone ordinary workflow also passed four cases. Ubuntu qualification and actual deployment remain external release gates.
- [x] M6 (2026-10-16): The clean-clone documented first-use/reuse/outage-recovery workflow passed four cases, zero skipped at `.dev/acceptance/first-use-uefk8qam`, using implementation revision `11d3f63` and the previously accepted SDK. Packaged native suffix/recovery rehearsals passed all 17 cases. Strict validation passed for 22 ADRs and 13 guides. ADR-22 and ADR-10/17/18 updates, all seven required guides, README, architecture atlas and release evidence record native identities/sessions, both-store backup/restore, exact qualification and unresolved deployment gates.


## Surprises & Discoveries


2026-10-16 aggregate acceptance: the existing [SDK checkout](mori://shinzui/kansoku-ts/packages/kansoku-js) failed its exact catalog equality assertion because its snapshot predates the server’s organization-traits v2. This is unrelated to native migration semantics. Preserved the failed aggregate and prepared an isolated clone using that project’s documented contract sync/generation/build commands against implementation revision `11d3f63`; the shared SDK checkout remains clean. The full SDK-required aggregate subsequently passed with that explicit refreshed-contract fixture. The separate clean-clone first-use proof passed using the previously accepted immutable SDK revision.

2026-10-16 documentation validation: the invoked `okf log add` command rewrote parsed log entries and omitted the existing free-form guide-adoption provenance table. Restored the complete historical log from the clean starting revision and retained only the new entry, then revalidated. Preserve that table when using the log writer in this repository; no upstream tool change is part of this plan.

2026-10-16 implementation: Cabal CLI acceptance passed 13 non-skipping cases at `.dev/acceptance/ch-migrations-w0oqza8g`, including native upgrade, exact pending-receipt handling, lost SQL/ledger response recovery, all four repair operations and original/native schema plus raw/derived/reader result parity. Separate-process coordination and the current 16-case Cabal suite subsequently passed. Both the original and expanded final Nix CLI suites subsequently passed; see Progress and the adoption evidence. Revalidated the four published archives against every tagged source member. Added exact Cabal constraints, unpacked Nix hashes, qualified binary wiring and package-owned conversion inputs. `python3 scripts/check_clickhouse_conversion.py` proves 25 original files, 253 exact byte ranges and 257 native steps with only the three reviewed adaptations. The initial Cabal/Nix boundary and public native proof passed; final full application acceptance subsequently passed as recorded in M5. The qualified Nix binary required expansion in the writable build directory because the official compressed download self-expands beside itself; immutable execution failed with `mkstemp: Permission denied`. Production target remains undecided and Linux qualification remains an upstream prerequisite. See `docs/evidence/clickhouse-migrate-adoption.md`.

2026-10-16 readiness review: Hackage's preferred-version endpoints now report 0.1.0.0 for core, embed, CLI and test-support. Upstream tag `v0.1.0.0` has tag object `4414ed9cc39e5dbabb24ecb2f42f95eb98e953fd` and dereferences to `6a795475fdbb441d1d42ac9b932ba2205d99a393`. Downloaded archives contain respectively 66, 15, 18 and 314 files; every member and the currently served Cabal metadata match the clean tagged checkout. The archive SHA-256 values below identify the published bytes, rather than the earlier qualification archives:

```text
clickhouse-migrate-0.1.0.0              e57311e6b42cfb05178e5754f4146b611acf3c9a4c880d0a6e5d41649cab8ec4
clickhouse-migrate-embed-0.1.0.0        ac869207abf920c646b0fd3cd6c70ee0e3b38b38592fce6539a474ced31cd355
clickhouse-migrate-cli-0.1.0.0          85852797b0094b0635a9082491e6c1a78d426f392cc3376292e867cc076e6747
clickhouse-migrate-test-support-0.1.0.0 917f7165f9792eae771a02db4ac80befb0d03fa8a985ae224a365d116f00d7bd
```

2026-10-16 readiness review: All 25 original SQL file hashes and the original shell-runner bytes match the released captured fixture. The compiler fit is also promising: both repositories select GHC 9.12.4, and the release requires base >=4.21 && <4.22. These checks remove publication, source-capture drift and an obvious compiler mismatch as current objections; they do not prove Kansoku's Cabal/Nix dependency solutions or live behavior.

2026-10-16 readiness review: The upstream [initial review](mori://shinzui/clickhouse-migrate/okf/reviews/concepts/REV-1) found component upgrade ordering, a whole-history response-size ceiling and recovery validation after a durable write. Its [remediation verification](mori://shinzui/clickhouse-migrate/okf/reviews/concepts/REV-2) records fixes and native regressions at `1869d639a12662856747b81f3abe0377a0a7e47c`; no executable source changed between that revision and the published tag. That verification explicitly comes from the implementing agent and is incremental. The earlier twelve-group qualification record predates those fixes and its archive hashes differ from the published artifacts. Read both records together; neither alone certifies the final Kansoku executable. Whole-history retained memory still grows with event count and configured deadlines still apply.

2026-10-16 readiness review: The [compatibility contract](mori://shinzui/clickhouse-migrate/okf/user-documentation/concepts/DOC-5) records a server startup SIGSEGV before readiness with unknown cause, alongside later successful serial qualification. Its underlying evidence is `mori://shinzui/clickhouse-migrate`, project-relative `docs/release-evidence.md` and `docs/release-evidence/2026-10-16-native.json` (artifact-level URIs pending). Passing later runs do not explain that failure. ClickHouse's [support policy](https://github.com/ClickHouse/ClickHouse/security/policy) still supports the 26.8 series and [26.8.29.10 LTS](https://github.com/ClickHouse/ClickHouse/releases/tag/v26.8.29.10-lts) is published, but the library allows only 26.8.28.14. This review did not establish whether the newer patch fixes the crash or a relevant vulnerability; qualification must not become an indefinite reason to defer required server fixes.


## Decision Log


2026-10-16: Adopt the released core, embedding and CLI libraries in a separate administrative executable. Keep the native ClickHaskell driver for application queries and writes. Migration transport is independent HTTP owned by the toolkit; replacing the application driver would add unrelated scope.

2026-10-16 implementation: Persist the preceding entry outcome and exact append receipts in the PostgreSQL session, in addition to its pre-submission marker. Explicit target/session/counter-bound reconciliation uses public exact-event observations after external drain. It cannot acknowledge unresolved or incompatible native history; that still requires explicit repair. This prevents a lost append response that later looks current from silently re-enabling ordinary up or session completion.

2026-10-16: Use one directly addressed ClickHouse 26.8.28.14 server on Apple Silicon macOS for the initial disposable integration proof, with the exact official binary from the dependency's qualification matrix. Do not broaden its version allowlist locally. This is a proof environment, not a decision to drop Kansoku's existing Linux acceptance or adopt macOS for deployment. Qualification of each claimed platform is a prerequisite to its supported execution; Cloud, proxies, replication and distributed execution remain outside the current dependency contract.

2026-10-16: Use explicit persistent maintenance sessions around ClickHouse migration commands. Reuse the PostgreSQL administrator and traffic locks, and extend persisted admission state. No process lock, advisory lock release, timeout or empty process list proves that ClickHouse has finished an earlier request. Preserve a pending-entry marker after each mutating entry and require external quiescence evidence before another entry or session completion.

2026-10-16, superseded by the pre-deployment clarification below: The initial plan proposed preserving a predecessor ledger and importing filename/time history. No deployed predecessor exists, so this work is removed. Preserve original SQL files only as review/parity inputs; native history begins with fresh execution.

2026-10-16, revised after user clarification: Adopt before first deployment and remove legacy import from scope. Retire the shell runner when the native fresh-install and recovery gates pass; deployment still requires qualification of its actual target. A development-only result must not be described as passing Linux acceptance. Future updates extend native history; no installation may run both migration systems.


## Outcomes & Retrospective


2026-10-16 implementation outcome: M1–M6 are complete on the qualified Darwin/arm64 development target. The compiled 25/257 native baseline, explicit initialization, append-only upgrade, retained PostgreSQL fence/session, exact receipt reconciliation and deliberate repair passed through Cabal and the final Nix executable. Final packaged native acceptance passed 17 cases without skips. Full service acceptance passed at `.dev/acceptance/run-b1tboun9`, including 526 core examples, native replay/limits/identity, all telemetry modes, SDK/browser delivery, reader parity and seven administrative families. The SDK-required aggregate used an isolated documented contract refresh after the first aggregate exposed an existing stale SDK catalog; no shared SDK source was changed. The separate clean-clone ordinary workflow passed four cases using the previously accepted immutable SDK. Source-archive/content-rebuild, deterministic checks, strict 22-ADR/13-guide validation, local flake checks and Seihou managed-file checks passed.

ADR-22, with ADR-10/17/18 updates, preserves the durable native/session/platform contract. Operator guides, README and architecture atlas describe explicit identities, PostgreSQL-first setup, actual drain, initialization and recovery. Raw evidence remains private; sanitized aggregate summaries are retained separately. Source implementation checkpoint is `11d3f63`; the final follow-up commit records documentation and acceptance only. Linux qualification, the intended production artifact/target, crash and intervening-patch review, and observed required remote CI remain release/deployment gates. Optional GrowthBook/Grafana integrations were not supplied for this rerun; constrained SQL/HTTP reader parity passed. No deployment, publication, persistent user-data mutation or upstream repository change occurred.

2026-10-16 pre-implementation review/update outcome (historical; superseded by the implementation outcome above): The original plan was authored and revised by gpt-6.1-sol and had no recorded review entry at the start of that pass. The pass checked the current release, source/tag identity, relevant public contracts, upstream review/qualification evidence, captured SQL hashes, local coordination paths, build configuration and ADR-10/17/18. The initial recommendation deferred supported adoption; the user then clarified that Kansoku has not been deployed. The revised recommendation was pre-deployment adoption, omitting legacy import and retaining platform and runtime safety gates. That review ran no native suite, Kansoku build, migration or persistent database operation; M1–M6 were still unfinished at that point. Accepted architecture decisions were unchanged during that review; the subsequent implementation completed the milestones and ADR updates recorded above.


## Context and Orientation


At the plan baseline, `db/clickhouse/migrate.sh` created `analytics.schema_migrations(filename, applied_at)`, sorted `db/clickhouse/migrations/*.sql` by filename, ran each whole file with `clickhouse-client --multiquery`, then inserted a ledger row. It had no checksums, per-statement checkpoints or administrator exclusion. A failed file may have partially executed; a successful file followed by a lost ledger acknowledgement may be replayed on the next invocation. A ledger is the durable record of migration history, not proof of arbitrary live schema equality. The implemented path retires that script; its original bytes are retained under `kansoku-server/migrations/clickhouse/original`.

At the plan baseline, `justfile` exposed the runner as `ch-migrate` and called it again after dropping `analytics` in `ch-reset`. `scripts/isolated_clickhouse.py:apply_migrations` also invoked it; many native scenarios used that helper without PostgreSQL. `scripts/acceptance.py` already owns both databases and applies PostgreSQL first. `scripts/first_use_acceptance.py` exercises the documented developer commands. The implemented `ch-migrate` forwards to the compiled native CLI, `ch-reset` refuses, and the shared helper now requires actual owned ClickHouse/PostgreSQL fixtures and same-root drain. `scripts/clickhouse_migrations_acceptance.py` exercises the actual binary and separate PostgreSQL sessions.

`kansoku-server/app/Migrate.hs` mounts PostgreSQL migration commands. `kansoku-core/src/Kansoku/Migrations.hs` owns the explicit PostgreSQL application component; it ended at `0006-metric-definitions` before this implementation. The additive `0007-clickhouse-administration` now creates native administrative sessions and extends traffic fencing. Its `0004-maintenance` definition creates `maintenance_fence`, `maintenance_jobs` and `require_traffic_lock()`. Append a new migration rather than editing those applied SQL bytes. `kansoku-core/src/Kansoku/Maintenance.hs:withTraffic` and `kansoku-core/src/Kansoku/Admin/Store.hs:admitMaintenanceTraffic` protect application operations. `kansoku-core/src/Kansoku/Admin/Jobs.hs` uses administrator lock `(726401,2)` and exclusive traffic lock `(726401,1)` for resumable jobs. The existing `active_job` column references a maintenance job; do not invent a synthetic foreign-key value for migration sessions.

`cabal.project` originally fixed an index state at 2026-10-14, before this release; it now selects 2026-10-16T20:50:11Z and exact 0.1.0.0 cohort constraints. `flake.module.nix` owns application package overrides and Nix outputs. `nix/haskell.nix`, `flake.nix` and `flake.lock` are Seihou-managed; extend project-specific wiring in `flake.module.nix` and preserve shared pins. The template shell supplied `pkgs.clickhouse`; older Kansoku evidence uses 26.8.2.7. The implemented default shell prepends the exact digest-qualified artifact from `nix/clickhouse-qualified.nix`. The dependency's runtime accepts exactly 26.8.28.14. `.github/workflows/check.yml` retains deterministic and packaged acceptance on `ubuntu-latest`, which is outside the dependency's qualified platform, and now adds a separate arm64 macOS source/component/packaged proof job. Neither remote job was run locally. This demonstrates an acceptance-platform mismatch, not the OS of an actual deployment; deployment inventory remains required.

The owning dependency project is [mori://shinzui/clickhouse-migrate](mori://shinzui/clickhouse-migrate). Its [core](mori://shinzui/clickhouse-migrate/packages/clickhouse-migrate), [embedding](mori://shinzui/clickhouse-migrate/packages/clickhouse-migrate-embed), [CLI](mori://shinzui/clickhouse-migrate/packages/clickhouse-migrate-cli) and [test support](mori://shinzui/clickhouse-migrate/packages/clickhouse-migrate-test-support) are separate packages. The CLI package is a reusable parser/handler library, not a ready-made migration executable. Consult the canonical [adoption runbook](mori://shinzui/clickhouse-migrate/okf/user-documentation/concepts/DOC-2), [compatibility contract](mori://shinzui/clickhouse-migrate/okf/user-documentation/concepts/DOC-5), [SQL envelope](mori://shinzui/clickhouse-migrate/okf/user-documentation/concepts/DOC-11) and [operations contract](mori://shinzui/clickhouse-migrate/okf/user-documentation/concepts/DOC-13). Resolve source with Mori before relying on APIs.

At planning time all 25 current SQL files and the shell runner matched the dependency's captured Kansoku fixture at source revision `138d9a316931bbf46781757a29ab6c7fdd90f870`. That fixture belongs to `mori://shinzui/clickhouse-migrate`, project-relative `clickhouse-migrate-test-support/test/fixtures/kansoku/` (file-level artifact URI pending). It preserves 253 source statements and defines 257 native steps. Two standalone assertions in migration 0017 become prepare/INSERT-SELECT-check/cleanup steps, adding four steps. One materialization in migration 0018 removes `mutations_sync=2` in favor of the qualified local `mutations_sync=1` policy. Recheck original hashes before reusing this mapping. Recorded upstream fixture success is useful evidence, but does not replace Kansoku's own executable acceptance.

Relevant local decisions are [ADR-10](../adr/0010-owned-executable-acceptance-environments.md), requiring actual packaged binaries, owned fresh resources, nonzero required cases and private diagnostics; [ADR-17](../adr/0017-fenced-resumable-administration-and-applied-retention.md), requiring persistent fences, shared traffic admission and preservation of failed jobs; and [ADR-18](../adr/0018-stable-reader-sql-and-real-consumer-conformance.md), requiring external SQL schedules to pause during maintenance because they bypass PostgreSQL admission. These remain binding. The accepted [ADR-22](../adr/0022-explicit-clickhouse-migrations-and-persistent-administrative-sessions.md) records the native migration/session contract and its operational limits.


## Plan of Work


### M1 — Verify the released artifacts and establish platform fit


Recheck Hackage and upstream tags before selecting versions. The 2026-10-16 review verified all four packages at 0.1.0.0 and records their published archive hashes and release identity above; the original companion-package 404 observation is superseded. Use that released cohort as the candidate, subject to rechecking for later fixes. Compare release evidence by revision: the original twelve-group matrix predates the remediation fixes, while the later incremental verification covers those changes. Build/test the published artifacts through Kansoku rather than treating earlier source-distribution hashes as release hashes. Do not substitute an untagged local checkout. Advance the dated Cabal index only enough to include the chosen packages. Add exact application constraints and Nix overrides without disabling dependency invariants or widening their declared bounds. Expose the embedding package's build driver in the developer shell so supported recipes can invoke it directly.

Record the intended server OS/architecture, direct endpoint topology, storage policy and current version before deciding the supported rollout scope. The macOS integration below can proceed independently on disposable resources. Record Linux qualification as an explicit upstream prerequisite when that is the intended deployment or acceptance platform; it does not require retaining the legacy importer scope. Record a disposition of the reported startup crash and review intervening ClickHouse fixes before choosing a production candidate; do not label it fixed because later starts passed. Define who will qualify/release support for required server patches and how that evidence reaches Kansoku. Unsupported targets or an unresolved production candidate defer execution/deployment on those targets rather than justify a local allowlist patch.

Add `nix/clickhouse-qualified.nix` and a checked-in artifact record under `db/clickhouse/qualification/`. Fetch the official aarch64-darwin 26.8.28.14 binary, validate its SHA-256 against the upstream qualification matrix, and supply consistent `clickhouse-server` and `clickhouse-client` launchers through project wiring. The inspected matrix records SHA-256 `ab5a04de4a6b705e0f1f02e6a0e0a44feff8b4455b6dfcc4a03b7571f98fbb60`; independently verify the released matrix before adopting it. Ensure PATH selects this artifact for process-compose, standalone fixtures and packaged acceptance rather than the older shell package. Unsupported platforms may still compile deterministic components but must not silently launch an unqualified server for this gate.

Add the macOS proof job alongside existing checks while evaluating adoption; do not remove Ubuntu service acceptance merely to match the dependency. For the proof job, use the explicit `macos-26` hosted label, verify `uname -m` is `arm64`, and recheck runner availability against [GitHub's runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners) before editing the workflow. Preserve immutable action revisions, timeouts and sanitized evidence. The required native gate must cover every platform claimed as supported; adding a macOS integration job does not close the existing Ubuntu gate. A deliberately narrower macOS-only support decision requires an explicit scope decision and corresponding ADR/guide changes; it is not assumed here. Do not claim a remote passing run from a local run or declare Linux qualified from macOS results. If Linux prerequisites are unavailable, record that acceptance/deployment blocker while continuing the qualified native integration.

M1 passes when both package managers resolve/build the released cohort, the selected native binary matches its recorded version/digest, an owned target probe accepts it while rejecting an unsupported version and a wrong server UUID, and the integration platform and outstanding deployment prerequisites are recorded explicitly. M1 alone does not establish deployment readiness. The initial proof candidate is 26.8.28.14; a later qualified release requires updating the candidate and evidence consistently. Platform checks and dependency locks must be reproducible without traversing `/nix/store`.


### M2 — Embed the complete reviewed migration component


Create `kansoku-server/migrations/clickhouse/manifest.json`, explicit named statement files beneath it, and `provenance.json` mapping every original filename/hash and byte range to native steps. Keep original `db/clickhouse/migrations/*.sql` unchanged. Use the captured fixture as reviewed input, not a production dependency on test-support data paths. Retain every original assertion and record all three adaptations. Component name is `kansoku`; migration names retain their existing numbered stems. The execution schedule is explicit and append-only: applying a new version must not reorder the already applied prefix.

Define `Kansoku.ClickHouseMigrations` in `kansoku-server/src/Kansoku/ClickHouseMigrations.hs`, exporting the validated component and composed plan using the public constructors and `embedComponent`. Add manifest/SQL/provenance inputs to `kansoku-server/kansoku-server.cabal:extra-source-files`. The server subtree is already a Nix source boundary, so keeping embedding inputs there makes them available to `callCabal2nix` builds. Register modules in the administrative executable and its focused test component; keep CLI/embed/test-support dependencies out of `kansoku-core` and the application's query/write code.

Use `clickhouse-migrate-embed-build` for Cabal build/test/Haddock paths that own the manifest, including developer recipes and scripts that initiate builds. Nix source hashing must include every input. Exercise preserved-timestamp SQL changes so a stale embedded executable cannot pass the gate. Source archives must build independently, and running the compiled plan must not reopen migration sources.

Before expanding the CLI, compile a representative consumer of the public runner and execute the full component on an owned qualified server under an actual serialized fixture scope. Verify the two assertion adaptations run, fresh state matches targeted schema/reader observations, and a second run submits zero application SQL. This is the early producer/consumer proof; failure here changes the mapping before later integration grows around it. M2 passes with 25 migrations, 257 native steps, exact source hashes, successful assertions and an independently observed no-op repeat.


### M3 — Coordinate migration sessions with existing maintenance


Append PostgreSQL application migration `0007-clickhouse-administration` in `kansoku-core/src/Kansoku/Migrations.hs`. Create separate migration-session state retaining a session UUID, target key, expected server UUID, ledger UUID, current administrative entry, predecessor-quiescence requirement and redacted audit/evidence references. Retain the same ledger UUID before any first-use ClickHouse submission, including interrupted initialization. Store no credentials or authored SQL in this state. Enforce a single active session for this initial single-tenant deployment.

Introduce shared coordination in `kansoku-core/src/Kansoku/Admin/Coordination.hs`. An administrative scope owns a dedicated PostgreSQL backend, takes `(726401,2)`, persists its migration-session fence before taking exclusive `(726401,1)`, and refuses entry if an existing data-maintenance job owns the fence. Update `Kansoku.Maintenance.withTraffic`, `Kansoku.Admin.Store.admitMaintenanceTraffic` and `kansoku.require_traffic_lock()` to reject an active migration session as well as an active data-maintenance job. Update `Kansoku.Admin.Jobs` so new jobs and resumed jobs cannot bypass migration-session exclusion. Keep the same lock acquisition order to avoid deadlocks. Bound acquisition and liveness checks; session loss must never be interpreted as successful release.

Expose application-owned `maintenance begin` and `maintenance finish` commands on the new executable. Begin records the operator and returns a durable session ID. Ordinary migration mutations require that ID. Before each mutating entry, persist a predecessor marker under the administrator lock; loss of the process or connection leaves it set. Re-entry after any preceding mutation requires fresh target/session-bound `--quiescent` evidence establishing that all preceding application SQL, ledger INSERTs and initialization DDL have finished or been terminated. This includes clean prior entries: a generic cleanup callback is not a drain proof. Wire the toolkit's `externallySerialized` callbacks to the shared coordinator, and its alive callback to actual retained backend ownership. Do not use the test-support host-local adapter in production.

The first migration entry must also establish quiescence of pre-session application writers and manual administrators. Acquiring the PostgreSQL traffic lock drains cooperating PostgreSQL scopes, but a ClickHouse request can survive the client/backend that held that scope. Fence admission, stop the submitting clients and establish external drain before first migration SQL; do not reserve this requirement only for a previous native-migration marker. The restart procedure below must keep old clients stopped or otherwise unable to submit afterwards. Test a delayed writer submission and a still-running server INSERT across client/backend loss, with zero migration SQL until drain is established. Liveness checks reduce submissions after detected lease loss; they are not an atomic network fence against bytes already in flight. A successor must remain blocked through this window.

Finish acquires exclusion, validates explicit predecessor-quiescence evidence, verifies the retained native ledger is current with no unresolved execution, and then atomically closes the PostgreSQL migration session. Failed inspection, unknown requests or cleanup preserve the fence. Read-only unguarded diagnostics remain available while fenced; no force-clear command is added. A PostgreSQL-only recovery command must not clear an unfinished ClickHouse session merely because its owner process disappeared.

The operator establishes quiescence outside the library. Stopping every administrative client and completely stopping/restarting the directly owned ClickHouse server while retaining its data identity is one reproducible test procedure; a timeout or empty `system.processes` read is not equivalent evidence. Application traffic stays fenced throughout. External reader schedules require operator suspension under ADR-18. This plan does not turn a PostgreSQL fence into a network fence against arbitrary manual SQL.

M3 passes using separate processes: competing migration/admin jobs cannot mutate, protected traffic returns the established maintenance response, process/backend loss preserves the fence, the old session cannot submit after scope loss, and explicit external drain plus matching recovery evidence permits re-entry. Include both Haskell session admission and database-side transaction admission, since either can otherwise bypass the fence.


### M4 — Mount the CLI for fresh initialization and native upgrades


Add `kansoku-server/app/ClickHouseMigrate.hs` and modules under `kansoku-server/src/Kansoku/ClickHouseMigration/` for configuration and coordinator adaptation. Add executable `kansoku-ch-migrate` and Nix output `kansoku-ch-migrate`. Mount the toolkit's parser/handler and renderers, preserving target/audit/repair validation. Add application-owned maintenance commands. Do not implement `legacy-snapshot` or a legacy mapping module. The toolkit's parser includes adoption commands; reject `AdoptCommand` in application dispatch before configuration, file access or handler execution, with a clear unsupported-legacy-import error. Test that it submits no SQL. Parse offline `plan` without loading PostgreSQL, credentials or live target configuration. JSON goes to stdout, redacted progress/errors to stderr, and failure produces a nonzero exit status.

Keep existing host/user/password/HTTP-port settings usable, but require a direct administrative endpoint and explicit target/server identity. Add `KANSOKU_CH_MIGRATION_TARGET`, `KANSOKU_CH_MIGRATION_ENDPOINT`, `KANSOKU_CH_MIGRATION_SERVER_ID`, `KANSOKU_CH_MIGRATION_LEDGER_ID` and `KANSOKU_CH_MIGRATION_SESSION` configuration. Store events in a dedicated `kansoku_migration_ledger` Atomic database, separate from `analytics`; application SQL must not touch the ledger namespace. Credentials remain explicit and redacted. First use requires an operator-retained UUID and initialization authorization. Recurring execution binds `ExistingLedger` and never silently creates a missing ledger. Do not auto-discover and trust a new server UUID on every run.

Before genuinely fresh initialization, refuse a predecessor ledger or application objects left by the old runner and explain how to create a new owned development stack. Missing native history cannot authorize replay over an existing schema. This refusal must not reject legitimate recovery of an interrupted native initialization under its retained ledger UUID and explicit quiescence evidence: inspect native bootstrap/history and route through the library's initialization or repair contract. Never delete an old database automatically.

Test the complete baseline on an empty database, a no-op repeat and a test-only appended migration that visibly changes a scratch table exactly once. Cover `repair retry-step`, `accept-step`, `resume` and `finalize` at the application boundary: the selected retry executes only its authorized statement, acceptance/finalization execute none, and stale attempts/positions or missing evidence refuse mutation. Exercise representative lost-response and surviving-query cases through Kansoku's configuration, serialization, reports and receipts without duplicating the dependency's entire transport suite.

M4 passes through both Cabal and Nix-built CLI binaries. A changed applied step or wrong target identity fails before application SQL; an absent recurring ledger fails without creating it; interrupted first use retains the same ledger identity; and unsupported legacy import is refused without mutation.

### M5 — Retire the shell runner and require executable acceptance


Start this milestone after the integration-platform checks in M1 and safety/acceptance proof in M2–M4. Keep any unqualified deployment/CI platform visibly blocked; no live legacy cutover is required. Replace `just ch-migrate` with argument forwarding to `kansoku-ch-migrate`; expose the required audit/session inputs rather than manufacturing evidence. Turn `db/clickhouse/migrate.sh` into a short failing retirement stub pointing to the new executable, retaining its original bytes/hash in source-conversion evidence. No supported script may execute old multiquery migration logic after the switch.

Update `scripts/isolated_clickhouse.py:apply_migrations` and its callers to use the real binary. Introduce an owned coordinator fixture composed from `scripts/isolated_postgres.py` for standalone ClickHouse-only scenarios; reuse the already owned PostgreSQL instance in `scripts/acceptance.py`. Explicitly carry target/server/ledger/session configuration and reject ambient endpoints. Each test owns fresh UUIDs and ports; do not share a coordinator state with the developer database. Resolve Nix-packaged `kansoku-ch-migrate` beside `kansoku-server` for packaged acceptance rather than invoking `cabal run` from the gate. Update `scripts/first_use_acceptance.py`, direct runner invocations and fixture subprocess timeouts for the new workflow.

The previous `ch-reset` is unsafe after introducing a separate ledger: dropping only `analytics` would leave a current ledger and cause replay to skip everything. Replace its old implementation with a refusal and instructions to create a fresh disposable stack with fresh database roots and a new ledger identity. All automated reset/replay proofs must create such owned stacks. Do not add a reset/force operation to the native ledger or apply destructive reset to a persistent target.

Add `scripts/clickhouse_migrations_acceptance.py` and `just ch-migrations-acceptance` with required, non-skipping scenarios for fresh/repeated execution, a subsequent native migration, uncertainty, recovery and competing administrators. Use original-source replay only for targeted schema/result parity on a separate fresh owned fixture, never as an operator entry point or legacy-import prerequisite. Make full `just acceptance` call the new verifier and retain the existing reader, ingestion, administrative and telemetry families. Update `.github/workflows/check.yml` for the qualified deployment scope established in M1. Failing platform checks or unavailable binaries must not become pending tests or green shell fallbacks.

M5 passes when static searches find no supported old-runner call path, both focused and full packaged native gates pass with nonzero cases, and the existing application behavior still passes after the pinned ClickHouse upgrade. Include original/native schema observations and raw/derived result parity; matching filenames alone are insufficient. Retain private request/effect evidence and sanitized summaries separately.


### M6 — Document first deployment and native operations


Update `docs/guides/getting-started.md`, `configuration.md`, `operations.md`, `administration.md`, `development.md`, `consume-clickhouse.md` and `consumer-conformance.md` with explicit PostgreSQL-first setup, qualified binary installation, maintenance sessions, retained UUIDs, fresh initialization and repair. Show the actual generated `--help` syntax and commands after the implementation exists. Explain how to retain/reconcile pending append receipts and why ordinary up does not resume interrupted work. Preserve reader role ownership and privileges, including the definer identity of reader views.

Write a first-deployment runbook covering new database roots, PostgreSQL-first setup, explicit native initialization, the three reviewed SQL adaptations, native verification and starting traffic. Rehearse a subsequent native migration under maintenance with backup, drain and recovery instructions for both stores. Explain that old development stacks must be replaced with new owned stacks and are not imported. Preserve old data until its owner chooses disposal. The shell runner is retired before deployment. For future persistent installations, rollback restores a consistent backup into a separate target with reviewed identities; it does not rewrite checksums or discard native events. No live deployment is part of this implementation's acceptance.

Create a new migration ADR with `okf id next`, preserve the profiled ADR convention, and update ADR-10/17/18 where the platform or admission contract changes. Record the final dependency versions, binary digest, source revision, command outcomes and evidence paths in `docs/evidence/clickhouse-migrate-adoption.md`. Distinguish local proof, remote CI configuration, observed remote results and deployment status. Use the new Kansoku plan/change URI as the external consumer reference to `mori://shinzui/clickhouse-migrate`; do not mark its upstream initiative complete or write to that repository merely because the local fixture passed.

M6 passes when the documented fresh-initialization and subsequent-native-migration workflows are reproduced with the packaged executable, strict ADR/guide validation passes, and no guide describes the old shell ledger as the current migration system.


## Concrete Steps


Run from the repository root, `/Users/shinzui/Keikaku/bokuno/kansoku-project/kansoku`. These commands describe implementation work; creating this plan does not execute migrations.

First locate the released dependency and verify publication. Registry discovery locates local source; Hackage and upstream tags establish what can be pinned.

```bash
mori registry list
mori registry search clickhouse
mori registry show shinzui/clickhouse-migrate --full
mori registry docs shinzui/clickhouse-migrate
mori path mori://shinzui/clickhouse-migrate/packages/clickhouse-migrate
curl -fsSL https://hackage.haskell.org/package/clickhouse-migrate/preferred.json
curl -fsSL https://hackage.haskell.org/package/clickhouse-migrate-embed/preferred.json
curl -fsSL https://hackage.haskell.org/package/clickhouse-migrate-cli/preferred.json
curl -fsSL https://hackage.haskell.org/package/clickhouse-migrate-test-support/preferred.json
git ls-remote --tags https://github.com/shinzui/clickhouse-migrate.git
```

Each selected package must report a released compatible version; a 404 leaves the corresponding dependency unresolved. Read the release archive and compare it with its tag before filling exact constraints and archive hashes. A newer release must be evaluated against this plan's APIs and target policy rather than accepted solely for its version number.

After implementing M1/M2, enter the development shell and use the content-qualified wrapper from the repository root. Its `--input` pair is the owning package directory and manifest path relative to that package.

```bash
nix develop --builders ''
clickhouse-server --version
clickhouse-migrate-embed-build --input kansoku-server migrations/clickhouse/manifest.json -- build all --enable-tests
cabal run kansoku-server:exe:kansoku-ch-migrate -- plan --json
cabal run kansoku-server:exe:kansoku-ch-migrate -- --help
```

Expected observations are version 26.8.28.14 and a JSON plan containing one `kansoku` component, 25 ordered migrations and 257 named steps. Offline plan must work with PostgreSQL/ClickHouse stopped and migration credentials unset. The new executable and wrapper recipes do not exist before the implementation milestones.

Build and test actual package boundaries after M3/M4. Stage only the intended new Nix input files before flake evaluation so Git-backed flake sources include them; retain unrelated user edits. Do not search or read `/nix/store`; execute exact output paths returned by Nix when needed.

```bash
nix build .#kansoku-server .#kansoku-ch-migrate --no-link --json
just ch-migrations-acceptance
just check
just acceptance
nix flake check --builders ''
seihou diff
```

The focused harness must report a nonzero case count with zero failures and zero skipped/pending required cases. Full acceptance must reach the existing reader and administration families, not stop after fresh migrations. `seihou diff` must show no unintended managed-file drift. The initial native integration runs on qualified arm64 macOS only. Retain existing Ubuntu service acceptance and report its qualification blocker explicitly; it does not prevent implementing the replacement on the qualified development target. Resolve qualification and run acceptance on the exact intended version/platform before deployment. A passing macOS run does not make a failing or unrun Ubuntu gate complete.

For source and documentation verification after implementation:

```bash
rg -n 'db/clickhouse/migrate\.sh|schema_migrations|apply_migrations\(' justfile scripts docs/guides
okf id list docs/adr --profile docs/adr/profile.dhall
okf id next docs/adr --profile docs/adr/profile.dhall ADR
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
just guides-check
git diff --check
```

Historical evidence and the retirement stub may mention the old runner; supported execution paths must not call it. Resolve the shared documentation/profile dependency through Mori if using an unfamiliar OKF API rather than guessing commands.


## Validation and Acceptance


The early integration check is the complete embedded plan executed through the public runner on an owned server in M2. Validate independently observed application requests/effects, not just a successful return code. Then use the mounted application CLI and packaged output for all final acceptance. New tests must focus on the migration/coordinator boundary rather than reproducing every implementation detail of the dependency.

An empty owned target reaches the complete current schema, assertions and reader projections. Repeating after explicit predecessor drain sends no application SQL. A changed applied step, reordered history, wrong server UUID, unsupported version or missing recurring ledger returns nonzero before application SQL. The compiled executable continues to inspect its plan with migration source files absent. An input change with preserved timestamps is observed by the supported build path.

An empty owned installation executes all 25 native migrations, verifies current, repeats without application SQL and executes an appended migration once. Compare targeted schema and raw/derived results with original SQL executed on a separate empty fixture. No legacy snapshot, adoption batch, prefix import or live legacy cutover is required. A database populated by the old runner is refused without mutation; create a fresh owned stack instead. The mounted application rejects toolkit adoption commands before handler execution.

Before a subsequent native migration, a surviving or delayed application write must keep migration admission blocked until external drain has stopped further submission and resolved prior work. Exercise this through the actual application coordinator. Interrupted first use must retain its ledger identity and recover explicitly rather than be mistaken for an unrelated legacy installation.

Inject response loss after a demonstrably committed application statement and after a ledger append, retain the exact pending receipt, and prove ordinary up refuses replay. A fresh process must see the same unresolved condition. Establish external drain while retaining the persistent fence, reconcile receipts read-only, then use an explicit repair request with current position/attempt. Count SQL effects to distinguish retry, acceptance and finalization. Keep original primary errors and secondary cleanup errors visible; no failure clears the fence. Terminating a process while a server query remains active must block a mutating successor.

Two administrative processes cannot mutate concurrently. Existing erasure/retention and migration sessions exclude each other. HTTP traffic, writer insertion and direct PostgreSQL admission paths respect the migration fence; session or backend death does not release it. Ordinary diagnostic history/status remain usable while fenced. Completion requires current native history plus explicit quiescence evidence. External direct readers are paused by the runbook, not falsely claimed to be covered by the PostgreSQL fence.

Final acceptance is the actual Nix executable, both stores owned by the harness, qualified native binary, repeated native migration scenarios and the existing full service suite. Keep secrets, raw source diagnostics and private snapshots outside sanitized uploads. Update code, plan and ADRs when real interface behavior differs. Do not call a configured-but-unrun remote workflow, a fixture-only proof or a pending live cutover completed deployment.


## Idempotence and Recovery


Builds, offline plan and unguarded inspection are repeatable. A fresh stack always owns new database roots and identities, and cleanup stops only its recorded processes. Preserve failed private diagnostics. Normal up applies only the compatible pending suffix and cannot authorize replay of interrupted work. Creating the coordinator schema is an additive PostgreSQL migration, not an edit to applied history.

Retain the same ledger UUID after interrupted initialization; silently generating another would change the intended target. Never clear a durable session marker based on elapsed time, process absence or a single NotObserved receipt. A request can arrive or complete later. Diagnose read-only, establish external quiescence for all predecessor requests, inspect again under exclusion, then submit only the selected native recovery operation. The persistent fence remains through any unresolved step or cleanup failure.

Use fresh owned databases for development transition and keep original SQL files as conversion evidence. Existing development data is not automatically deleted or imported. Once native initialization has begun, preserve its ledger and use native recovery; do not fall back to the shell runner. Persistent backup restoration remains a separately reviewed operator procedure on a separate target with explicit identity binding. Neither restoring only analytics nor deleting the native ledger is a rollback strategy.

All commits made during implementation must use Conventional Commits, stay on the current branch unless instructed otherwise, and include `ExecPlan: docs/plans/49-adopt-clickhouse-migrate-for-explicit-clickhouse-migrations.md` and the active `Intention:` trailer. Record model provenance with the skill's script when a later session materially changes this plan.


## Interfaces and Dependencies


`Kansoku.ClickHouseMigrations` exports the application-owned `MigrationComponent` and `MigrationPlan`. Use `ClickHouseMigrate.Definition`/`Plan` and `ClickHouseMigrate.Embed.embedComponent`; inspect the released signatures first. Keep component identity, migration/step names, SQL bytes and execution order stable after application.

`Kansoku.ClickHouseMigration.Config` constructs `TargetConfig` through validated `TargetKey`, `DirectEndpoint`, `ServerId`, `LedgerNamespace`, `LedgerBinding`, `Credentials` and bounded `HttpLimits`. It never exposes credentials through rendering. `ClickHouseMigrate.CLI.commandEnvironment` and `handleCommand` receive the compiled plan, optional configuration, provider, diagnostic policy and command policy. Use toolkit JSON/text renderers; the application owns stdout/stderr and exit codes. Observe/report types are the source of truth for native ledger state, not PostgreSQL coordinator rows.

`Kansoku.Admin.Coordination` owns the shared PostgreSQL administrative lease and persistent session state. `Kansoku.ClickHouseMigration.Coordinator` adapts that application primitive to `ClickHouseMigrate.ExclusiveAccess.externallySerialized`. Acquisition excludes all administrators for the target; alive checks actual ownership; release preserves the predecessor marker. A lease is temporary exclusive permission, while a persisted fence prevents future traffic after the lease disappears. Neither one alone establishes server quiescence. `maintenance finish` is the explicit application-level transition that verifies evidence/currentness and closes the persistent fence.

Reuse library receipt reconciliation and explicit `ClickHouseMigrate.Repair` operations rather than synthesizing ledger events or importing private modules. No `Kansoku.ClickHouseMigration.Legacy` module or legacy-adoption interface is required. The application dispatcher refuses `AdoptCommand`; inspection, native execution and repair continue to use public toolkit behavior.

Production requires the released core, embed and CLI packages plus the existing PostgreSQL coordination stack. Test-support is test-only. Keep new migration dependencies scoped to the server's administrative/test components. No new external service is required. The initial integration platform is a direct self-managed qualified macOS/arm64 server with local synchronous storage effects. M1 records deployment-platform gaps; resolving them is a deployment gate, not a prerequisite to beginning implementation. SQL and ledger writes still have no joint transaction and no exactly-once guarantee. This standalone plan has no parent MasterPlan or prerequisite unfinished Kansoku plan; it can require upstream qualification for the intended target, and no live database action is implied by completing it.

Revision note (2026-10-16): Reframed the plan around whether adoption is advisable now, verified the complete published cohort and source capture, distinguished older qualification from remediation evidence, deferred supported replacement pending deployment fit, and closed first-entry drain and partial-legacy-history gaps. The six implementation milestones remain unexecuted.

Revision note (2026-10-16, user clarification): Kansoku is not deployed. Adopt before first deployment and remove legacy snapshot/import/resume and live-cutover work from M4–M6. Retain fresh-schema parity, native upgrade/recovery, coordination and explicit platform qualification; existing data is never implicitly disposable.

Revision note (2026-10-16, implementation-readiness check): Removed two stale statements that placed deployment qualification before implementation/replacement. Implementation can begin on the qualified development target; the exact deployment combination and all required CI results remain explicit release/deployment gates.
