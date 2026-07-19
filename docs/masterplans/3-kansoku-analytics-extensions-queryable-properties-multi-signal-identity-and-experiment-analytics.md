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
| 17 | Queryable event properties: typed storage and property-based grouping | docs/plans/17-queryable-event-properties-typed-storage-and-property-based-grouping.md | None (external: MP-2) | EP-20 | Complete |
| 18 | Multi-signal identity: identifier kinds, fingerprints, and confidence-aware stitching | docs/plans/18-multi-signal-identity-identifier-kinds-fingerprints-and-confidence-aware-stitching.md | None (external: MP-2) | None | Complete |
| 19 | Experiment analytics: assignment events, variant rollups, and per-variant metrics | docs/plans/19-experiment-analytics-assignment-events-variant-rollups-and-per-variant-metrics.md | EP-17 | EP-18, EP-20 | Complete |
| 20 | Event schema governance: versioned registry and portfolio event contracts | docs/plans/20-event-schema-governance-versioned-registry-and-portfolio-event-contracts.md | None (external: MP-2) | None | Complete |

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
column. Group keys use
`toString(getSubcolumn(properties_json, '<name>'))`; numeric aggregates use
`CAST(getSubcolumn(properties_json, '<name>'), 'Float64')`. `getSubcolumn` is required
because identity-resolved views expose the JSON value as an expression, for which direct
dot syntax is not reliable. EP-19's variant grouping and rollup MVs must use those
expressions, never `JSONExtract*` over the raw string. Full evidence and alternatives are
in EP-17's Decision Log.

Event registry (`kansoku-api/src/Kansoku/Event/Registry.hs`) — the in-code registry remains
the authoring source of truth and now maps each name to immutable contiguous versions. EP-17
reads the latest schema for property-query compilation, EP-19's `experiment_viewed` entry
retains both SQL-safe patterns, and EP-20 migrated all eight landed entries as version 1.
The complete producer contract is public at `GET /v1/schemas` and committed at
`docs/contracts/events.json`; ADR 0007 owns its governance and compatibility rules.

`AnalyticsEvent` wire type (`kansoku-api/src/Kansoku/Event/Types.hs`) — EP-18 shipped the
optional `identifiers :: Maybe (Map Text Text)` field; EP-20 shipped optional
`schemaVersion :: Maybe Int`, where absence means 1. Both are additive and optional, and
both moved `kansoku-client`, validation, `EventRow`/ClickHouse storage, and OpenAPI in their
wire-changing commits.

Identity resolution (`analytics.events_resolved` and successors) — EP-18 now computes
`canonical_user` from account-scoped `identity_signals` plus the view-time confidence
policy recorded in ADR 0005. EP-19's per-variant unique
users consume `canonical_user` opaquely and must not encode assumptions about how it is
resolved. EP-18's pre- and post-retirement batteries preserved the shared projection and
MP-2-era counts, so EP-19 can consume the resolved value without identity-policy
assumptions.

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
unique-user metrics retain canonical identity stitching. EP-18 replaced the view's
internals under exactly this contract and re-ran the MP-2-era query battery to prove it;
EP-19 consumes `canonical_user`, `account_id`, and the documented property expressions.
Any plan needing more columns from the view extends the contract HERE first. ADR 0004
records the durable rationale.

Wire-field name claims on `AnalyticsEvent` — EP-18 shipped `identifiers` (kind→value map),
and EP-20 shipped `schemaVersion` (optional Int, absent = 1). Both are recorded in the
respective plans; no collision. Future additive fields are claimed in this paragraph before
implementation.

Registry gap carried between plans — EP-17 declared the previously missing
`payment_completed` and `feature_used` builtins, and EP-20 carried both as version 1 with
their types and requiredness unchanged.


## Progress

Track milestone-level progress across all child plans. Each entry names the child plan
and the milestone. This section provides an at-a-glance view of the entire initiative.

- [x] EP-17: property storage representation decided, prototyped, and migrated
- [x] EP-17: query builders support declared-property grouping and filtering
- [x] EP-17: metrics API groupBy/filter contract extended; client + OpenAPI regenerated
- [x] EP-18: identity-signals model (wire field, storage, ingestion) live
- [x] EP-18: confidence-aware resolution replaces latest-wins; merge conflicts representable
- [x] EP-18: fingerprint retention/deletion policy implemented and documented
- [x] EP-19: assignment event schemas registered; variant rollups populated
- [x] EP-19: per-variant metrics endpoints (exposure, conversion, funnel) serving
- [x] EP-20: events carry schema version; versioned registry established
- [x] EP-20: portfolio event contract published and consumable by other kikan services


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
  - The `revenue` builtin existed in the registry and compiler but had no HTTP route.
    EP-17 exposes it additively as `GET /metrics/revenue`; the generated OpenAPI contract
    now contains 14 analytics paths.
  - A first property read through `analytics.events_resolved` failed because direct JSON
    dot syntax did not survive the view expression boundary. EP-17 now renders
    `getSubcolumn(properties_json, '<name>')`; a repeated 10-million-row benchmark kept the
    grouped-sum median within the adoption threshold (0.051 seconds versus the original
    raw-JSON baseline of 0.272 seconds).

- 2026-07-19, during EP-18 implementation:
  - `analytics.events_resolved` retained the ordered seven-column EP-17 projection while
    moving from the latest-wins cookie map to account-scoped evidence plus view-time
    confidence. Fresh pre- and post-retirement batteries both returned 3 stitched users
    and 4 raw DAU; EP-19 can consume `canonical_user` and `properties_json` unchanged.
  - Identity conflicts are now durable data rather than merge casualties. The shared
    fingerprint fixture exposed both `user-U` and `user-V`, while equal-confidence
    resolution selected the more recent observation and the stronger cookie kept session
    A on `user-U`.
  - EP-17's materialized native JSON column requires direct SQL fixtures to provide valid
    `properties` JSON. EP-18 and the legacy EP-5/EP-6 fixtures now write explicit `'{}'`
    values; production Haskell inserts already did so.
  - ADR 0005 owns the cross-plan identifier vocabulary, one-hop evidence semantics,
    ranking policy, conflict visibility, and 180-day fingerprint boundary.

- 2026-07-19, during EP-19 implementation:
  - The event contract is exposure-based: `experiment_viewed` means a variant was actually
    shown. Its required `experiment` and `variant` properties use the same SQL-safe name
    rule as metric inputs, and the rollup returned the expected account/day/variant counts
    `5/1/5/2` under replay-safe unique sketches.
  - A ClickHouse 26 insert block containing no experiment JSON paths left
    `toString(getSubcolumn(...))` dynamically typed while analyzing the materialized view's
    `GROUP BY`. Immutable corrective migration `0015` recreates only the EP-19 view with an
    explicit outer String cast; fresh replay through `0015` and ordinary inserts passed.
  - Exact stitched conversion and funnel queries share a first-exposure boundary. The live
    account-A fixture returned control/treatment conversions `1/3` from `5/5` exposures and
    ordered funnels `1/1` and `4/3`; account B remained isolated. ADR 0006 owns these
    semantics and explicitly excludes significance claims.

- 2026-07-19, during EP-20 implementation:
  - The landed registry contained eight entries plus EP-19's generic `SqlNamePattern`, not
    the five-entry pre-sibling sketch. All eight became immutable version 1, and the public
    catalog gained a nullable `pattern` field so it does not omit enforced semantics.
  - `schemaVersion` is compatible with EP-18's `identifiers`: both optional wire fields and
    their ClickHouse columns coexist, while migration `0016` appends the version after the
    identifier map. Live ingest persisted versionless/pinned-v1 events as 1 and an unknown
    event's explicit version as 7.
  - The deterministic catalog is one pure value served publicly, decoded by the Haskell SDK,
    and committed as JSON. A deliberate illegal in-place schema edit made the golden test
    fail with its regeneration instruction; reversing the edit restored the suite. ADR 0007
    owns the durable versioning and publication policy.


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

- Decision: EP-17's cross-plan property-storage contract is one server-materialized native
  JSON column, read with registry-validated
  `getSubcolumn(properties_json, '<name>')` expressions.
  Rationale: the 10-million-row benchmark met the latency and storage thresholds without
  per-property DDL. `getSubcolumn` also works through the identity-resolved view expression,
  unlike direct dot access. EP-19 must reuse this contract for variant dimensions and
  numeric inputs.
  Date: 2026-07-19

- Decision: EP-18's cross-plan identity contract is account-scoped immutable signal
  evidence with view-time confidence (`email_sha256` 0.95, cookie 0.90, device 0.80,
  fingerprint 0.50), one-hop bindings, queryable conflicts, and a 180-day fingerprint
  TTL. The old latest-wins map is retired only after compatibility verification.
  Rationale: preserves conflicts and permits policy revision without rewriting history,
  while the unchanged resolved-event projection insulates EP-19 and existing metrics.
  Durable rationale and privacy consequences live in ADR 0005.
  Date: 2026-07-19

- Decision: EP-19's cross-plan experiment contract is render-time
  `experiment_viewed`, an approximate raw-identity exposure rollup, and exact canonical-user
  conversion/funnel endpoints that exclude pre-exposure outcomes. Users seen in multiple
  variants count in each, and no endpoint declares statistical significance or a winner.
  Rationale: This preserves causal ordering, keeps the high-frequency dashboard read cheap,
  leaves identity resolution revisable at query time for attribution, and makes data-quality
  contamination visible. Durable rationale and consequences live in ADR 0006.
  Date: 2026-07-19

- Decision: EP-20's cross-plan schema contract is an in-source, immutable and contiguous
  version registry; absence means version 1, known names require an exact known version,
  unknown names remain permissive, and the same pattern-complete catalog is public at
  `GET /v1/schemas` and committed at `docs/contracts/events.json`.
  Rationale: This pins legacy producer meaning, preserves organic event adoption, records
  the accepting schema era in ClickHouse, and gives runtime and review-time consumers one
  drift-guarded contract without operating a separate registry service. Durable rationale
  and consequences live in ADR 0007.
  Date: 2026-07-19


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original vision.

EP-17 completed on 2026-07-19. It delivered benchmark-selected native JSON property
storage, registry-gated grouping/filtering/aggregation, the public revenue route, generated
client/OpenAPI updates, and a real-network HTTP integration over fresh PostgreSQL plus live
ClickHouse. Its two downstream contracts are now stable: EP-18 preserved the seventh
`properties_json` column on `analytics.events_resolved`, and EP-19 must render property
reads through `getSubcolumn`.

EP-18 completed on 2026-07-19. It delivered the optional typed `identifiers` map across
API, client, OpenAPI, writer, and storage; account-scoped evidence with confidence-ranked
resolution and queryable conflicts; 180-day fingerprint evidence retention; an exercised
raw-retention and per-user erasure runbook; and retirement of the latest-wins identity
map. The seven-column resolved-event contract and MP-2-era counts remained stable. EP-19
could therefore consume canonical identity and native properties without compatibility
work.

EP-19 completed on 2026-07-19. It delivered the validated `experiment_viewed` exposure
contract; an account/experiment/variant/day exposure rollup; authenticated exposure,
conversion, and ordered-funnel endpoints; typed client selectors and regenerated OpenAPI;
and ADR 0006's durable attribution semantics. Fresh migrations, real HTTP acceptance, and
the final 120-core/11-client test pass verified exact post-exposure counts, tenant
isolation, malformed-input rejection, and empty unknown-experiment results.

EP-20 completed on 2026-07-19. It delivered immutable per-event schema versions,
version-aware validation and persistence, producer pinning, a public browser-readable
catalog, a deterministic committed artifact, SDK catalog fetching, a golden drift guard,
the producer governance guide, and ADR 0007. Live HTTP/ClickHouse acceptance proved legacy,
pinned, unavailable-version, unknown-name, catalog, pattern, and CORS behavior. The final
suite reached 133 core and 13 client examples with no failures (the one opt-in live client
test remained intentionally pending), and both generated artifacts were byte-stable.

MasterPlan 3 is complete. Queryable properties, evidence-based multi-signal identity,
exposure-based experiment analytics, and schema governance now compose through the stable
`events_resolved`, event registry, wire, storage, client, and OpenAPI contracts. ADRs
0004–0007 own the four durable capability boundaries. Deferred scope remains explicit:
browser SDK/dashboard work, statistical significance, version-specific property metrics,
organization analytics, and external kikan/mori publication pointers.

---

Revision note (2026-07-15): after the four child plans were authored in parallel, the
Integration Points section gained five entries discovered during authoring (the ClickHaskell
no-JSON/Map wire constraint, migration-number claiming, the frozen `events_resolved` column
contract, `AnalyticsEvent` wire-field name claims, and the undeclared-registry-entries
handoff), and Surprises & Discoveries records the authoring-time findings including the
`migrate-keiro-stack` blueprint prerequisite inherited from MasterPlan 2.

Revision note (2026-07-19, EP-18 completion): marked EP-18 complete, recorded its shipped
wire and resolved-event contracts, captured cross-plan verification evidence, linked ADR
0005's durable identity policy, and updated the remaining initiative outcome to EP-19 and
EP-20.

Revision note (2026-07-19, EP-19 completion): marked EP-19 complete, recorded the shipped
exposure rollup and three per-variant endpoints, captured the ClickHouse Dynamic cast
correction and end-to-end counts, linked ADR 0006, and left EP-20 as the sole remaining
child plan.

Revision note (2026-07-19, initiative completion): marked EP-20 and MasterPlan 3 complete,
recorded the versioned registry and pattern-complete public catalog, captured the golden
drift proof and live persistence/catalog evidence, and distilled the final durable boundary
into ADR 0007 alongside ADRs 0004–0006.
