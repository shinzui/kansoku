---
id: 2
slug: kansoku-production-hardening-review-fixes-and-portfolio-service-readiness
title: "Kansoku production hardening: review fixes and portfolio-service readiness"
kind: master-plan
created_at: 2026-07-15T21:30:13Z
intention: intention_01kxr5jt2heyvt0n768ym9dwqd
---

# Kansoku production hardening: review fixes and portfolio-service readiness

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

Kansoku (repository root: this repo, four cabal packages `kansoku-api`, `kansoku-core`,
`kansoku-server`, `kansoku-client`) is the first-party analytics service for the kikan
portfolio: browsers, product frontends, and every backend microservice in the stack send it
canonical analytics events, and dashboards, reports, and agents query it for metrics. The MVP
(MasterPlan 1, `docs/masterplans/1-kansoku-analytics-service-mvp.md`) delivered the right
macro-architecture — HTTP ingest decoupled from ClickHouse by a durable pgmq queue, one
batched `INSERT` per flush via a shibuya consumer, ClickHouse `ReplacingMergeTree` idempotency
over an at-least-once queue boundary, and a servant-only `kansoku-api` package shared by
server, Haskell SDK, and OpenAPI generation.

A full architecture and performance review (2026-07-15, recorded in this plan's Decision Log
and expanded in each child plan) found that the foundation is sound but not yet safe to build
the portfolio on. After this initiative is complete, the following are true and demonstrable:

The service cannot silently lose its pipeline: if the batch writer dies the process exits (and
the supervisor restarts it), and a readiness endpoint reports writer liveness and queue depth.
The repository compiles again (it currently does not, because shibuya renamed the
handler-facing message type). Dashboard queries and writer inserts no longer serialize on a
single MVar-guarded ClickHouse TCP connection. The ClickHouse schema matches the query
patterns: the raw-events sort key serves time-and-event-name range scans (with account
scoping), identity resolution no longer forces `FINAL` merges at read time, the DAU/WAU
materialized views no longer perform an insert-time join that grows with total identities, and
rollup tables are actually smaller than the raw data. Metric SQL is built from validated or
parameterized inputs instead of hand-escaped string interpolation, funnels are computed
in one ordered pass with `windowFunnel`, and query result decoding fails loudly instead of
producing plausible zeros. The served HTTP API and the published OpenAPI document are the same
servant type (plan 9). The ingest contract is SDK-grade: batches are accepted partially with
per-event rejections, browsers can ingest cross-origin, and payload limits are enforced.
Callers authenticate — write keys for frontends, service tokens for microservices, read
access for metrics — and metric queries are account-scoped. The pipeline is observable:
queue depth, batch flush latency, and insert failures are exported telemetry, not log lines.

Explicitly excluded: the JS/React browser SDKs (`kansoku-js`, `kansoku-react`) and the
dashboard UI remain a separate frontend initiative; this plan only guarantees the server is
ready for them. Kafka ingestion stays deferred (the shibuya adapter boundary already
accommodates it). The four HTTP-501 metric stubs (acquisition, feature-adoption,
organizations, custom) stay stubbed; new metric families are out of scope.


## Decomposition Strategy

The initiative decomposes along the failure modes the review found, not along packages or
files, so each child plan removes one class of risk and is verifiable on its own. Reliability
defects (silent writer death, broken build) come first because nothing else can be validated
on a repo that does not compile and a pipeline that can die unnoticed. Resource architecture
(connection sharing) is separated from storage architecture (schema v2) because they fail
independently and are testable independently: one shows up under concurrent load, the other in
query plans and storage size. Query-layer safety (SQL construction, funnel semantics, honest
decoding) is kept apart from the schema migration it runs on, so the schema can land while the
data is small even if the query rewrite takes longer. The already-authored plan 9
(NamedRoutes/vertical slices/MultiVerb) is adopted unchanged as the contract-unification work
stream; the ingest-contract and auth plans build on its restructured routing rather than
touching the hand-rolled WAI router twice. Auth and tenancy land last because they change
wire contracts that plans 9 and 14 stabilize first.

Alternatives considered: folding the connection split (EP-11) into the supervision plan
(EP-10) was rejected because EP-10 must stay small — it unblocks every other plan and should
land in one sitting. Folding typed row decoding into the query-safety plan (EP-13) instead of
the connection plan (EP-11) was considered; decoding lives in EP-11 because it is a property
of the ClickHouse client layer (`select` shape), while EP-13 owns what SQL is generated, and
the two can then proceed with only a soft ordering. A single "make ClickHouse fast" mega-plan
was rejected as unverifiable in one step and too large for one session. Eight plans exceed
the two-to-seven guideline, so they are grouped into four phases that act as implementation
waves.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|----|-------|------|-----------|-----------|--------|
| 21 | Migrate Kansoku to the coherent pg-migrate PGMQ and Shibuya cohort | docs/plans/21-migrate-kansoku-to-the-coherent-pg-migrate-pgmq-and-shibuya-cohort.md | None | None | In Progress |
| 10 | Restore the build and supervise the writer | docs/plans/10-restore-the-build-and-supervise-the-writer.md | EP-21 | None | Not Started |
| 11 | Split ClickHouse connections and adopt typed row decoding | docs/plans/11-split-clickhouse-connections-and-adopt-typed-row-decoding.md | EP-10 | None | Not Started |
| 12 | ClickHouse schema v2: sort key, FINAL-free resolution, join-free rollups | docs/plans/12-clickhouse-schema-v2-sort-key-final-free-resolution-join-free-rollups.md | EP-10 | None | Not Started |
| 9 | Convert kansoku to NamedRoutes, vertical slices, and MultiVerb | docs/plans/9-convert-kansoku-to-namedroutes-vertical-slices-and-multiverb.md | EP-10 | None | Not Started |
| 13 | Safe and correct metric SQL: validated inputs, ordered funnels, honest failures | docs/plans/13-safe-and-correct-metric-sql-validated-inputs-ordered-funnels-honest-failures.md | EP-12 | EP-11, EP-9 | Not Started |
| 14 | SDK-grade ingest contract: partial batch acceptance, CORS, and payload limits | docs/plans/14-sdk-grade-ingest-contract-partial-batch-acceptance-cors-and-payload-limits.md | EP-9 | None | Not Started |
| 16 | Pipeline observability: queue depth, writer lag, and exported telemetry | docs/plans/16-pipeline-observability-queue-depth-writer-lag-and-exported-telemetry.md | EP-10 | EP-11 | Not Started |
| 15 | API keys, service auth, and account-scoped queries | docs/plans/15-api-keys-service-auth-and-account-scoped-queries.md | EP-9 | EP-12, EP-13, EP-14 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-10).

Phases (implementation waves):

- Phase 1 — Migrate and stabilize (sequential): EP-21, then EP-10.
- Phase 2 — Resource and storage architecture (parallelizable after EP-10): EP-11, EP-12, EP-9.
- Phase 3 — Query and contract quality (parallelizable once their deps land): EP-13, EP-14, EP-16.
- Phase 4 — Portfolio readiness: EP-15.


## Dependency Graph

EP-21 blocks EP-10. The repository currently fails to compile for two independent reasons:
`Kansoku/Writer/Batch.hs` still pattern-matches Shibuya's removed handler-facing `Ingested`
type, and `Kansoku/Ingest/Queue.hs` still calls `Pgmq.Migration.migrate`, removed when PGMQ
adopted pg-migrate. Cabal also resolves workstation-local current checkouts while the active
Nix build pins an older PGMQ/Shibuya cohort. EP-21 owns that coherent migration: it makes both
build paths portable and version-aligned, adapts the runtime APIs, adds the PGMQ-only
pg-migrate plan and administrative executable, and proves first/second application on an
ephemeral PostgreSQL database.

EP-10 then blocks every remaining plan because it owns the production stabilization built on
that migrated baseline: writer/server lifetime linking, graceful shutdown, readiness, error
hygiene, and ClickHouse configuration. This is why EP-11, EP-12, and EP-9 still hard-depend on
EP-10 rather than directly on EP-21. Plans that touch Shibuya or PGMQ must use the cohort EP-21
records rather than reintroducing older APIs or implicit startup migrations.

EP-11, EP-12, and EP-9 are mutually independent and can proceed in parallel in any order:
EP-11 changes how connections are owned (`kansoku-server/app/Main.hs`, `Kansoku/ClickHouse.hs`
and the decode path), EP-12 changes what lives in ClickHouse (`db/clickhouse/migrations/`),
and EP-9 changes how routes are declared and served (`kansoku-api` route types,
`Kansoku/Server.hs`). Their file overlap is small and documented under Integration Points.

EP-13 hard-depends on EP-12 because its SQL builders target the v2 schema (a FINAL-free
`events_resolved`, new rollup state types); writing them against the v1 schema would mean
migrating the same SQL twice. It soft-depends on EP-11 (it emits SQL through the typed select
path EP-11 introduces; until then the tab-delimited path still works) and on EP-9 (its
handlers are cleaner to wire into the vertical-slice layout, but the old handler module works).

EP-14 hard-depends on EP-9 because it changes the ingest wire contract (`BatchAck` becomes a
partial-acceptance response) and adds CORS/limits at the routing layer; doing that against the
hand-rolled WAI router and again after the NamedRoutes conversion would be double work.

EP-16 hard-depends only on EP-10 (it extends the readiness endpoint EP-10 introduces and
observes the supervised writer) and soft-depends on EP-11 (its query-side gauges are cleaner
against the pooled connection layer). It can run in parallel with everything in Phase 3.

EP-15 lands last: it hard-depends on EP-9 (auth is declared in the servant API types and
enforced per route family; the NamedRoutes record is where that declaration lives) and
soft-depends on EP-12 (account-scoped queries only pay off once the sort key leads with
`account_id` intentionally), EP-13 (the account predicate is added to the rewritten query
builders), and EP-14 (write keys and service tokens attach to the finalized ingest contract).


## Integration Points

`Kansoku.Query` (kansoku-core/src/Kansoku/Query.hs) — touched by EP-11, EP-13, EP-15. EP-11
defines the typed row-decoding shape (replacing the `concat(..., '\t', ...)`/`splitOn` wire
hack and the `AggLine` type); EP-13 rewrites the SQL builders on top of that shape; EP-15 adds
an account predicate to `QueryRequest` and threads it through every builder. Later plans must
not reintroduce string-splitting decode paths.

`analytics.events_raw` schema and sort key — defined by EP-12 (in a versioned migration under
`db/clickhouse/migrations/`), consumed by EP-13 (every SQL builder) and EP-15 (account
scoping). EP-12 must keep `account_id` as the leading sort-key column *because* EP-15 makes
per-account filtering mandatory on the query API; the review's observation that the current
key is unused becomes false once EP-15 lands. `event_id` stays last in the key because it is
the ReplacingMergeTree dedup identity. Any plan changing the key must update both the
migration and `createEventsRawTable` ownership decision recorded in EP-12.

ClickHouse connection ownership — defined by EP-11 (a dedicated writer `Connection` plus a
query-side pool, replacing the single shared handle created in `kansoku-server/app/Main.hs`).
EP-13's query runner, EP-9's restructured handlers, and EP-16's gauges all consume the pool
type EP-11 introduces. Plan 9's milestone that wires handlers must accept whatever handle
type exists at implementation time and note it in its own Decision Log.

Ingest and metrics wire types (`kansoku-api/src/Kansoku/Api/*.hs`) — EP-9 restructures the
route declarations into NamedRoutes records (same DTOs); EP-14 changes `BatchAck` into a
partial-acceptance response and adds limit-related errors; EP-15 adds authentication to the
route types. Order is EP-9 then EP-14 then EP-15; each updates `kansoku-client` and the
generated OpenAPI document in the same change.

`Kansoku.Config` (kansoku-core/src/Kansoku/Config.hs) — EP-10 adds ClickHouse
host/user/password environment variables (currently hardcoded to `127.0.0.1` and user
`default`); EP-15 adds key-storage settings; EP-16 adds telemetry exporter settings. Additive
record fields only; every plan keeps `loadConfig` total with defaults suitable for `nix
develop` + `process-compose`.

PostgreSQL migration ownership — EP-21 defines `Kansoku.Migrations` and the
`kansoku-migrate` administrative executable. Its application plan contains only the PGMQ
component because Kansoku has no Kiroku, Keiro, Kioku, or application-owned PostgreSQL SQL.
Normal server startup may idempotently provision the configured queue after migration but
must never apply schema migrations or create/repair a pg-migrate ledger. EP-15 must extend
this checked-in application plan when it introduces authentication tables; it must not add a
second migration framework or restore startup migration side effects.

Readiness endpoint — EP-10 defines `/ready` (writer liveness, pgmq reachability); EP-16
extends it with queue depth and lag thresholds. EP-16 must extend, not replace, EP-10's
handler.

ClickHouse migration mechanism — EP-12 introduces versioned, recorded migrations (replacing
"apply every file in filename order" in the justfile `ch-migrate` recipe and deleting the
duplicated DDL in `Kansoku/ClickHouse.hs` `createEventsRawTable`). EP-13, EP-15, and EP-16
add any new ClickHouse objects through that mechanism only.

`Kansoku/Server.hs` WAI assembly — touched by EP-10 (`/ready` route in the hand-rolled
router), EP-9 (replaces the hand-rolled router with a served NamedRoutes record), EP-14
(CORS and size-limit middleware around the ingest subtree), and EP-16 (`GET
/internal/metrics` scrape endpoint and the `/ready` threshold extension). EP-9 and EP-16 are
both Phase 3-adjacent and parallelizable, so ordering is not guaranteed: EP-16 must add its
scrape endpoint as WAI middleware wrapped around whatever application exists (keeping it out
of the servant types and therefore out of the OpenAPI document), and EP-14 attaches its
middleware to the assembly EP-9 produces. The conventional Prometheus path `/metrics` is
unavailable — it is the analytics query API — hence `/internal/metrics`.

Shared MultiVerb error tail (plan 9) — plan 9 pins every operation's error alternatives
(400/404/503) and its conformance test asserts that literal. EP-14's batch-length cap adds a
413 alternative to the shared tail, so plan 9's implementer must not treat that test literal
as frozen; EP-14 edits the expectation when it widens the tail.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [ ] EP-21: Cabal and Nix resolve one portable pg-migrate/PGMQ/Shibuya cohort
- [ ] EP-21: writer runtime migrated to current Shibuya and adapter APIs
- [ ] EP-21: explicit PGMQ-only migration plan and `kansoku-migrate` executable; server startup does not migrate
- [ ] EP-21: ephemeral PostgreSQL first apply, strict verification, zero-work second apply, and queue provisioning proven
- [ ] EP-10: migrated baseline verified; `cabal build all` and `cabal test` green
- [ ] EP-10: writer and server lifetimes linked; writer death exits the process (demonstrated)
- [ ] EP-10: `/ready` endpoint reports writer liveness and pgmq reachability
- [ ] EP-10: error-body hygiene and ClickHouse credential configuration
- [ ] EP-11: dedicated writer connection separated from query-side connections
- [ ] EP-11: query-side connection pool serving concurrent metrics requests
- [ ] EP-11: typed row decoding replaces tab-delimited line parsing; decode failures are loud
- [ ] EP-12: versioned ClickHouse migration mechanism; single DDL owner
- [ ] EP-12: schema v2 migration (sort key, Nullable cleanup) applied and data rewritten
- [ ] EP-12: FINAL-free `events_resolved`; join-free DAU/WAU materialized views
- [ ] EP-12: rollup aggregate states replaced; storage and query-time verified against fixtures
- [ ] EP-9: (see plan file for its milestones; registry tracks overall status)
- [ ] EP-13: metric SQL inputs validated or parameterized end-to-end
- [ ] EP-13: funnel computed via ordered `windowFunnel` single pass
- [ ] EP-13: decode/parse failures surface as errors, not zeros; redundant re-sort removed
- [ ] EP-14: partial batch acceptance contract live in API, server, and `kansoku-client`
- [ ] EP-14: CORS preflight and payload/batch limits enforced
- [ ] EP-16: OTel exporter actually exports (current tracer provider has no exporter)
- [ ] EP-16: queue depth, batch flush latency/size, and insert-failure metrics emitted
- [ ] EP-16: readiness extended with queue-depth/lag thresholds
- [ ] EP-15: key model, storage, and issuance path
- [ ] EP-15: ingest authenticated (write keys, service tokens)
- [ ] EP-15: metrics read-authenticated and account-scoped

## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- 2026-07-15, during plan authoring (before any implementation):
  - A second build break exists beyond the shibuya one the review knew about: the pinned
    local `pgmq-migration` cut over to the pg-migrate framework and no longer exports
    `Pgmq.Migration.migrate`, breaking `Kansoku/Ingest/Queue.hs` `bootstrapQueue`
    (discovered while authoring EP-15; verified — `Pgmq.Migration` now exports only
    `pgmqMigrations :: Either DefinitionError MigrationComponent`). Folded into EP-10
    Milestone 1; EP-10's plan carries the pg-migrate consumption pattern.
  - ClickHaskell native query parameters: the pinned driver's protocol-level
    `QueryParameters` serialization is an unimplemented stub (verified in driver source by
    EP-13's author). SUPERSEDED later the same day: the corpus checkout was stale — updated
    upstream ships real protocol-level parameter support (commit `d372918`,
    `addParameter`/`passParameters`). Kansoku's `cabal.project` pin predates the feature,
    so EP-13 Milestone 1 now bumps the pin and adopts native parameters as the primary
    injection defense, retaining charset validation as defense-in-depth; EP-11's
    driver-behavior checks are re-run after the bump (EP-11 implements against the old pin
    in Phase 2; the bump lands with EP-13 in Phase 3).
  - ClickHaskell exposes no public way to close a `Connection` (the module holding the
    buffer close is an other-module). EP-11's query pool is designed to never destroy
    connections (one stripe, no idle reaping) rather than leak sockets; connection
    recycling would need an upstream or vendored close.
  - servant-openapi-hs has no `HasOpenApi` instance for `AuthProtect`; EP-15 supplies local
    instances in kansoku-api (openapi-hs has the SecurityScheme types) with an upstreaming
    note.
  - EP-12's `countState` rollups for event counts/page views deliberately trade replay
    dedup for bounded state (a replayed insert increments the count where `uniqExact` did
    not); both EP-12 and EP-13 document `count(DISTINCT event_id)` on raw as the
    replay-proof source. The ep6 fixture's deliberate duplicate row makes this visible
    (4 vs 3 page views on the fixture day).
  - Two Integration Points were added after authoring: the `Kansoku/Server.hs` WAI assembly
    (EP-9/EP-10/EP-14/EP-16 all touch it; EP-16 found the overlap) and plan 9's shared
    MultiVerb error tail (EP-14's 413 widens it).
  - `kansoku-client` currently derives client functions only for `IngestAPI`, so
    metrics-side wire changes (EP-13's funnel `window` param) touch only kansoku-api and
    the OpenAPI document.

- 2026-07-17, at implementation start:
  - The external cohort blueprint had never been run, so its prerequisite was not an auditable
    repository state. EP-21 now captures and implements the relevant work as a checked-in child
    plan before EP-10.
  - The generic stack's complex ordering is not applicable here: `mori show --full` confirms
    Kansoku consumes PGMQ and Shibuya but not Kiroku, Keiro, or Kioku, and the repository owns no
    PostgreSQL application SQL. The migration plan is therefore PGMQ-only.
  - Cabal and Nix were not merely on different source mechanisms; they selected different released
    cohorts. Cabal selected pg-migrate 1.1.0.0, PGMQ 0.4.0.1, Shibuya 0.8.0.1, and adapter
    0.12.0.0, while `nix/haskell.nix` pinned PGMQ 0.3.0.0, Shibuya 0.7.1.0, and adapter 0.8.0.0.


## Decision Log

- Decision: Create this MasterPlan covering (a) all findings of the 2026-07-15 architecture
  and performance review and (b) server-side readiness for kansoku's role as kikan's
  portfolio-wide analytics service.
  Rationale: The review found the MVP foundation architecturally sound but with reliability,
  resource-sharing, schema, and query-layer defects that become blocking as frontend and
  microservice consumers arrive; user chose to coordinate the fixes as one initiative.
  Date: 2026-07-15

- Decision: Adopt the pre-existing plan 9 (NamedRoutes/vertical slices/MultiVerb) as a child
  of this MasterPlan rather than leaving it standalone.
  Rationale: Plan 9 fixes the review's served-versus-documented API defect; adopting it gives
  one coordination point and lets EP-14/EP-15 depend on its restructured routing. User
  confirmed. Its `master_plan` frontmatter field now names this file.
  Date: 2026-07-15

- Decision: Scope foundation hardening to server-side readiness (auth/keys, tenancy, CORS,
  partial-batch contract, observability); JS/React SDKs and dashboard UI stay a separate
  initiative.
  Rationale: User selection; the server must be ready before client SDKs can be built against
  it, and mixing UI work into a hardening plan would balloon scope.
  Date: 2026-07-15

- Decision: Keep `account_id` leading the events_raw sort key in schema v2 (EP-12) even though
  the review noted no current query filters on it.
  Rationale: EP-15 makes metric queries account-scoped, which retroactively justifies the key;
  changing the key twice would mean two data rewrites. Recorded as an integration point.
  Date: 2026-07-15

- Decision: EP-10 remains deliberately small (supervision + readiness + config hygiene) but now
  hard-depends on EP-21, which owns the cohort, runtime-API, and PostgreSQL migration cutover.
  Rationale: The repository does not compile and the external blueprint was never run. Separating
  the concrete migration into a checked-in plan makes the prerequisite auditable while keeping
  production supervision independently verifiable.
  Date: 2026-07-15

- Decision: SUPERSEDED — do not run or update the external `migrate-keiro-stack` blueprint for
  this initiative. Implement its applicable migration work in EP-21 and leave the blueprint
  repository untouched.
  Rationale: User direction on 2026-07-17. The blueprint was never run, and Kansoku uses only the
  straightforward PGMQ/Shibuya slice. A self-contained ExecPlan is sufficient and avoids adding
  unused stack components or coupling completion to external repository state.
  Date: 2026-07-17

- Decision: EP-21 composes only the PGMQ pg-migrate component and keeps migration application out
  of normal server startup.
  Rationale: Kansoku has no other PostgreSQL component today. Explicit administrative migration
  makes production ordering inspectable and allows repeat-application behavior to be tested on an
  isolated database without touching persistent development state.
  Date: 2026-07-17

- Decision: Phases group eight children into four waves (Stabilize; Resource & storage;
  Query & contract quality; Portfolio readiness).
  Rationale: Eight child plans exceed the two-to-seven decomposition guideline; phases keep
  parallelizable work visible without merging unrelated concerns.
  Date: 2026-07-15


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision.

(To be filled during and after implementation.)

---

Revision note (2026-07-15): after the child plans were authored in parallel, the MasterPlan
was updated to reflect authoring-time discoveries: the second build break (pgmq-migration →
pg-migrate cutover) was folded into EP-10's Milestone 1 and into the Dependency Graph and
Progress sections; two Integration Points were added (`Kansoku/Server.hs` WAI assembly;
plan 9's shared MultiVerb error tail vs. EP-14's 413); and the Surprises & Discoveries
section now records the driver-capability findings (no native ClickHouse query parameters,
no public connection close) that shaped EP-13 and EP-11.

Revision note (2026-07-15, second revision): per user direction, the build restoration was
delegated to the operator-run `migrate-keiro-stack` seihou blueprint as an external
prerequisite; the Dependency Graph, Decision Log, EP-10's plan (Milestone 1 reframed as
verification with a hand-fix fallback), and EP-15's plan (Postgres migration mechanism must
follow the blueprint's pg-migrate manifest) were updated accordingly.

Revision note (2026-07-17): superseded the unexecuted external-blueprint prerequisite with
checked-in EP-21. The registry, first phase, dependency graph, PostgreSQL integration point,
progress, surprises, and decisions now make the PGMQ-only cohort and migration cutover a hard gate
before EP-10. Per user direction, no blueprint files are updated.
