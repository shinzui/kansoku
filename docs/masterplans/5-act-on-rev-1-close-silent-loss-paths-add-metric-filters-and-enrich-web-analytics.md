---
id: 5
slug: act-on-rev-1-close-silent-loss-paths-add-metric-filters-and-enrich-web-analytics
title: "Act on REV-1: close silent-loss paths, add metric filters, and enrich web analytics"
kind: master-plan
created_at: 2026-10-15T13:44:34Z
intention: "intention_01m4zwwdrjesytazp5tb39fe3n"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-15T13:44:34Z
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-15T14:24:22Z
      mode: "update"
      note: "Promote beacon route (EP-39), rejection quarantine (EP-29 M4, EP-37 M5) and person properties (EP-40) into scope after owner discussion."
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-15T15:43:15Z
      mode: "update"
      note: "Reconcile first-release APIs, domain semantics, dependencies and acceptance with the source-validated MP-5 review."
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-15T16:02:57Z
      mode: "update"
      note: "Select released Shibuya and PGMQ upgrades for fresh deployment without rollout coordination."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-15T16:12:47Z
      mode: "implement"
      note: "Begin EP-29 shared ingest normalization, outcomes and bounded quarantine."
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-15T15:43:15Z
      verdict: "changes-requested"
      note: "Original draft review found correctness gaps; findings corrected by the accompanying update, with native acceptance still required."
---

# Act on REV-1: close silent-loss paths, add metric filters, and enrich web analytics


## Vision & Scope


Prepare Kansoku for its first deployment with stable event, identity, query and administrative
contracts. There are no deployed consumers to migrate: make necessary API/domain corrections
before initial release, without temporary compatibility flags, staged rollouts or downstream
release coordination. Dependency upgrades target fresh installations; internal package bounds
must agree and server/SDK contracts must still pass conformance tests. The originating feature review is
`docs/reviews/2026-10-15-architecture-and-feature-set-against-comparable-products.md`.

The initiative covers timestamp normalization, rejection visibility/quarantine, durable event
idempotency, outage recovery and rate limits; metric filters and dual grouping; unambiguous
identity resolution; device/channel/country enrichment; session, rolling-user, retention, funnel
and experiment diagnostics; current user traits; beacon transport; administrative lifecycle and
SQL consumption guides. Activity excludes identity-only profile updates; revenue remains
a single-account-unit analytical sum, without FX/refund accounting. Newly discovered work necessary to fulfill those guarantees belongs to
these children, including transactional deduplication, replay-safe aggregates and erasure fences.

Excluded from the initial supported feature set: dashboard UI, significance/statistics engine,
container distribution, multi-tenancy, event-time trait snapshots, organization analytics and
custom metric definition APIs. Existing organizations/custom stubs are not supported capabilities.
Group events stamp organization context; alias binds an anonymous identifier to a user and does
not promise arbitrary transitive user merges. Public write-key data is analytics input, not an
authorization source. Country is optional; deployment capacity is finite and measured.

Browser work is coordinated with
`mori://shinzui/kansoku-ts/plans/8-serve-kansoku-masterplan-5-sentat-beacon-exit-flush-bot-flag-and-identifyonce`
and cross-origin identity with
`mori://shinzui/kansoku-ts/plans/7-cross-origin-identity-parent-domain-cookies-and-link-handoff`.
Server development may proceed independently of SDK implementation, but final release acceptance
requires both contracts and real browser/server conformance. Mori's registry does not yet resolve
these newly authored plan URIs; the registered project and files were verified directly.

## Decomposition Strategy


Keep twelve functional children, but correct their actual prerequisites rather than let a child
omit promised filters, bot handling or erasure because a "soft" dependency is absent. EP-29
owns shared normalization/validation; EP-30 first upgrades the released queue-processing stack,
then establishes durable acceptance and logical uniqueness;
EP-32 defines identity and the internal rich resolved source; EP-31 defines metric grammar and
result grouping. Later analytic features consume those foundations. EP-37 finalizes operational
lifecycle after the stores exist, and EP-38 finalizes documentation and release proof last.

The first design had no owner for durable event identity, treated shared types as optional,
and gave two children incompatible session semantics. Those are coordination defects, not reasons
to create more plans. Existing children now own the required behavior explicitly.

Relevant accepted decisions were read: ADRs [1](../adr/0001-sdk-grade-ingest-contract-boundaries.md),
[2](../adr/0002-pipeline-observability-readiness-and-writer-recovery.md),
[3](../adr/0003-api-key-authentication-and-account-scoped-analytics.md),
[4](../adr/0004-queryable-event-properties-and-identity-resolved-projection.md),
[5](../adr/0005-evidence-based-multi-signal-identity-resolution.md),
[6](../adr/0006-exposure-based-experiment-analytics.md),
[7](../adr/0007-versioned-event-schema-governance-and-publication.md),
[8](../adr/0008-rfc9457-problem-details-and-generated-client-media.md),
[9](../adr/0009-bounded-complete-aggregate-responses.md) and
[10](../adr/0010-owned-executable-acceptance-environments.md).
[ADR-11](../adr/0011-initial-release-analytics-contracts.md) records the proposed first-release
changes without claiming the current runtime already implements them. Child implementations
update affected accepted ADRs and promote the proposal only with evidence. SDK transport context
is `mori://shinzui/kansoku-ts/okf/adrs/concepts/ADR-2`.

## Exec-Plan Registry


| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 29 | Correct client timestamp skew and count ingest rejections | docs/plans/29-correct-client-timestamp-skew-and-count-ingest-rejections.md | None | None | Complete |
| 30 | Pipeline backpressure and storage-outage resilience | docs/plans/30-pipeline-backpressure-and-storage-outage-resilience.md | EP-29 | None | Complete |
| 31 | Metric property filters and dual grouping | docs/plans/31-metric-property-filters-and-dual-grouping.md | EP-26; EP-30; EP-32 | None | Complete |
| 32 | Time-aware identity bindings and bounded resolution cost | docs/plans/32-time-aware-identity-bindings-and-bounded-resolution-cost.md | EP-29; EP-30 | None | Complete |
| 33 | Acquisition and device enrichment with bot flagging | docs/plans/33-acquisition-and-device-enrichment-with-bot-flagging.md | EP-26; EP-31 | None | Complete |
| 34 | Session analytics: duration, bounce, entry and exit pages | docs/plans/34-session-analytics-duration-bounce-entry-and-exit-pages.md | EP-26; EP-30; EP-33 | None | Complete |
| 35 | Rolling active users, retention modes, and lifetime cohorts | docs/plans/35-rolling-active-users-retention-modes-and-lifetime-cohorts.md | EP-26; EP-31; EP-32 | None | Complete |
| 36 | Funnel modes and experiment exposure diagnostics | docs/plans/36-funnel-modes-and-experiment-exposure-diagnostics.md | EP-26; EP-31; EP-32 | None | Complete |
| 37 | Administrative executable for keys, erasure, retention, and replay | docs/plans/37-administrative-executable-for-keys-erasure-retention-and-replay.md | EP-29; EP-30; EP-32; EP-34; EP-40 | None | Not Started |
| 38 | Single-tenant consumption guide for dashboards and experiments | docs/plans/38-single-tenant-consumption-guide-for-dashboards-and-experiments.md | EP-31; EP-33; EP-34; EP-35; EP-36; EP-37; EP-39; EP-40 | None | Not Started |
| 39 | Beacon ingest route for page-exit delivery | docs/plans/39-beacon-ingest-route-for-page-exit-delivery.md | EP-29; EP-30; EP-33 | None | Not Started |
| 40 | Person properties: set and set-once user traits | docs/plans/40-person-properties-set-and-set-once-user-traits.md | EP-29; EP-31; EP-32; EP-34 | None | Not Started |

EP-26 is `docs/plans/26-bound-analytics-query-inputs-and-result-cardinality.md`, Complete in
`docs/masterplans/4-align-kansoku-with-relevant-haskell-jitsurei-practices.md` on review day.
EP-29 is Complete with owned native/HTTP acceptance; the other children retain their reviewed prerequisites.

## Dependency Graph


The default sequence is EP-29 → EP-30 → EP-32 → EP-31 → EP-33 → EP-34 → EP-35 → EP-36 →
EP-40 → EP-37 → EP-39 → EP-38. This is a valid topological order; registry hard dependencies
are authoritative. EP-35 and EP-36 can begin once EP-31 completes; EP-39 can begin after EP-33;
EP-40 waits for EP-34 to support the promised session trait filters. These are opportunities
for future scheduling, not instructions to delegate this review.

No implementation cycle exists between traits and administration: EP-40 supplies trait erasure
primitives and tests; EP-37 later integrates them into the executable. No SDK cycle exists:
server children use contract fixtures, SDK plans consume the implemented server, and EP-38
performs joint release acceptance. Documentation can be drafted early but cannot be accepted
against obsolete metric semantics. Whole-child hard dependencies cannot be weakened silently.

## Integration Points


**PostgreSQL diagnostic lifetime — EP-29 owner.** A locked quarantine write exposed
unbounded Hasql/libpq result handling. EP-29 owns a small dedicated nonblocking libpq adapter
for diagnostics, with lock/cancellation/handshake proofs. It does not change the credential or
queue pool's dependency source. Later children consume this quarantine boundary without
borrowing diagnostic connections from the ingest pool.

**Queue-processing dependencies — EP-30 M0 owner.** Adopt shibuya-core 0.10.0.1,
shibuya-pgmq-adapter 0.16.1.0 and pgmq-core/hasql/effectful/migration 0.6.1.1 together in
`cabal.project` and `flake.module.nix`. EP-30 owns source adaptations, fresh native schema
installation and acknowledgement/lifecycle acceptance. Later children use this baseline.
This is local dependency consistency, with no upstream release work, SDK release sequencing,
old-version support or deployed-data migration required. The selected releases do not expose
the pause/resume API seen in unreleased Shibuya source; EP-30 M2 still owns source-level outage
control and verifies it against the selected released adapter.

**Shared ingest service — EP-29 owner, EP-30/33/39 extensions.** Wire AnalyticsEvent and catalog
live in kansoku-api; core owns request context and the private queued envelope. EP-29 defines
future-only normalization, original rejection capture and transport-labelled outcomes. EP-30
adds transactionally unique account/event acceptance and per-credential admission. EP-33 adds
server enrichment and versioned queue encoding. EP-39 adapts beacon body authentication into
that exact path. All three routes have the same limits, counters and replay semantics.

**Event uniqueness — EP-30 owner.** PostgreSQL accepted_events and atomic PGMQ send establish
immutable event IDs. Canonical ClickHouse rows collapse queue redelivery before aggregation;
count rollups use distinct IDs. EP-32 identity, EP-34 sessions and EP-40 traits consume this
source. EP-37 replay/retention/deletion respects tombstones and source envelopes. Finite block
hash windows are never a substitute for this contract.

**Identity projection — EP-32 owner.** Preserve the seven public view columns while providing
a richer private source for query compilation. Canonical subject kind distinguishes users and
anonymous IDs. Conflicted evidence stays ambiguous; query-time resolution may use evidence
outside the selected event window. EP-31 and all analytic children consume this one resolver through its query-connection
lifetime. EP-32 supplies exact evidence/context indexes and connection-local snapshots with
part/UUID invalidation and fingerprint-expiry deadlines, not a timed stale refresh.
Context expansion is scoped to the requested account/date window; evidence may span history. EP-31 applies work budgets to preparation
and final SELECT; EP-37 erases/rebuilds every derived identity index as well as raw/evidence.
The public SQL projection uses its direct policy-equivalent relation. EP-37 also treats the
materialized, lossless raw identity_context_key as identity data during erasure/scrubbing.

**Metrics grammar and result shape — EP-31 owner.** Repeated JSON filter objects, native value
parameters, one/two dimensions, full namespaced group keys and nullable group text form the
initial API. Encode native group transport structurally. EP-33 adds enrichment, EP-34 session
attributes, EP-35 cohort modes, EP-36 funnel measures and EP-40 user traits. Every extension
keeps account predicates, typed ordering and complete-or-error output. EP-31 owns database
work budgets consumed by EP-35/36; result cardinality alone is not an execution budget. OpenAPI/Haskell consumers
move with each wire change; the final SDK contract pin is EP-38's release gate.

**Session population — EP-34 owner; attribution — EP-33 owner.** Logical key is account,
source_service,session_id; session start controls bucket assignment. Merge all retained session
state before date filtering. First-touch attribution is deterministic; lifecycle/identity events
are not engagement. Duration is observed elapsed time; page_leave is optional. Acquisition and
sessions share the same projection, bot policy and first-resolved-user trait attribution.

**Catalog — EP-29/40 ownership split.** EP-29 declares alias/group/page_leave v1 and validates
top-level identity fields. EP-40 declares identify v2/identify_once v1 and compatible scalar
traits; helper versions are explicit. EP-32 adds email_hmac and identify_once binding semantics.
The SDK consumes the generated catalog, not hand-copied assumptions.

**Administrative lifecycle — EP-37 owner.** Retention and erasure cover raw facts, derived states,
quarantine and replayable inputs. Maintenance jobs are fenced, resumable and explicit. EP-29
owns automatic quarantine expiry; admin purge is supplemental. EP-38 freezes only intentional
SQL projections after these policies are implemented.

**Migrations and acceptance.** Each child takes the next unclaimed migration number. All tests
that mutate stores use ADR-10's owned environments. EP-30's failure/rebatching test and EP-32's
resolution benchmark precede dependent metric expansion; EP-33's optional native geo reader
has a build/lookup proof before adoption. Never use successful compilation or skipped native
cases as acceptance. All schema changes must work on a fresh database and repeat safely under
the migration ledger; unsafe append-backfills are replaced with verified rebuilds.

## Progress


EP-29, EP-30, EP-32, EP-31, EP-33, EP-34, EP-35 and EP-36 are Complete; four children remain Not Started. Accepted foundations now include bounded timestamp/rejection
handling, immutable acceptance and canonical replay-safe facts, outage recovery/admission,
conservative exact identity resolution, typed filters, nullable dual grouping and immutable device/channel/bot/trusted-country enrichment. Child plans
hold the native, packaged and consumer evidence. The tested ten-minute outage/restart and
finite capacity budget remain workload-specific; see `docs/guides/capacity.md`.

Final integration gate (owned by EP-38): a practical ordinary first-use/adoption/reuse/recovery
workflow from a fresh clone and the previously supported consumer, plus packaged server acceptance, generated API/catalog,
SDK contracts and required live/browser cases all agree with zero feature skips. Performance,
geo dependency compatibility and external GrowthBook consumer acceptance remain implementation
proofs, not results established by this document review. Source builds, published artifacts and
the installed executable must be identified separately; test-only fixture preparation cannot
substitute for steps the shipped workflow leaves to developers.

EP-31's final packaged gate passes 225 core examples, 18 live-client examples, 51 Hurl
requests and native recovery/limits/replay/identity proofs. Its ten-million-event identity
regression remains below 2× for all twelve cases (1.24–1.58×), and the pinned SDK contract
refresh passes 60 unit and two SSR examples plus package checks. EP-33 adds 384 native core examples, public enrichment acceptance in all three telemetry modes,
optional-geography privacy/startup checks and pinned SDK consumer `e199567` with 61 unit/two
SSR examples. EP-34 adds replay-idempotent whole-session state and count/bounce/duration measures, with
388 native core examples, packaged public workflows in all three telemetry modes and pinned
SDK consumer `bfe281c`. EP-35 adds exact closed-day rolling/stickiness, mature retained-history retention and lifecycle,
with 394 native core examples, packaged public workflows, pinned SDK consumer `3501e45` and
28 ten-million-event performance cases below 2× (1.09–1.54×). EP-36 adds deterministic selected-chain modes, exclusions, exact timing, first-touch breakdown,
ordered signup conversion and exact exclusive exposure diagnostics. Its 2000 seeded native
chain comparisons, 412-example packaged core gate, three-mode public workflows and pinned
SDK consumer `5db6d5c` pass. The repeated 28-case ten-million-event cost gate is below 2×
(1.02–1.54×), with peak native memory below 452 MB against the unchanged 512 MiB budget.
[ADR-15](../adr/0015-deterministic-selected-funnel-chains-and-exclusive-exposure-diagnostics.md)
is Accepted. EP-40 follows; the final joint SDK/browser, performance and outage gates remain
EP-38 obligations.

## Surprises & Discoveries

EP-29 implementation on 2026-10-15 established the supported UTC range
`[1970-01-01, 2100-01-01)` and catalog v2 constraint fields (`minimum`, `minLength`). Later
children consume these contracts. Beacon-specific executions of shared ingest/quarantine and credential-rate admission
acceptance belong to EP-39, when its route exists; this resolves the impossible requirement
to test that route before its hard prerequisite EP-29 completes.


Review on 2026-10-15 found the following material defects, ordered by impact. Each is corrected
in the revised child; the proof obligations remain open until implementation.

| Severity | Location in original plans | Finding and correction |
|---|---|---|
| High | EP-30 M1; EP-37 M4 | ReplacingMergeTree is not keyed solely by event ID, finite block dedup does not survive rebatching/archive age, and count-state views inflate. Added durable acceptance identity plus replay-safe canonical aggregation. |
| High | EP-37 M2/M3; EP-34 M1 | Erasure/TTL leaves queue/archive/derived data able to restore deleted facts; backfill count states are not idempotent. Added fenced lifecycle jobs and consistent retained populations. |
| High | EP-32 M3 | Nearest-future cookie binding reassigns ambiguous shared-device activity; evidence uses receive time. Added session-aware unambiguous evidence and subject namespaces. |
| High | EP-31 M1/M2; MP Integration Points | Filters require columns absent from the frozen view; delimiter grouping collides; user counts change identity policy on fast-path bypass. Added rich private source, typed JSON grammar and exact user semantics. |
| High | EP-34 M1/M2; SDK EP-8 M2 | Page-leave turns every visit into a nonbounce, any(channel) is nondeterministic, date filtering truncates sessions. Unified session identity, lifecycle classification and first-touch attribution. |
| High | EP-36 M1/M4 and current conversion route | Step-only filtering defeats strict funnels; variant shares with overlapping denominators cannot sum to one. Added full timelines, ordered signup conversion and exclusive first-assignment shares. |
| High | EP-40 M1/M3; SDK EP-8 M4 | identify defaults to schema v1; undeclared traits bypass governance; tie-break and string decoding are missing. Explicit helper versions, declared storage and deterministic typed values now required. |
| Medium | EP-29 M1/M4 | Timestamp example has inverted arithmetic; zero config conflicts with positive parsing; manual purge does not bound quarantine. Corrected policy/tests and added automatic caps/expiry. |
| Medium | EP-30 M1/M3 | Handler breaker still consumes adapter deliveries; WAI does not automatically have a Servant principal. Move pause before reads and rate admission into authenticated shared service. |
| Medium | EP-33 M1/M4 | Handler has no WAI request, no queue carrier for enrichment, proxy header is spoofable, channel precedence is wrong. Define context bridge, private envelope, trust boundary and rules. |
| Medium | EP-35 M1/M2 | Rolling fixture wrong; lifetime claim conflicts with retained history; immature retention was treated as zero. Specify UTC windows, history scope and observation horizons. |
| Medium | EP-39 M2; SDK EP-8 M2/M5 | Beacon true is not delivered, quota is shared, missing features could pass by skipping. Preserve acknowledgement distinction and require final conformance. |
| Medium | MP graph; EP-38 | Real dependencies called soft; stale EP-26 status; guide freezes changing internals. Correct graph and finalize documentation/SQL contracts last. |

Evidence inspected: current ingest/auth/writer/event-row/query/property sources, migrations
0004/0006/0012/0014, SDK transport/identity/session code, both SDK plans and the relevant ADRs.
All original plans (MP-5, server EP-29–40, SDK EP-7/8) record claude-fable-5-1 authorship and had
no review entries before this pass. Current reviewer identity is resolved from runtime session
metadata as gpt-6-astra. Review provenance records the original changes-requested verdict;
revision provenance records this corrective update. This is not runtime deployment approval.

Dependency validation: Mori located the adapter and PGMQ sources; inspected adapter tag
v0.12.0.0 matching cabal.project, not just current checkout. The follow-up on 2026-10-15 verified
Hackage releases and upstream tags for shibuya-core 0.10.0.1, shibuya-pgmq-adapter 0.16.1.0
and the PGMQ family 0.6.1.1, now selected by EP-30 M0. They fix acknowledgement failure
propagation, ambiguous-commit dead-letter duplication and processor lifecycle failures;
they do not implement Kansoku's event idempotency or a complete storage-outage policy.
Canonical dependency references and source/API adaptations are recorded in EP-30.
Vendored ClickHaskell
exposes passSettings/addSetting for insert tokens and dependent-view dedup settings. These
APIs do not remove finite-window limitations documented by
[ClickHouse](https://clickhouse.com/docs/guides/developer/deduplicating-inserts-on-retries).
[Beacon's processing model](https://www.w3.org/TR/beacon/) and
[GrowthBook's datasource contract](https://docs.growthbook.io/app/datasources) were checked.
Geo/user-agent dependency selection still needs the explicit build spike; no custom MMDB parser
or guessed package API is approved here.

EP-34 adds replay-idempotent `analytics.sessions` and scopes entry/exit dimensions to whole
sessions. Ordinary acquisition counts reuse that state; primary-user/finite-property queries
retain the equivalent canonical projection. EP-37 must rebuild the current complete derived
schema under its fence, including session state and materialized enrichment/context columns;
reapplying an earlier migration alone can replace richer views with obsolete projections.
Current exact identity/trait changes cannot be treated as immutable session-state attributes.

EP-35 applies a request-start closed-UTC-day cutoff across users, stickiness, retention and
lifecycle. Shared filters/groups define identical lookback populations; lifetime means retained
history. Its expanded `scripts/identity-bench.py --activity` gate checks seven compiler query
families with the actual extended/history evidence scopes and must be reused by EP-38.

## Decision Log


On 2026-10-15 preserve the twelve-child scope, including the previously promoted beacon,
quarantine and current-value traits. Container distribution and event-time traits remain excluded.
The earlier scope decisions are retained in git history and the original provenance entries.

On 2026-10-15 revise contracts before first deployment: immutable account/event identity;
conservative evidence resolution; exact HTTP users; typed filter/group transport; session-start
and lifecycle semantics; retained-history cohorts; deterministic funnel chains and assignment
shares; governed traits with explicit SDK versions. Rationale: the original algorithms and
acceptance examples contradicted these user-visible guarantees.

On 2026-10-15 make source/grammar/storage prerequisites hard, move administrative integration
after trait/session stores, and finalize the guide last. Rationale: features cannot be declared
complete by omitting their promised dependencies. Keep performance/native integration proofs
inside the owning child, with failure treated as an implementation blocker.

Revision note (2026-10-15): all twelve children and the matching SDK plans were reconciled
against current sources. Corrected graph/status, stable initial contracts, first-release
exclusions, lifecycle guarantees and acceptance ownership; no production code changed.

Revision note (2026-10-15, dependency follow-up): select the released Shibuya core/adapter and
required PGMQ upgrades as EP-30 M0. Kansoku is unused, so implement directly against the new
baseline and validate fresh installation without rollout coordination or legacy compatibility
work. Keep the existing child graph and final contract tests; dependency pins change during
implementation, not this planning update.

## Outcomes & Retrospective


The original plan set was not ready to implement unchanged. This update records and corrects
the material findings and creates a coherent implementation sequence. Implementation must still
prove writer source pausing, event idempotency under failures, identity performance, native geo
compatibility and external consumer behavior. EP-29 and EP-30 are Complete; the remaining acceptance obligations stay open. No deployment is performed.
