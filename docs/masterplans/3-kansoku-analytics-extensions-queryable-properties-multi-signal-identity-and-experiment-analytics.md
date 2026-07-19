---
id: 3
slug: kansoku-analytics-extensions-queryable-properties-multi-signal-identity-and-experiment-analytics
title: "Kansoku analytics extensions: queryable properties, multi-signal identity, and experiment analytics"
kind: master-plan
created_at: 2026-07-15T21:43:50Z
intention: intention_01kxxscv06exbvqdtefzqnf9h5
---

# Kansoku analytics extensions: queryable properties, multi-signal identity, and experiment analytics

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

Kansoku is the kikan portfolio's first-party analytics service (this repository; four cabal
packages `kansoku-api`, `kansoku-core`, `kansoku-server`, `kansoku-client`; events land in
ClickHouse `analytics.events_raw` via a pgmq queue and a batched writer). MasterPlan 2
(`docs/masterplans/2-kansoku-production-hardening-review-fixes-and-portfolio-service-readiness.md`)
hardens that foundation. This MasterPlan builds the next capability layer on top of it,
addressing the two deliberate flat spots the 2026-07-15 data-model assessment identified and
the first advanced-analytics features that depend on them.

After this initiative is complete: event `properties` are analyzable, not just capturable —
metric queries can group and filter by declared event properties (for example "revenue by
`plan`", "conversion by `variant`") instead of being limited to the hardcoded
event-name/source/route dimensions, backed by typed ClickHouse storage rather than
JSON-string parsing of every row. Identity is multi-signal — the service distinguishes a
stable cookie `anonymousId` from a probabilistic device fingerprint and from other identifier
kinds (hashed email, device id), records them as evidence with per-signal confidence, and
resolves a canonical user from that evidence instead of a single latest-wins map; merge
conflicts are representable instead of silently last-write-wins, and fingerprint data has an
explicit retention/deletion policy. A/B experiments are first-class: assignment events are
registry-declared, per-variant rollups exist, and the metrics API answers conversion, funnel,
and exposure questions broken down by experiment and variant. Event schemas are governed —
events carry a schema version, the registry of declared event schemas is versioned and
publishable so every kikan microservice can validate against the same contract instead of a
copy frozen in kansoku's source.

Explicitly excluded: the JS/React browser SDKs and dashboard UI (separate frontend
initiative — client-side capture of fingerprints and experiment assignments arrives with it;
everything here is buildable and verifiable server-side with fixtures and curl). Kafka
ingestion stays deferred. Machine-learning-flavored features (predictive LTV, anomaly
detection) are out of scope. The four HTTP-501 metric stubs from the MVP stay stubbed except
where a plan here explicitly implements one.


## Decomposition Strategy

The initiative decomposes along the two data-model gaps plus the two capabilities they
unlock, so each plan owns one model extension end-to-end (wire type → storage → query →
API → client → OpenAPI) and is independently demonstrable. Queryable properties (EP-17) and
multi-signal identity (EP-18) are the enabling layers and are mutually independent — one
changes how event payloads are stored and queried, the other changes how identities are
resolved; they touch disjoint storage objects. Experiment analytics (EP-19) is deliberately a
separate plan even though it is "just" properties + metrics, because it has its own wire
contract (assignment event schemas), its own rollups, and its own API surface; folding it
into EP-17 would couple the generic property machinery to one consumer. Schema governance
(EP-20) is separated because it changes process and contract publication, not query
capability, and because other kikan services consume its output — it can proceed in parallel
with everything.

Alternatives considered: implementing experiment analytics purely query-time over generic
properties (no dedicated rollups) was rejected — exposure/variant joins over raw JSON are
exactly the per-query cost EP-17 exists to remove, and experiments are the highest-frequency
dashboard question the portfolio will ask. Making fingerprints a second column on
`identity_map` instead of a general signals table was rejected: it repeats the two-slot
mistake this initiative exists to fix. A fifth plan for organization-level analytics (the
stubbed `organizations` endpoint) was considered and deferred: `organization_id` is already
stored, and the endpoint is better implemented once property grouping (EP-17) exists to make
it non-trivial; recorded as future scope.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|----|-------|------|-----------|-----------|--------|
| 17 | Queryable event properties: typed storage and property-based grouping | docs/plans/17-queryable-event-properties-typed-storage-and-property-based-grouping.md | None (external: MP-2) | EP-20 | In Progress |
| 18 | Multi-signal identity: identifier kinds, fingerprints, and confidence-aware stitching | docs/plans/18-multi-signal-identity-identifier-kinds-fingerprints-and-confidence-aware-stitching.md | None (external: MP-2) | None | Not Started |
| 19 | Experiment analytics: assignment events, variant rollups, and per-variant metrics | docs/plans/19-experiment-analytics-assignment-events-variant-rollups-and-per-variant-metrics.md | EP-17 | EP-18, EP-20 | Not Started |
| 20 | Event schema governance: versioned registry and portfolio event contracts | docs/plans/20-event-schema-governance-versioned-registry-and-portfolio-event-contracts.md | None (external: MP-2) | None | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled.
Hard Deps and Soft Deps reference other rows by their # prefix (e.g., EP-17). "External:
MP-2" marks prerequisites satisfied by MasterPlan 2 rather than by rows in this table; see
Dependency Graph.

Phases (implementation waves):

- Phase 1 — Enabling layers (parallelizable): EP-17, EP-18, EP-20.
- Phase 2 — Capabilities: EP-19.


## Dependency Graph

This entire MasterPlan starts only after MasterPlan 2 is complete. The specific external
prerequisites, named so a future contributor can check them: the versioned ClickHouse
migration mechanism (MP-2 EP-12) — every schema object here is created through it; the
rewritten, validated query builders (MP-2 EP-13) — EP-17 extends them with property
expressions rather than extending the string-concatenation code they replace; account-scoped,
authenticated queries (MP-2 EP-15) — identity signals and experiment data are tenant data and
inherit its scoping; the NamedRoutes API structure (plan 9) and SDK-grade contract change
process (MP-2 EP-14) — EP-17/EP-18/EP-19/EP-20 all change `kansoku-api` wire types and must
move `kansoku-client` and the OpenAPI document in the same commits, following the idiom those
plans establish.

Within this MasterPlan: EP-17, EP-18, and EP-20 are mutually independent and can proceed in
parallel — EP-17 owns property storage and query grouping, EP-18 owns identity tables and
resolution, EP-20 owns the registry's versioning and publication. EP-19 hard-depends on
EP-17: per-variant metrics group by the `variant` property, and the whole point is to do that
through EP-17's typed property machinery, not through JSON string extraction. EP-19
soft-depends on EP-18 (per-variant unique-user counts are better on confidence-aware
canonical users, but work against the MP-2 resolution) and on EP-20 (assignment event schemas
are cleaner as versioned registry entries, but in-code registry entries work). EP-17
soft-depends on EP-20 only in the sense that registry-driven materialized columns get a
stable declaration format from it; EP-17 must work against the in-code registry and state so.

Client-side capture is NOT a dependency for any plan here: fingerprints and experiment
assignments will eventually arrive from the JS SDK initiative, but every plan validates with
fixture events posted via curl or the Haskell client.


## Integration Points

Properties storage representation — defined by EP-17, consumed by EP-19. EP-17 chose one
server-side `properties_json JSON MATERIALIZED CAST(properties, 'JSON')` column after a
10-million-row benchmark: the grouped aggregate median was 0.043 seconds versus 0.272
seconds for raw `JSONExtract*`, and compressed storage was 34% of the raw properties
column. Group keys use `toString(properties_json.<name>)`; numeric aggregates use
`CAST(properties_json.<name>, 'Float64')`. EP-19's variant grouping and rollup MVs must use
those expressions, never `JSONExtract*` over the raw string. Full evidence and alternatives
are in EP-17's Decision Log.

Event registry (`kansoku-api/src/Kansoku/Event/Registry.hs`) — EP-17 reads it to know which
properties are declared (and, if it chooses materialized columns, to drive them); EP-19 adds
experiment event schemas (`experiment_viewed` / assignment) to it; EP-20 versions and
externalizes it. Until EP-20 lands, the in-code registry is the source of truth and EP-17/
EP-19 write against it; EP-20 must migrate their entries without semantic change.

`AnalyticsEvent` wire type (`kansoku-api/src/Kansoku/Event/Types.hs`) — EP-18 adds an
optional identifier-signals field; EP-20 adds an optional schema-version field. Both are
additive and optional (existing producers keep working); each plan updates `kansoku-client`,
validation, `EventRow`/ClickHouse columns (through the migration mechanism), and the OpenAPI
document in the same change. If both plans are in flight simultaneously, coordinate field
naming here before either merges.

Identity resolution (`analytics.events_resolved` and successors) — EP-18 redefines how
`canonical_user` is computed (signals table + confidence policy). EP-19's per-variant unique
users consume `canonical_user` opaquely and must not encode assumptions about how it is
resolved. If EP-19 lands first, its rollups keyed on the MP-2-era `canonical_user` remain
correct when EP-18 swaps the resolution underneath — EP-18 must verify that property as part
of its acceptance.

ClickHouse migration mechanism (established by MP-2 EP-12) — all four plans create or alter
ClickHouse objects only through versioned migration files under `db/clickhouse/migrations/`.

Metrics API surface (`kansoku-api/src/Kansoku/Api/Metrics.hs` NamedRoutes records, after
plan 9) — EP-17 extends the groupBy contract (declared-property grouping), EP-19 adds
experiment endpoints. Both extend the records additively and regenerate client + OpenAPI.

ClickHaskell wire constraint (discovered during EP-17 authoring, verified against the
pinned driver) — the driver supports no `JSON` or `Map` column types on the wire, only the
primitive set (String, numerics, Nullable, LowCardinality, Array, …). Therefore every
property/identifier representation in this MasterPlan is server-side MATERIALIZED (or
view-computed) from the raw JSON `String` columns; the Haskell insert/select wire never
carries a JSON-typed column. EP-19's rollup materialized views inherit this rule, and
EP-18's `identifiers` extraction uses server-side JSON functions for the same reason.

ClickHouse migration file numbering — EP-17 and EP-18 run in parallel and both add files
under `db/clickhouse/migrations/` (EP-19 and possibly EP-20 add more). Migration numbers
written in plan prose are illustrative; at implementation time each plan takes the next
unclaimed number in the ledger, and the first plan to land renumbers nothing. MP-2's EP-12
owns the ledger mechanics; MP-2's EP-15 also appends migrations before this MasterPlan
starts.

`analytics.events_resolved` column contract — EP-17 extended the frozen output shape to
`event_id, event_name, occurred_at, url, account_id, canonical_user, properties_json`
(seven columns). The server-only native JSON column is required so property-grouped
unique-user metrics retain canonical identity stitching. EP-18 replaces the view's
internals under exactly this contract and re-runs an MP-2-era query battery to prove it;
EP-19 consumes `canonical_user`, `account_id`, and the documented property expressions.
Any plan needing more columns from the view extends the contract HERE first. ADR 0004
records the durable rationale.

Wire-field name claims on `AnalyticsEvent` — EP-18 claims `identifiers` (kind→value map),
EP-20 claims `schemaVersion` (optional Int, absent = 1). Both are recorded in the
respective plans; no collision. Future additive fields are claimed in this paragraph before
implementation.

Registry gap carried between plans — `payment_completed` and `feature_used` are queried by
builtin metrics today but undeclared in `defaultRegistry` (pre-existing gap found during
EP-17 authoring). EP-17 Milestone 2 declares them; EP-20 must carry those entries as
version 1 when it versions the registry.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [x] EP-17: property storage representation decided, prototyped, and migrated
- [x] EP-17: query builders support declared-property grouping and filtering
- [ ] EP-17: metrics API groupBy/filter contract extended; client + OpenAPI regenerated
- [ ] EP-18: identity-signals model (wire field, storage, ingestion) live
- [ ] EP-18: confidence-aware resolution replaces latest-wins; merge conflicts representable
- [ ] EP-18: fingerprint retention/deletion policy implemented and documented
- [ ] EP-19: assignment event schemas registered; variant rollups populated
- [ ] EP-19: per-variant metrics endpoints (exposure, conversion, funnel) serving
- [ ] EP-20: events carry schema version; versioned registry established
- [ ] EP-20: portfolio event contract published and consumable by other kikan services


## Surprises & Discoveries

Document cross-plan insights, dependency changes, scope adjustments, or unexpected
interactions between child plans. Provide concise evidence.

- 2026-07-15, during plan authoring (before any implementation):
  - The pinned ClickHaskell driver has no `JSON`/`Map` column wire support (verified against
    its primitive-type modules), which removes "typed wire, typed storage" as an option:
    all candidate property representations in EP-17 are MATERIALIZED server-side from the
    raw JSON strings. Promoted to an Integration Point.
  - The dev-shell ClickHouse is 26.5.1 (verified live), comfortably past the native JSON
    type's maturity bar — the native-JSON candidate in EP-17's benchmark is viable.
  - `payment_completed` and `feature_used` are queried by builtin metrics but undeclared in
    the event registry — a pre-existing MVP gap; EP-17 declares them, EP-20 carries them.
  - EP-20 folded client/OpenAPI regeneration into each wire-changing milestone rather than
    a trailing milestone, to honor MP-2's same-commit contract discipline; the deviation
    from its brief is recorded in its Decision Log.
  - The `migrate-keiro-stack` blueprint (MP-2's external prerequisite) upgrades the whole
    dependency cohort before MP-2 implementation; by the time this MasterPlan runs, plans
    here must treat MP-2's landed tree — not the code quoted in their Context sections —
    as ground truth. Every child plan carries a reconcile-at-start step.

- 2026-07-19, during EP-17 implementation:
  - Property-grouped unique-user metrics require the typed property projection on
    `analytics.events_resolved`; its shared contract now has a seventh `properties_json`
    column. ADR 0004 records the decision, and EP-18 must preserve it when replacing the
    view's identity-resolution internals.


## Decision Log

- Decision: Create this follow-up MasterPlan now, scoped to the data-model extensions the
  2026-07-15 assessment identified (queryable properties, multi-signal identity, experiment
  analytics, schema governance), sequenced strictly after MasterPlan 2.
  Rationale: User needs these features soon; the assessment concluded the current model
  captures the data but cannot analyze it (opaque JSON properties) and cannot distinguish
  identifier kinds (two-slot identity); both gaps are additive to fix and nothing in MP-2
  forecloses them.
  Date: 2026-07-15

- Decision: JS/React SDK and dashboard work stays excluded; all validation here is
  server-side via fixtures.
  Rationale: Consistent with MP-2 scoping; client capture consumes these server capabilities
  but does not gate building them.
  Date: 2026-07-15

- Decision: Experiment analytics is its own plan (EP-19) rather than a demo inside EP-17.
  Rationale: It has its own wire contract, rollups, and API surface; coupling the generic
  property machinery to its first consumer would blur ownership.
  Date: 2026-07-15

- Decision: Organization-level analytics (the stubbed `organizations` endpoint) deferred out
  of this MasterPlan.
  Rationale: Better implemented once property grouping exists; recorded as future scope.
  Date: 2026-07-15


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision.

(To be filled during and after implementation.)

---

Revision note (2026-07-15): after the four child plans were authored in parallel, the
Integration Points section gained five entries discovered during authoring (the ClickHaskell
no-JSON/Map wire constraint, migration-number claiming, the frozen `events_resolved` column
contract, `AnalyticsEvent` wire-field name claims, and the undeclared-registry-entries
handoff), and Surprises & Discoveries records the authoring-time findings including the
`migrate-keiro-stack` blueprint prerequisite inherited from MasterPlan 2.
