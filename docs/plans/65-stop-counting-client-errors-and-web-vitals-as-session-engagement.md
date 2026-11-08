---
id: 65
slug: stop-counting-client-errors-and-web-vitals-as-session-engagement
title: "Stop counting client errors and web vitals as session engagement"
kind: exec-plan
created_at: 2026-11-08T04:31:52Z
intention: "intention_01m6wpsv48e0sa0kj91xsb0tf7"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-11-08T04:31:52Z
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-08T05:33:25Z
      mode: "implement"
      note: "Implement diagnostic classification, fenced retained-session correction, and acceptance evidence"
---

# Stop counting client errors and web vitals as session engagement


This ExecPlan is a living document. Maintain Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective during implementation. Follow `agents/skills/exec-plan/FRICTION.md` for implementation friction and distill durable decisions into the existing ADRs before completion.

## Purpose / Big Picture


Enabling automatic client error or Web Vitals collection must not turn a one-page visit into an engaged visit. After this change, a session containing one distinct `page_view` plus any `client_error` or `web_vital` events remains a bounce. A visitor action such as `purchase` still removes the bounce. These diagnostic events continue to contribute their timestamps to observed session duration.

Implement the request in `docs/improvement-requests/stop-counting-client-errors-and-web-vitals-as-session-engagement.md`, including correcting retained session aggregates during upgrade. Verify both fresh installations and an installation with pre-change data. This plan does not change event schemas, SDK collection, per-account configuration, or the definition of active reading time.

## Progress


- [x] (2026-11-08) Milestone 1: Canonical queries and fresh session state exclude both diagnostics for every stored version. `scripts/session-attributes-acceptance.py` passed at 65536- and 2-row blocks (native session, attachment, acquisition and activity suites; no failures/pending). Direct native migration component passed 26 migrations/264 steps, assertions and zero-SQL repeat.
- [x] (2026-11-08) Milestone 2: Both native topologies upgrade retained page/vital sessions from engagement 1/bounce 0 to engagement 0/bounce 1 with unchanged 20-second duration. Packaged direct acceptance passed 18 cases; Apple Container acceptance passed 15 owned cases, the packaged full case and the packaged hyphenated-cluster case, including interrupted clear, explicit repair, repeated reconstruction, fresh installation and nonquorum-history refusal with the fence retained. Historical 25/257 and 25/254 prefixes remain byte/checksum-identical.
- [x] (2026-11-08) Milestone 3: Packaged authenticated HTTP checks report bounce 1/duration 20 for retained diagnostics and bounce 0/duration 30 after purchase, preserving event counts. Guides, OpenAPI, capability/terms and ADR-7/ADR-13 document classification, duration, the retained upgrade, supported quorum contract and recovery. Repository, documentation/profile and source-archive checks pass.

## Surprises & Discoveries

The exact Altinity candidate reads a quorum-written retention revision 0 instead of a later synchronized nonquorum revision 99 when `select_sequential_consistency=1`. An owned probe returned cutoff 99 with sequential reads disabled and cutoff 0 with them enabled, independently of result limits or insert quorum. The toolkit deliberately protects sequential read mode for native replicated statements; authored SQL cannot override it. The retained-upgrade fixture therefore uses the established supported writer contract (synchronous full quorum). The coordinator independently verifies the complete canonical population with sequential restriction disabled, so incompatible nonquorum history fails closed while fenced rather than silently completing a partial rebuild. No dependency upgrade or policy bypass is introduced.

The dependency replica fixture hardcodes Docker, so the required Apple Container policy needs a repository-owned bridge using the same qualified image and hostile profiles. FRIC-19 in `docs/friction-log/` records the detour. The bridge preserves Keeper, full UUID inventories, explicit coordinator sessions and refusal cases. Each owned replica has 4 GiB: the full native memory-limit fixture exceeded the initial 2 GiB VM during seed insertion, before reaching its intentionally constrained query. Query limits remain unchanged; no Colima runtime is used.


## Decision Log

Decision (2026-11-08): Preserve the toolkit's protected replicated read policy on separately journaled SQL. Use full-quorum retained fixtures representing the supported writer contract, and an independent complete-history read for final canonical agreement. Explicit complete-result/throwing-overflow settings prevent limiting command profiles from silently narrowing reconstruction or verification. History outside the supported acknowledgement contract must remain fenced if complete canonical agreement cannot be established.

Decision (2026-11-08): Use coordinator event callbacks for repeatable all-replica barriers before the separately journaled replay, and reuse the compiled SQL assertion for a fresh read-only check before migration completion and maintenance release. Synchronization uses the validated configured cluster; bounded local observations cover every expected UUID through the retained endpoint without following discovered hostnames.


Decision (2026-11-08): Exclude the exact names `client_error` and `web_vital` from engagement without testing schema version. Preserve minimum/maximum event timestamps. This implements the requested behavior for historical, versionless and future-version rows without changing accepted event contracts or duration semantics.

Decision (2026-11-08): Append migrations for both supported topologies and rebuild retained session state inside the migration maintenance window. Existing exact-ID aggregate states cannot subtract previously counted diagnostic IDs; changing only the insert view would leave history wrong. Do not finish maintenance between replacing the view and correcting retained state.

## Outcomes & Retrospective

Completed on 2026-11-08. Both exact diagnostic names are excluded for every stored version, while all observed timestamps continue contributing to duration. Migration 0026 replaces the view and reconstructs only retained sessions inside the existing persisted fence. Native and independent complete-history checks prevent partial reconstruction from being served; replicated sources retain the supported synchronous quorum contract and incompatible nonquorum history refuses completion.

Validation passed: 54 native attachment/session/acquisition/activity examples at normal and two-row blocks; four direct component cases over 26 migrations/264 steps; 18 packaged direct cases including authenticated public metrics; 15 owned Apple Container cases plus packaged full and hyphenated-cluster cases; 73/73 native query/metrics examples across the two full replicated runs; exact historical-prefix inspection; preserved-time embedding rebuilds; ten extracted source archives building both offline plans; `just check`; strict ADR, guide, terminology and friction profiles; the capability profile; and `git diff --check`. Source-archive/embedding evidence remains applicable after the final SQL and read-only query-rendering corrections: migration membership, build/embedding code and interfaces are unchanged, and the final packaged/native runs execute the accepted SQL. Private failed and passing evidence remains under `.dev/acceptance/`.

FRIC-19 in `docs/friction-log/` is resolved by the owned Apple Container migration fixture; no Docker/Colima backend is used by this gate. FRIC-20 is accepted with preservation of every historical log byte around generated additions. FRIC-21 is accepted: retain content-qualified embedding and use bounded SQL probes before expensive graph rebuilds. Durable classification, reconstruction and quorum-visibility context is recorded in ADR-7 and ADR-13. No live installation was migrated or deployed by this work.


## Context and Orientation


A session is the retained set of web events with the same account, source service and nonempty session ID. A bounce has exactly one distinct page-view event ID and no engagement event IDs. Duration is the maximum minus minimum event timestamp, including diagnostics, with millisecond precision. Zero-page sessions remain in the session denominator but are never bounces.

`kansoku-core/src/Kansoku/Metrics/Query/Session.hs` owns `engagementPredicate`, the canonical `sessionProjection`, and `materializedSessionProjection`. Canonical means reconstructing from retained event facts rather than reading derived aggregates. The first projection counts engagement directly; the second merges stored distinct-ID sets from `analytics.sessions`. `kansoku-core/src/Kansoku/Metrics/Query.hs` computes bounce rate from finalized page and engagement counts. Changing the Haskell predicate alone cannot fix the stored sets.

An insert-triggered materialized view, `analytics.mv_sessions`, builds aggregate state in `analytics.sessions`. Its pre-change definition is in `kansoku-server/migrations/clickhouse/steps/0022_applied_retention_policy/statement-19.sql`; migration 0026 replaces it with the corrected predicate. It includes the applied retention cutoff and all attribution fields. Earlier definitions in migration 0020 are historical evidence, not edit targets. The direct manifest is `kansoku-server/migrations/clickhouse/manifest.json`; the replicated manifest is `kansoku-server/migrations/clickhouse-replicated/manifest.json`. Both immutable converted prefixes end at 0025; their appended 0026 suffix has seven steps. A replicated installation keeps synchronized copies of data on multiple ClickHouse servers. Full INSERT quorum requires acknowledgement from every configured replica.

`kansoku-core/test/Kansoku/Metrics/SessionIntegrationSpec.hs` compares canonical and materialized results and tests replay and session measures. `scripts/session-attributes-acceptance.py` runs this family and adjacent populations on owned scratch databases with normal and two-row block sizes. `kansoku-server/test/ClickHouseMigrations.hs`, `kansoku-server/test/ClickHouseReplicatedMigrations.hs`, and `scripts/clickhouse_migrations_acceptance.py` exercise native migrations and the packaged coordinator. `scripts/check_clickhouse_conversion.py` currently assumes the entire manifest is the 25-migration converted baseline; it must distinguish that immutable prefix from new suffixes.

Relevant decisions consulted are [ADR-7](../adr/0007-versioned-event-schema-governance-and-publication.md), which declares these events and explicitly defers reclassification; [ADR-13](../adr/0013-whole-retained-replay-safe-web-sessions.md), which defines whole retained sessions and replay-safe state; [ADR-17](../adr/0017-fenced-resumable-administration-and-applied-retention.md), which requires maintenance exclusion and verified reconstruction; and [ADR-22](../adr/0022-explicit-clickhouse-migrations-and-persistent-administrative-sessions.md), which requires append-only native migration history and persistent recovery identities. A fence is persisted maintenance ownership that blocks application traffic until verification and explicit release; external SQL clients must also be stopped separately.

## Plan of Work


### Milestone 1: Correct classification and fresh state


Add both names to `engagementPredicate`. Append `0026_diagnostic_session_engagement` (or the next unused suffix if another migration lands first) to both manifests, with SQL files under their respective `steps/` directories. Preserve every historical name, step, byte and checksum. Use the current retention-aware view definition, replacing only its engagement predicate. Keep timestamp, bot, attribution and page-ID expressions unchanged.

The suffix must replace `analytics.mv_sessions` and reconstruct `analytics.sessions` from retained canonical events under the existing migration fence. Use explicit separately journaled steps: remove the old insert view, create the corrected view, clear old session state, insert rebuilt states, and assert agreement with canonical retained sessions. Reuse the repository's native assertion pattern (prepare a check target, INSERT-SELECT with a failing check, then cleanup), rather than assuming a standalone SELECT is checked by the migration runner. Build the replay SELECT from the corrected aggregation and canonical retained source, preserving the applied cutoff. Do not replay raw rows through unrelated views or change other derived populations.

First prove one page plus one web vital through this complete producer/consumer path on an owned direct database. Then expand `kansoku-core/test/Kansoku/Metrics/SessionIntegrationSpec.hs` to the acceptance matrix below. Preserve the existing canonical/materialized equality checks and replay checks. Milestone acceptance is passing session native tests on fresh migrations at both supported block sizes.

### Milestone 2: Upgrade and recovery


Extend `scripts/check_clickhouse_conversion.py` to verify the existing direct and replicated converted prefixes exactly as before, separately validating suffix membership and step files. Keep historical provenance and frozen baseline fixtures unchanged. Update tests that equate the current plan length with 25/257 or 25/254 so they still prove prefix identity as well as the new suffix. Ensure embedding and source archives include the new SQL files.

Extend the direct and replicated migration acceptance suites to initialize only the historical prefix, insert a retained page-plus-vital fixture, observe engagement=1 and bounce=0, and then run the appended migration through the real maintenance coordinator. After upgrade, require engagement=0, bounce=1, unchanged duration and canonical/materialized equality. Also insert new diagnostics after upgrade and repeat clean migration execution; results must remain stable and no already-applied SQL may be resubmitted.

Replicated execution must synchronize the cleared target before replay, submit replay once, and synchronize/check each expected replica before maintenance finishes. Explicitly test repeated replay after clearing with insert deduplication disabled for reconstruction, following the existing maintenance pattern. Exercise the candidate SQL against the qualified replicated fixture early; do not assume a successful direct migration proves replica barriers or statement support. If a barrier is required outside declarative SQL, integrate it into `kansoku-server/src/Kansoku/ClickHouseMigration/Coordinator.hs` using the existing topology and retained identity contract, and cover it with the same acceptance scenario.

Inject failure after clearing state and before successful reconstruction. Traffic must remain fenced. Use explicit receipt reconciliation/repair and fresh drain evidence to recover, then prove all session attributes match the canonical projection. Do not use a second data-maintenance job while a migration session owns the fence. Completion requires both topology suites to pass without skipped required cases.

### Milestone 3: Publish and prove the contract


Extend the packaged public workflow in `scripts/clickhouse_migrations_acceptance.py` with a session metric query for a retained diagnostic fixture after upgrade, or add an owned HTTP scenario to `scripts/session-attributes-acceptance.py` using existing fixture helpers. Assert the actual public bounce and average-duration response, not just internal SQL. Retain coverage of genuine application engagement and unaffected event counts.

Update `docs/guides/query-metrics.md`, `docs/guides/send-events.md`, and `docs/guides/clickhouse-migrations.md`. Explain that both names are non-engagement for every version but still extend observed duration. Document the tested maintenance begin/up/guarded verification/finish procedure, the required stopped external clients and drain evidence, and failure recovery. The new migration corrects all retained sessions; discarded raw history cannot be recovered. Unupgraded installations retain the old classification. Deploy the matching application binary and migration together during the maintenance window so canonical and materialized queries never intentionally serve different classifications.

Update ADR-7 and ADR-13 with the same contract and rebuild consequence; update their timestamps and bundle logs using the existing OKF convention. Inspect `docs/capabilities/web-sessions-acquisition.md`, `docs/terminology/web-session.md` and `docs/terminology/observed-session-duration.md` for contradictory wording and change it where necessary, keeping their metadata/logs valid. Record concrete acceptance evidence in this plan before completing its milestones.

## Concrete Steps


Run commands from the repository root. The default Nix shell supplies the qualified direct ClickHouse environment; replicated checks require the repository's owned Linux replica fixture and its existing prerequisites. A missing qualified environment is a reported validation blocker, not a passing skip.

```bash
nix develop --no-write-lock-file -c just build-with-tests
nix develop --no-write-lock-file -c just session-attributes-acceptance
nix develop --no-write-lock-file -c just ch-migrations-component
nix develop --no-write-lock-file -c just ch-migrations-acceptance
nix develop --no-write-lock-file -c just ch-migrations-replicated
nix develop --no-write-lock-file -c just ch-migrations-source
nix develop --no-write-lock-file -c just check
git diff --check
```

Expected results are zero exits, non-skipped session and migration cases, exact historical-prefix verification, passing source-archive/embedding checks, and valid documentation metadata. Add the public scenario to one of the named runners so these commands execute it. Preserve concise results and owned failure evidence rather than copying full logs into this plan.

Before using unfamiliar dependency APIs, locate sources through Mori:

```bash
mori registry search clickhouse-migrate
mori registry show shinzui/clickhouse-migrate --full
mori registry docs shinzui/clickhouse-migrate
```

No dependency upgrade is required. If implementation requires one, verify registry releases and upstream tags before choosing bounds or a workaround; local corpus versions are not release evidence.

## Validation and Acceptance


For each diagnostic name independently and for both together, insert one page at time 0 and diagnostics at 10 and 20 seconds. Require one session, one distinct page, zero engagement, bounce rate 1 and duration 20 seconds when the last event is at 20. Add `purchase` at 30 seconds and require bounce rate 0 and duration 30. Add a second distinct page and require bounce rate 0 without diagnostics becoming engagement. Diagnostic-only sessions have zero page views and are not bounces. A page-only session remains a bounce with duration zero.

Cover historical/versionless and explicit-version diagnostic rows. Future version independence is a stored-row classification test; do not relax ingest registry validation to accept an undeclared version. Replay identical IDs in separate batches and insert late diagnostics across midnight: distinct counts and bounce stay stable, while whole-session timestamps and the start bucket retain existing semantics. Check account/source isolation, existing bot behavior, attribution, and page entry/exit through canonical/materialized equality and the adjacent existing suites.

Retained-upgrade acceptance must first observe the old wrong bounce result under the old view, then the corrected result after the new suffix. Fresh-install-only tests cannot satisfy this criterion. Verify the retained cutoff excludes expired facts, the public HTTP query reports the same bounce/duration, and every replica agrees. Recovery acceptance must show the fence remains active after an interrupted reconstruction and releases only after repair and verification. Documentation must explicitly state duration behavior and the exact historical correction boundary.

## Idempotence and Recovery


Test fixtures own their databases and ports; preserve failed fixture evidence and never reset ambient data. A clean repeated migration run is a no-op. Replay of identical canonical IDs produces idempotent set/min/max state, but cannot remove previously stored engagement IDs: clearing/replacement is mandatory. A destructive clear is safe only inside the persisted fence with retained canonical data available for reconstruction.

On uncertain native execution, preserve the session, ledger identities and receipts. Follow the existing reconciliation and repair procedure in `docs/guides/clickhouse-migrations.md`, establishing new external drain evidence before each mutating entry. Re-observe whether clearing and insertion completed before authorizing a retry; never rerun a clear blindly after a completed insert. Keep the fence active until fresh canonical/materialized comparison and all-replica synchronization succeed. Rollback uses a separately reviewed consistent backup restore into a separate target, not modified historical checksums or deletion of the migration ledger.

## Interfaces and Dependencies


Keep `sessionProjection :: Text -> Bool -> Text` and `materializedSessionProjection :: Text` unchanged in `Kansoku.Metrics.Query.Session`. Public event schemas and session query response shapes remain unchanged. The classification is an exact event-name exclusion; unknown application events continue to count as engagement.

Use the existing native migration/embedding cohort, PostgreSQL maintenance coordinator and ClickHouse aggregate state types. Its canonical dependency identity is `mori://shinzui/clickhouse-migrate`; no new package or compatibility pin is selected by this plan. Preserve separate direct and replicated manifests and their immutable prefixes. This is a standalone plan with no parent MasterPlan dependency.

Revision note (2026-11-08): Preserve the native toolkit's protected quorum policy and add independent complete-history release verification, including a deliberate nonquorum-history refusal case. Use the repository-owned Apple Container fixture with 4 GiB per replica for the complete required native workload. Historical migration prefixes and the original acceptance obligations remain intact.
