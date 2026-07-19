---
id: 20
slug: event-schema-governance-versioned-registry-and-portfolio-event-contracts
title: "Event schema governance: versioned registry and portfolio event contracts"
kind: exec-plan
created_at: 2026-07-15T21:43:59Z
intention: intention_01kxxscv06exbvqdtefzqnf9h5
master_plan: "docs/masterplans/3-kansoku-analytics-extensions-queryable-properties-multi-signal-identity-and-experiment-analytics.md"
---

# Event schema governance: versioned registry and portfolio event contracts

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Kansoku is the kikan portfolio's first-party analytics service. Every microservice in the
portfolio will emit analytics events to it. Today the catalog of declared event schemas —
which event names exist, what properties they carry, which are required — is a Haskell value
(`defaultRegistry` in `kansoku-api/src/Kansoku/Event/Registry.hs`) frozen into kansoku's
source code. A service that wants to emit `subscription_started` correctly has no way to
discover the current expected shape except by reading kansoku's source. When a schema changes
there is no signal to producers, and events carry no schema version, so a producer emitting
yesterday's shape and a consumer expecting today's cannot even detect the mismatch. As the
portfolio grows to many producers, that schema drift becomes silent data corruption: rows
land, queries run, and the numbers are quietly wrong.

After this plan is implemented, three things are true and demonstrable. First, events can
carry a schema version: `AnalyticsEvent` gains an optional `schemaVersion` field (JSON key
`"schemaVersion"`, absent means version 1), validation checks the event against exactly the
named version of its schema, an unknown version of a known event is rejected with an error
that names the versions that do exist, and the version is persisted into the ClickHouse
`analytics.events_raw` table (column `schema_version`) so analysts can segment any metric by
schema era. Second, the registry itself is versioned: each event name maps to a non-empty
list of immutable schema versions, each with a changelog note, and the whole catalog is
served as machine-readable JSON at `GET /v1/schemas` — any kikan service (or a human with
`curl`) can fetch the current contract from the running service. Third, the contract is
governed: a committed artifact `docs/contracts/events.json` is kept identical to the served
document by a golden test that fails CI on drift, and a short authored guide
`docs/event-schema-governance.md` tells a service author who has never seen kansoku's
internals how to declare a new event, when to bump a version, and how to pin one.

To see it working after implementation: start the local stack (`just up` in one terminal,
`just run` in another, both inside `nix develop`), then `curl -s localhost:8080/v1/schemas`
prints the versioned catalog; posting an event with `"schemaVersion": 2` where only version 1
exists returns HTTP 400 naming `[1]` as the known versions; posting the same event without a
version is accepted as version 1; and `cabal test` fails if the registry is edited without
regenerating `docs/contracts/events.json`.

Explicitly out of scope: a standalone schema-registry service (kansoku serves its own
contract over HTTP — that is the whole design), any external DSL or configuration-file
format for declaring schemas, enforcement of schemas on unknown event names (the MVP's
permissive policy stands, see Decision Log), and automated propagation of the contract into
other kikan repositories (recorded as a future-scope hook, not implemented here).


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-07-19 14:43 PDT) M0: verified the post-MasterPlan-2 baseline (NamedRoutes
      record, migration runner, auth, committed `docs/api/openapi.json`) and recorded the
      landed EP-17/EP-18/EP-19 deviations below
- [x] (2026-07-19 14:58 PDT) M1: `EventRegistry` remodeled as `Map EventName (NonEmpty EventSchema)`;
      `EventSchema` gains `schemaVersion :: Int` and `schemaNote :: Text`; `PropertySpec`
      gains `propDescription :: Maybe Text`; lookup helpers added
- [x] (2026-07-19 14:58 PDT) M1: `defaultRegistry` entries migrated as version 1 with no semantic change
      (including any EP-17 / EP-19 additions that landed first)
- [x] (2026-07-19 14:58 PDT) M1: `AnalyticsEvent` gains `schemaVersion :: Maybe Int`; `baseEvent` defaults it to
      `Nothing`
- [x] (2026-07-19 14:58 PDT) M1: validation resolves the requested version, rejects unknown versions of known
      events (`UnknownSchemaVersion`), rejects out-of-range versions
      (`InvalidSchemaVersion`), keeps unknown event names permissive
- [x] (2026-07-19 14:58 PDT) M1: ClickHouse migration adds `schema_version UInt16 DEFAULT 1` to
      `analytics.events_raw`; `EventRow` maps it
- [x] (2026-07-19 14:58 PDT) M1: `kansoku-client` helper `trackEventWithVersion`; client and OpenAPI document
      regenerated in the same commit as the wire change
- [x] (2026-07-19 14:58 PDT) M1: unit tests in `kansoku-core/test/Kansoku/EventSpec.hs` cover the new validation
      paths and JSON round-trip; `cabal test` green; M1 committed
- [x] (2026-07-19 15:12 PDT) M2: `Kansoku.Event.Contract` module (`SchemaCatalog` DTOs, `schemaCatalog`
      derivation, JSON instances)
- [x] (2026-07-19 15:12 PDT) M2: `GET /v1/schemas` served (public, `application/json`); route in the NamedRoutes
      record; OpenAPI document regenerated
- [x] (2026-07-19 15:12 PDT) M2: `kansoku-contracts` executable writes `docs/contracts/events.json`; artifact
      committed; justfile `contracts` recipe added
- [x] (2026-07-19 15:12 PDT) M2: golden test `kansoku-core/test/Kansoku/ContractSpec.hs` (served catalog equals
      committed artifact; registry version invariants; JSON round-trip); drift demo
      performed; M2 committed
- [x] (2026-07-19 15:12 PDT) M2: `kansoku-client` exposes `fetchSchemaCatalog`; committed with M2's wire change
- [ ] M3: `docs/event-schema-governance.md` authored for kikan service authors
- [ ] M3: full validation pass (transcripts captured into this plan), MasterPlan 3
      progress checkboxes updated, portfolio-publication hook recorded as future scope;
      M3 committed
- [ ] Outcomes & Retrospective written


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- 2026-07-19: The landed registry has eight, not five, schemas. EP-17 added
  `payment_completed` and `feature_used`, and EP-19 added `experiment_viewed` plus the
  generic `propPattern :: Maybe PropertyPattern` field and `SqlNamePattern`. Versioning
  must preserve all eight schemas and every pattern exactly; `propDescription` is a new
  fifth `PropertySpec` field rather than a replacement for the pattern field.

- 2026-07-19: The root `KansokuAPI` is a NamedRoutes record, but it currently contains only
  authenticated `ingest` and `metrics` sub-records. `/health`, `/ready`,
  `/internal/metrics`, and `/openapi.json` remain deliberately WAI-level per ADR 0001.
  The public catalog can join the root record as an unauthenticated `schemas` field without
  moving those operational routes or changing either auth family.

- 2026-07-19: EP-18's optional `identifiers` field and ClickHouse column are landed, so
  `schemaVersion` has no naming collision and `schema_version` appends after `identifiers`.
  The migration ledger is occupied through EP-19's immutable `0015`; this plan claims
  `0016_events_raw_schema_version.sql`.

- 2026-07-19: The fully live baseline is green: `just build`, deterministic
  `just openapi-check`, 120 core examples, and 11 client examples passed with zero failures;
  the one client test requiring `KANSOKU_SERVER_URL` remains intentionally pending.

- 2026-07-19: The process-compose UI already owns port 8080, and the shared local `kansoku`
  Postgres database contains a partial PGMQ install. M1 live acceptance therefore used a
  fresh `kansoku_ep20_m1` database, isolated queue, and port 18080; the server and temporary
  database were stopped and removed afterwards.

- 2026-07-19: The landed EP-14 single-ingest rejection format is the shared
  `ErrorEnvelopeWire`, so the unknown-version response places the rendered validation text
  in `message` rather than a `details` array. The observed HTTP 400 body was
  `{"code":"validation_failed","message":"validation failed: event 'page_view': schemaVersion 2 is unknown; known versions: [1]","retryable":false}`.

- 2026-07-19: The planned catalog property shape omitted EP-19's landed
  `SqlNamePattern`, even though the milestone promises the full registry. The public DTO now
  includes a fixed nullable `pattern` key and publishes `[a-z0-9_.:-]{1,128}` for both
  `experiment_viewed` identifiers; a contract test pins that propagation.

- 2026-07-19: `/v1/schemas` shares the existing `/v1` CORS middleware with ingestion. Its
  policy originally allowed only POST preflights, so M2 added GET while preserving the
  existing origins and auth-header policy. Live acceptance returned
  `Access-Control-Allow-Origin: *` for an Origin-bearing catalog request.


## Decision Log

Record every decision made while working on the plan.

- Decision: The registry stays in Haskell source (`kansoku-api/src/Kansoku/Event/Registry.hs`)
  as the single source of truth; external DSL or configuration-file registries are rejected
  for now.
  Rationale: The Haskell registry is typed (the compiler rejects malformed schemas), tested
  (the suite in `kansoku-core/test/` exercises it), and versioned by git with ordinary PR
  review as the governance gate. Externalizing it would add a parser, a loading path, and a
  new drift surface (file vs. code) while there are zero portfolio consumers that need to
  author schemas without touching this repo. Publication (the served JSON contract) is
  decoupled from authorship, so this decision can be revisited later without changing the
  wire contract.
  Date: 2026-07-15

- Decision: Schema versions are immutable once released; every change — new property, type
  change, requiredness change, and also additive optional properties — is a new version.
  Rationale: Allowing additive optional properties within a version was considered and
  rejected. It would save a version bump occasionally, but it makes "version N" mean a range
  of shapes rather than one shape, so the persisted `schema_version` column stops identifying
  what a producer actually emitted, and reviewers must reason about which kinds of edit are
  in-place-legal. At this portfolio's scale a version bump costs one registry entry and one
  regenerated artifact; simplicity beats cleverness. The golden test makes any in-place edit
  visible in review as a diff to a released version block.
  Date: 2026-07-15

- Decision: Unknown event names remain permissive — they pass validation with no schema
  errors, with or without a `schemaVersion` field. Permissiveness is name-scoped: an unknown
  event that declares `"schemaVersion": 7` is accepted (subject only to structural checks),
  because there is no registry entry to check it against.
  Rationale: This restates the MVP policy unchanged (see `validateEventWith` in
  `kansoku-api/src/Kansoku/Event/Validation.hs`). Organic event adoption must not require
  registry ceremony: a product team can start emitting a new event today and declare its
  schema later. The registry adds strictness only for names it knows.
  Date: 2026-07-15

- Decision: An absent `schemaVersion` means version 1 — not "latest".
  Rationale: Every event emitted before this plan was written against the original shape of
  its schema, which becomes version 1 verbatim. Treating absence as "latest" would silently
  change validation semantics underneath versionless producers every time a schema bumps —
  exactly the undetectable drift this plan exists to remove. Absence-means-1 pins legacy
  producers to the shape they were written against; new producers that adopt a later schema
  say so explicitly.
  Date: 2026-07-15

- Decision: `GET /v1/schemas` is public (no authentication), like `/health`, `/ready`, and
  `/openapi.json`.
  Rationale: The catalog describes the service's contract, not tenant data — it contains no
  events, no identifiers, no account-scoped values, exactly like the OpenAPI document that
  MP-2 EP-15 (`docs/plans/15-api-keys-service-auth-and-account-scoped-queries.md`) explicitly
  keeps public. Producers should be able to fetch the contract before they have credentials.
  Date: 2026-07-15

- Decision: Drift between code and published contract is guarded by a committed artifact
  (`docs/contracts/events.json`) plus a golden test that compares the artifact to the live
  catalog by JSON value equality (not byte equality).
  Rationale: The committed file gives reviewers a plain diff of every contract change and
  gives the portfolio a stable path to reference without a running server. Value equality
  makes the test immune to formatting churn while still failing on any semantic change. The
  regenerator (`cabal run kansoku-contracts`) mirrors the `kansoku-openapi` /
  `docs/api/openapi.json` idiom established by plan 9
  (`docs/plans/9-convert-kansoku-to-namedroutes-vertical-slices-and-multiverb.md`).
  Date: 2026-07-15

- Decision: The persisted column is `schema_version UInt16 DEFAULT 1` on
  `analytics.events_raw`, added through the MP-2 EP-12 migration mechanism.
  Rationale: `UInt16` (0–65535) is generous for per-event schema versions while staying
  narrow; `DEFAULT 1` makes every pre-existing row and every versionless event a version-1
  row, matching the wire semantics. Validation bounds accepted versions to 1–65535 so the
  wire-to-column mapping is total.
  Date: 2026-07-15

- Decision: The wire field is named `schemaVersion`. MasterPlan 3's "AnalyticsEvent wire
  type" integration point requires coordinating field naming with EP-18
  (`docs/plans/18-multi-signal-identity-identifier-kinds-fingerprints-and-confidence-aware-stitching.md`),
  which adds an optional identifier-signals field expected to be named `identifiers`.
  Rationale: The names are disjoint, both fields are optional and additive (existing
  producers keep working), and `omitNothingFields = True` keeps absent fields off the wire.
  If EP-18 is in flight simultaneously, confirm in MasterPlan 3's Integration Points section
  that it has not claimed `schemaVersion` before merging; record the confirmation here.
  Date: 2026-07-15

- Decision: Client and OpenAPI updates land in the same commits as the wire changes they
  reflect — the `schemaVersion` field with Milestone 1, the `/v1/schemas` route with
  Milestone 2 — rather than being batched into Milestone 3.
  Rationale: MasterPlan 2's wire-change discipline (established by plan 9 and EP-14) is that
  `kansoku-client` and the OpenAPI document move in the same commits as any `kansoku-api`
  contract change, so no commit leaves the SDK or the published document stale. Milestone 3
  is therefore documentation and end-to-end validation only.
  Date: 2026-07-15

- Decision: Portfolio publication beyond this repository is a recorded hook, not implemented
  scope. The kikan umbrella's signal catalog
  (`/Users/shinzui/Keikaku/bokuno/kikan/docs/architecture/signals/kansoku.md`) and the mori
  registry (project `shinzui/kansoku`, which currently registers no docs) can reference the
  committed `docs/contracts/events.json` and the served `GET /v1/schemas`; wiring those
  references is future scope for the kikan/mori side.
  Rationale: The contract's source of truth is kansoku, served over HTTP; this plan stays
  self-contained and server-owned. Publishing pointers from umbrella docs is trivial once the
  artifact exists and belongs to the repos that own those docs.
  Date: 2026-07-15

- Decision: Migrate all eight landed schemas into immutable version 1 and retain
  `PropertyPattern` beside the new descriptions. Existing property-query compilation uses
  `latestSchema` after the registry remodel.
  Rationale: EP-17 and EP-19 have completed, so dropping their declarations or pattern
  constraints would be a semantic regression. Choosing the latest schema preserves today's
  one-shape lookup behavior and makes newly declared properties available to metrics; explicit
  schema-version dimensions for metric compilation are separate future scope.
  Date: 2026-07-19

- Decision: Add `/v1/schemas` as a public field on the landed root `KansokuAPI` NamedRoutes
  record; keep the four operational/meta endpoints in `waiWrapper`.
  Rationale: This makes the published catalog part of the served, client-derived, and OpenAPI
  contract while preserving ADR 0001's intentional separation of operational routes and
  ADR 0003's auth boundaries around only ingest and metrics.
  Date: 2026-07-19

- Decision: Publish a nullable `pattern` field on every contract property and render
  `SqlNamePattern` as `[a-z0-9_.:-]{1,128}`.
  Rationale: EP-19 made the pattern part of validation before EP-20 started. Omitting it from
  a catalog described as the full event contract would cause producer tooling to accept
  values the service rejects. A fixed nullable field keeps the document shape predictable
  and leaves room for additional typed patterns in future catalog versions.
  Date: 2026-07-19


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

- M1 (2026-07-19): The registry now carries ordered immutable versions for all eight landed
  schemas, `schemaVersion` is optional on the wire and defaults to 1 for validation and
  persistence, known-name/unknown-version requests fail with a readable 400, and unknown
  names remain permissive. Migration 0016 applied once and skipped on replay. Live HTTP
  acceptance returned 400 for `page_view` version 2, 202 for versionless and pinned-v1
  `page_view` events, and 202 for an unknown event at version 7. ClickHouse then showed
  versions 1, 1, and 7 respectively. `just build` and the suites passed (128 core examples;
  12 client examples with the one opt-in live test pending), and two OpenAPI generations
  produced the same SHA-256
  `bf7a00fb8b22d2a69d73d315f538ba3a1143fbefb261e2e4e1d61f738c2a0c6a`.

- M2 (2026-07-19): The public catalog is served from the same pure `schemaCatalog` value
  used by the deterministic artifact generator and SDK decoder. Live acceptance returned
  HTTP 200, JSON content type, browser CORS, all eight events, version-1 `page_view`, and
  both experiment patterns without credentials. The golden guard failed with its exact
  remediation message after a temporary in-place `page_view` edit and passed after that edit
  was reversed. The full suites passed (133 core examples; 13 client examples with one
  opt-in live test pending). Repeated generation preserved SHA-256
  `f930d8ad022ca281994a8adbbb840f4fa55eae29a5766804be3faf9c08337eff` for the contract and
  `dc40604e6611d7683cf7800193526940db90856f358f6fbf3710f88df8f96680` for OpenAPI.


## Context and Orientation

This section describes everything a reader needs to know, assuming no prior exposure to this
repository.

Kansoku is a Haskell analytics service built with GHC 9.12.4 inside a nix flake. Work happens
inside `nix develop` at the repository root; `just build` runs `cabal build all`, `just test`
runs `cabal test`, `just up` starts local PostgreSQL and ClickHouse via process-compose, and
`just run` starts the HTTP server (`cabal run kansoku-server`, listening on port 8080 by
default). There are four cabal packages: `kansoku-api` (servant route types, wire DTOs, the
event model, validation, and the shared prelude — it depends only on servant and friends, no
server machinery), `kansoku-core` (runtime, storage adapters, ingestion, metrics, OpenAPI
generation, HTTP app assembly), `kansoku-server` (the executable), and `kansoku-client` (the
typed Haskell SDK derived from `kansoku-api`). Events posted to `POST /v1/events` or
`POST /v1/batch` are validated, enqueued on a PostgreSQL pgmq queue, and written to the
ClickHouse table `analytics.events_raw` in batches by a background writer.

A few terms used throughout: an event schema is a declaration of what properties an event
name carries (name, JSON type, required or not). The event registry is the in-memory catalog
of all declared schemas. A schema version is an integer identifying one immutable shape of
one event's schema. The contract is the machine-readable JSON rendering of the whole
versioned registry that other services consume. A golden test is a test that compares live
output against a committed reference file, failing when they diverge. A ClickHouse migration
is a numbered SQL file under `db/clickhouse/migrations/` applied in order by `just
ch-migrate`. NamedRoutes is servant's style of declaring an API as a Haskell record — one
field per route — instead of a positional chain; plan 9 converts kansoku to it.

### The registry at implementation start

`kansoku-api/src/Kansoku/Event/Registry.hs` defines the whole artifact this plan versions:

```haskell
data PropertyType = PTString | PTNumber | PTBool | PTObject | PTArray | PTAny

data PropertySpec = PropertySpec
  { propName :: !Text,
    propType :: !PropertyType,
    propRequired :: !Bool,
    propPattern :: !(Maybe PropertyPattern)
  }

data EventSchema = EventSchema
  { schemaEventName :: !EventName,
    schemaProperties :: ![PropertySpec]
  }

newtype EventRegistry = EventRegistry (Map EventName EventSchema)
```

with `emptyRegistry`, `registerSchema :: EventSchema -> EventRegistry -> EventRegistry`,
`lookupSchema :: EventName -> EventRegistry -> Maybe EventSchema`, and `defaultRegistry`
declaring eight events. The original five are `page_view` (required string `url`),
`session_start` (required string `sessionId`), `identify` (no declared properties),
`user_registered` (required string `userId`), and `subscription_started` (required string
`plan`, optional number `amount`). EP-17 added `payment_completed` (required number
`amount`, optional string `plan`) and `feature_used` (required string `feature`). EP-19
added `experiment_viewed` with required string `experiment` and `variant` properties whose
`SqlNamePattern` admits only `[a-z0-9_.:-]{1,128}`. One event name still maps to exactly one
schema — there is no version anywhere.

### Validation today

`kansoku-api/src/Kansoku/Event/Validation.hs` exposes
`validateEventWith :: EventRegistry -> AnalyticsEvent -> Either [ValidationError] AnalyticsEvent`
and `validateEvent = validateEventWith defaultRegistry`. Structural checks reject an empty
event id, an empty event name, and `receivedAt < occurredAt`. Then, if `lookupSchema` finds
the event name, each declared property is checked against the event's `properties` object
(`MissingRequiredProperty`, `WrongPropertyType`, `InvalidPropertyValue`); if the name is
unknown, no schema errors are produced — unknown event names pass. The ingest handler
(`kansoku-core/src/Kansoku/Ingest/Handler.hs`) calls `validateEvent` and turns a `Left` into
HTTP 400 with the shared `ErrorEnvelopeWire`; its message includes the stable human-readable
output of `renderValidationError`.

### The wire type today

`kansoku-api/src/Kansoku/Event/Types.hs` defines `AnalyticsEvent` with 25 fields (ids,
source, timestamps, identity fields, URL/UTM attribution, correlation ids, two open JSON
objects `properties` and `context`, and EP-18's optional `identifiers`). JSON instances are
generically derived with
`omitNothingFields = True` and `rejectUnknownFields = False`, so field names are the wire
keys and optional fields disappear when absent. `kansoku-api/src/Kansoku/Event.hs` re-exports
the event modules and provides `baseEvent :: EventId -> EventName -> EventSource -> UTCTime
-> UTCTime -> AnalyticsEvent`, which fills every optional field with `Nothing`/empty. The
`kansoku-api` package enables `DuplicateRecordFields`, `OverloadedLabels`, and the repo style
is generic-lens `#labels` access (`event ^. #eventName`), which is what keeps duplicate field
names unambiguous.

### Storage today

`kansoku-core/src/Kansoku/ClickHouse/EventRow.hs` defines `EventColumns` (a type-level list
of ClickHouse columns), `EventRow` (the record inserted by the batch writer, one field per
column, derived `ClickHaskell EventColumns`), and `eventRowFromEvent :: AnalyticsEvent ->
EventRow`. The table `analytics.events_raw` is created by
`db/clickhouse/migrations/0001_events_raw.sql`. MP-2 EP-12
(`docs/plans/12-clickhouse-schema-v2-sort-key-final-free-resolution-join-free-rollups.md`)
replaces "apply every file in filename order" with a runner that records applied filenames in
`analytics.schema_migrations` and treats applied migration files as immutable. The landed
ledger runs through EP-19's `0015`, and EP-18 added `identifiers` after `context`. All
ClickHouse DDL goes through numbered files under `db/clickhouse/migrations/` — never through
Haskell code.

### OpenAPI and the client today

`kansoku-api/src/Kansoku/Api/OpenApi.hs` builds the OpenAPI document from the served
`Proxy (NamedRoutes KansokuAPI)`, adds a `kansoku-openapi` executable
(`kansoku-api/app/OpenApi.hs`) that writes the committed `docs/api/openapi.json` with
aeson-pretty (sorted keys, trailing newline), and adds the regeneration check
`cabal run kansoku-openapi && git diff --exit-code docs/api/openapi.json`.
`kansoku-client/src/Kansoku/Client.hs` is a buffering, batching SDK (`newClient`, `track`,
`trackEvent`, `identify`, `group`, `alias`, `flush`) whose HTTP calls are servant-client
functions derived from the shared API type.

### The verified MasterPlan 2 baseline

MasterPlan 2
(`docs/masterplans/2-kansoku-production-hardening-review-fixes-and-portfolio-service-readiness.md`)
is complete. M0 verified that the API is one NamedRoutes
record served by a single servant application (plan 9), with vertical-slice modules
(`Kansoku/Ingest/Api.hs`, `Kansoku/Metrics/Api.hs`, `Kansoku/Api/OpenApi.hs` in
`kansoku-api`); the OpenAPI artifact `docs/api/openapi.json` is committed and regenerated by
`cabal run kansoku-openapi`; ClickHouse migrations are versioned and recorded (EP-12); batch
ingest returns partial acceptance (EP-14, per-event rejections rather than all-or-nothing —
single-event `POST /v1/events` still returns 400 on validation failure); and authentication
exists (EP-15: write keys for ingest, service tokens, read auth for metrics) with `/health`,
`/ready`, and `/openapi.json` public. The API record itself currently contains only the two
authenticated sub-records; the operational routes remain in the intentional WAI wrapper.
The live build, deterministic OpenAPI check, and both package test suites are green as
recorded in Surprises & Discoveries.

### Sibling MasterPlan 3 plans and integration points

MasterPlan 3's Integration Points bind this plan in two places. The event registry: EP-17
(`docs/plans/17-queryable-event-properties-typed-storage-and-property-based-grouping.md`)
reads the registry to know which properties are declared and may add property declarations
to support aggregation; EP-19
(`docs/plans/19-experiment-analytics-assignment-events-variant-rollups-and-per-variant-metrics.md`)
adds the `experiment_viewed` schema. Both have landed: the registry now contains eight
events, and EP-19's two experiment properties carry a `SqlNamePattern`. This plan migrates
all eight entries as version 1 with no semantic change — same properties, types,
requiredness, and patterns. EP-18's optional `identifiers` wire field and column have also
landed; this plan appends the independent optional `schemaVersion` field and storage column.

### Portfolio context

The kikan umbrella repo (`/Users/shinzui/Keikaku/bokuno/kikan`) catalogs kansoku's signals in
`docs/architecture/signals/kansoku.md` — a prose catalog of `AnalyticsEvent`, the acks, the
`events_raw` row, and `MetricResult`, maintained by hand against kansoku's source. The mori
registry knows kansoku as project `shinzui/kansoku` (four packages, currently zero registered
docs). Both are natural consumers of the committed contract artifact this plan produces, and
both are future scope (see Decision Log): nothing in this plan edits the kikan repo or mori
metadata. The source of truth stays in this repository, served at `GET /v1/schemas`.


## Plan of Work

The work is three milestones. Milestone 1 changes the model: the registry becomes versioned,
events can name a version on the wire, validation resolves versions, and the version is
persisted. Milestone 2 publishes the contract: a public JSON endpoint, a committed artifact,
and a golden test binding them together. Milestone 3 writes the governance guide and proves
the whole feature end to end. Each milestone is independently verifiable and committed
separately; client and OpenAPI regeneration ride inside Milestones 1 and 2 with the wire
changes they reflect.


### Milestone 1 — Versioned registry model, `schemaVersion` on the wire, versioned validation, persisted column

Scope: after this milestone, the registry maps each event name to a non-empty, ascending list
of immutable schema versions; an event may declare `"schemaVersion": N` and is validated
against exactly version N of its schema; an unknown version of a known event is a 400 naming
the known versions; a versionless event validates as version 1; unknown event names still
pass; and every accepted event lands in ClickHouse with a `schema_version` column value. The
Haskell SDK can emit a pinned version. Nothing about the existing schemas changes
semantically — all eight landed schemas become version 1 verbatim.

Remodel the registry in `kansoku-api/src/Kansoku/Event/Registry.hs`. `PropertySpec` retains
`propPattern :: !(Maybe PropertyPattern)` and gains `propDescription :: !(Maybe Text)` — a
human-readable sentence for the published contract (the contract JSON exposes it; `Nothing`
renders as JSON `null`). `EventSchema` gains
`schemaVersion :: !Int` and `schemaNote :: !Text` (a one-line changelog note explaining what
this version introduced). `EventRegistry` becomes:

```haskell
newtype EventRegistry = EventRegistry (Map EventName (NonEmpty EventSchema))
```

with the invariant, stated in a comment and enforced by test in Milestone 2, that each list
is sorted ascending by `schemaVersion` and versions are exactly contiguous 1..n. (`NonEmpty`
is re-exported by `Kansoku.Prelude`; `Data.List.NonEmpty` can be imported qualified as
`NonEmpty` for combinators.) Replace `lookupSchema` with explicit helpers and let the
compiler find every call site:

```haskell
registerSchema :: EventSchema -> EventRegistry -> EventRegistry
-- inserts keeping ascending version order; replaces an entry with the same
-- (name, version) so re-registration is idempotent

lookupVersions :: EventName -> EventRegistry -> Maybe (NonEmpty EventSchema)
lookupSchemaVersion :: EventName -> Int -> EventRegistry -> Maybe EventSchema
latestSchema :: EventName -> EventRegistry -> Maybe EventSchema
knownVersions :: EventName -> EventRegistry -> [Int]
```

Rewrite `defaultRegistry` migrating every existing entry as version 1, note
`"Initial schema (kansoku MVP)."`, adding descriptions (these exact strings — the committed
artifact in Milestone 2 depends on them):

```haskell
defaultRegistry :: EventRegistry
defaultRegistry =
  foldr
    registerSchema
    emptyRegistry
    [ EventSchema
        (EventName "page_view")
        1
        "Initial schema (kansoku MVP)."
        [PropertySpec "url" PTString True Nothing (Just "Full URL of the viewed page.")],
      EventSchema
        (EventName "session_start")
        1
        "Initial schema (kansoku MVP)."
        [PropertySpec "sessionId" PTString True Nothing (Just "Client-generated session identifier.")],
      EventSchema
        (EventName "identify")
        1
        "Initial schema (kansoku MVP)."
        [],
      EventSchema
        (EventName "user_registered")
        1
        "Initial schema (kansoku MVP)."
        [PropertySpec "userId" PTString True Nothing (Just "Identifier of the newly registered user.")],
      EventSchema
        (EventName "subscription_started")
        1
        "Initial schema (kansoku MVP)."
        [ PropertySpec "plan" PTString True Nothing (Just "Plan identifier the subscription started on."),
          PropertySpec "amount" PTNumber False Nothing (Just "Monetary amount of the subscription, in the account's currency.")
        ]
    ]
```

The excerpt shows the five original MVP events; the implementation must also migrate the
landed `payment_completed`, `feature_used`, and `experiment_viewed` declarations. Preserve
every existing name, type, requiredness, and pattern — especially `SqlNamePattern` on the
experiment and variant properties — while supplying descriptions and the same version-1
note. The Milestone 2 artifact reflects all eight real registry entries.

Add the wire field in `kansoku-api/src/Kansoku/Event/Types.hs`: insert
`schemaVersion :: !(Maybe Int),` into `AnalyticsEvent` between `sourceGlobalPosition` and
`properties`. Generic derivation makes the JSON key `"schemaVersion"`, and
`omitNothingFields = True` keeps it off the wire when absent. This field name duplicates
`EventSchema.schemaVersion` — that is fine because `kansoku-api` enables
`DuplicateRecordFields` and the codebase accesses fields through generic-lens `#labels`
(`event ^. #schemaVersion`); do not use the bare selector in modules that import both types
(notably `Validation.hs`), or GHC will report an ambiguous occurrence. In
`kansoku-api/src/Kansoku/Event.hs`, `baseEvent` gains `schemaVersion = Nothing` in its record
literal.

Extend validation in `kansoku-api/src/Kansoku/Event/Validation.hs`. Two new error
constructors:

```haskell
data ValidationError
  = EmptyEventId
  | EmptyEventName
  | ReceivedBeforeOccurred UTCTime UTCTime
  | InvalidSchemaVersion Int
  | UnknownSchemaVersion EventName Int [Int]
  | MissingRequiredProperty EventName Text
  | WrongPropertyType EventName Text PropertyType
```

`InvalidSchemaVersion v` is a structural error produced when the event declares a version
outside 1–65535 (this bounds the wire `Int` into the ClickHouse `UInt16` so persistence is
total). `UnknownSchemaVersion name requested known` is produced when the event name is in the
registry but the requested version is not; `known` carries `knownVersions name registry` so
the 400 body names the versions that exist. The schema-error logic becomes: look up the
name's versions; if absent, produce nothing (permissive, unchanged); if present, resolve
`requested = fromMaybe 1 (event ^. #schemaVersion)`, find that exact version, and either
report `UnknownSchemaVersion` or run the existing per-property checks against that version's
`schemaProperties`. Skip the schema lookup entirely when the declared version is structurally
invalid (the `InvalidSchemaVersion` error already tells the caller what is wrong). The
ingest handler needs no change: it already maps `Left` to a 400 whose `details` use
`renderValidationError`.

Persist the version. Add the next unused immutable migration,
`db/clickhouse/migrations/0016_events_raw_schema_version.sql`:

```sql
ALTER TABLE analytics.events_raw
    ADD COLUMN IF NOT EXISTS schema_version UInt16 DEFAULT 1 AFTER identifiers;
```

`ADD COLUMN ... DEFAULT 1` is instant metadata-only DDL in ClickHouse; existing rows read as
1, which is exactly the absence-means-1 wire semantics. Check EP-12's landed migrations
before writing this one: if `events_raw` was rewritten under a different final name or the
materialized views select explicit column lists (they should — EP-12 recreates them), an
appended column with a default does not disturb them; if any view uses `SELECT *`, extend it
explicitly in this migration and note the discovery. Then extend
`kansoku-core/src/Kansoku/ClickHouse/EventRow.hs`: append `Column "schema_version" UInt16` at
the end of `EventColumns`, append `schema_version :: !Word16` at the end of `EventRow`
(import `UInt16` from `ClickHaskell` — it is a synonym for `Word16` — and `Word16` from
`Data.Word`), and in `eventRowFromEvent` set

```haskell
schema_version = boundedSchemaVersion (event ^. #schemaVersion)
```

with a private helper `boundedSchemaVersion :: Maybe Int -> Word16` mapping `Nothing` to 1
and clamping into 1–65535 (validation already rejects out-of-range values; the clamp keeps
the writer total even for events that bypassed validation, e.g. queue replays from before the
bound existed).

Update the SDK in `kansoku-client/src/Kansoku/Client.hs`: add and export

```haskell
trackEventWithVersion :: Client -> EventIds -> Text -> Int -> [Pair] -> IO ()
trackEventWithVersion clientHandle ids name version pairs = do
  event <- buildEvent (clientHandle ^. #config) ids name pairs
  track clientHandle (event & #schemaVersion ?~ version)
```

`trackEvent` and the other helpers stay versionless (their events validate as version 1). A
caller who builds an `AnalyticsEvent` by hand can also set `#schemaVersion` directly and use
`track`. Regenerate the OpenAPI artifact in this same commit: the `AnalyticsEvent` component
schema gains the `schemaVersion` property (add a field description via the ToSchema/OpenAPI
layer if the post-plan-9 module supports per-field docs; otherwise the generically derived
optional integer property suffices). Run `cabal run kansoku-openapi` and commit the changed
`docs/api/openapi.json` (if the pre-plan-9 tree is somehow still current, the document is
served-only from `kansoku-core/src/Kansoku/OpenApi.hs` and there is no artifact to
regenerate — record that in Surprises & Discoveries).

Add tests to `kansoku-core/test/Kansoku/EventSpec.hs` (hspec; the suite is registered in
`kansoku-core/test/Spec.hs`): a versionless `subscription_started` event with valid
properties validates `Right`; the same event with `"schemaVersion": 1` validates `Right`;
with `"schemaVersion": 2` validates `Left [UnknownSchemaVersion (EventName
"subscription_started") 2 [1]]`; with `"schemaVersion": 0` produces `InvalidSchemaVersion 0`;
an unknown event name with `"schemaVersion": 7` validates `Right`; JSON encoding of a
`baseEvent` omits the `"schemaVersion"` key and decoding a payload carrying it round-trips;
and `eventRowFromEvent` maps `Nothing` to `schema_version = 1` and `Just 3` to `3`.

Acceptance: `cabal test` is green; `just ch-migrate` applies the new migration (idempotent on
re-run); with the stack running, the three ingest transcripts in Validation and Acceptance
behave as shown (400 naming known versions, 202 for versionless, 202 for a valid pinned
version) and the ClickHouse query shows `schema_version` populated. Commit as Milestone 1.


### Milestone 2 — `GET /v1/schemas`, the committed contract artifact, and the golden test

Scope: after this milestone, the full versioned registry is served as JSON at
`GET /v1/schemas` (public, `application/json`), the same document is committed at
`docs/contracts/events.json`, a golden test fails `cabal test` whenever the registry and the
committed artifact disagree, and `cabal run kansoku-contracts` regenerates the artifact. The
endpoint appears in the OpenAPI document, and the Haskell SDK can fetch the catalog.

Design of the contract document. The document is deterministic (no timestamps), self-labeled,
and shaped for lookup by event name. Top level: `catalogVersion` (an integer versioning the
shape of this document itself, starting at 1 — bump it if this plan's successors change the
document structure, not when event schemas change), `service` (always `"kansoku"`), and
`events`, an object keyed by event name. Each event value has one key, `versions`, an array
ordered ascending by version. Each version has `version` (int), `note` (string, the
changelog line), and `properties`, an array of `{name, type, required, pattern, description}` where
`type` is one of `"string"`, `"number"`, `"bool"`, `"object"`, `"array"`, `"any"` (the
lowercase rendering of `PropertyType`), `pattern` is the validation expression or `null`,
and `description` is a string or `null`. Excerpt of
the version-1 catalog (two of the five events; key order shown alphabetically as the
regenerator writes it, but consumers and the golden test must not depend on key order):

```json
{
  "catalogVersion": 1,
  "events": {
    "page_view": {
      "versions": [
        {
          "note": "Initial schema (kansoku MVP).",
          "properties": [
            {
              "description": "Full URL of the viewed page.",
              "name": "url",
              "pattern": null,
              "required": true,
              "type": "string"
            }
          ],
          "version": 1
        }
      ]
    },
    "subscription_started": {
      "versions": [
        {
          "note": "Initial schema (kansoku MVP).",
          "properties": [
            {
              "description": "Plan identifier the subscription started on.",
              "name": "plan",
              "pattern": null,
              "required": true,
              "type": "string"
            },
            {
              "description": "Monetary amount of the subscription, in the account's currency.",
              "name": "amount",
              "pattern": null,
              "required": false,
              "type": "number"
            }
          ],
          "version": 1
        }
      ]
    }
  },
  "service": "kansoku"
}
```

(One caution about the excerpt: `properties` is an array and its order is the declaration
order in the registry, which the regenerator preserves. Declare properties in whatever order
reads best; the golden test compares values, and arrays compare in order, so the committed
artifact always matches declaration order.)

Create `kansoku-api/src/Kansoku/Event/Contract.hs` (add it to `exposed-modules` in
`kansoku-api/kansoku-api.cabal`) with the DTOs and the pure derivation:

```haskell
data ContractProperty = ContractProperty
  { name :: !Text,
    propertyType :: !Text,
    required :: !Bool,
    validationPattern :: !(Maybe Text),
    description :: !(Maybe Text)
  }

data VersionedEventSchema = VersionedEventSchema
  { version :: !Int,
    note :: !Text,
    properties :: ![ContractProperty]
  }

newtype EventVersions = EventVersions
  { versions :: NonEmpty VersionedEventSchema
  }

data SchemaCatalog = SchemaCatalog
  { catalogVersion :: !Int,
    service :: !Text,
    events :: !(Map Text EventVersions)
  }

propertyTypeText :: PropertyType -> Text
schemaCatalog :: EventRegistry -> SchemaCatalog
```

All four types derive `Generic, Eq, Show` (strict fields, per the repo's code standards).
`VersionedEventSchema`, `EventVersions`, and `SchemaCatalog` take generic `ToJSON`/`FromJSON`
(field names are already the wire keys; `Map Text` renders as a JSON object;
aeson provides `NonEmpty` instances). `ContractProperty` needs hand-written instances (or
generic ones with a `fieldLabelModifier`) because its wire key `"type"` is a Haskell keyword:
encode as the five keys `name`/`type`/`required`/`pattern`/`description`, always emitting
both nullable fields so consumers see a fixed shape, and decode tolerating either when
missing. `propertyTypeText` maps `PTString -> "string"` and so on;
`schemaCatalog` sets `catalogVersion = 1`, `service = "kansoku"`, and folds the registry into
the map (`Map EventName (NonEmpty EventSchema)` to `Map Text EventVersions`, unwrapping
`EventName` and converting each `EventSchema` — the lists are already version-ascending by
registry invariant). Both `ToJSON` and `FromJSON` exist so the SDK can decode what the server
encodes and the golden test can round-trip.

Serve it. In the post-plan-9 NamedRoutes record (the root API record in `kansoku-api` — plan
9's Milestone 2 names it; verify the actual record name in the tree), add a field:

```haskell
schemas :: mode :- "v1" :> "schemas" :> Get '[JSON] SchemaCatalog
```

and in the corresponding server record in `kansoku-core`, the handler is pure:

```haskell
getSchemas = pure (schemaCatalog defaultRegistry)
```

servant's `JSON` content type gives `content-type: application/json` on the response. The
route carries no authentication combinator — EP-15's scheme attaches auth per route family,
and this route joins `/health`, `/ready`, and `/openapi.json` in the public set (Decision
Log). If, contrary to the baseline assumption, the tree still runs the pre-plan-9 WAI router
in `kansoku-core/src/Kansoku/Server.hs`, serve the same document the way `openapi.json` is
served there today (a `pathInfo` case for `["v1", "schemas"]` responding with
`Aeson.encode (schemaCatalog defaultRegistry)`) and record the deviation — but prefer landing
plan 9 first. Add `ToSchema` instances for the four DTOs in the OpenAPI module
(post-plan-9 `kansoku-api/src/Kansoku/Api/OpenApi.hs`; currently
`kansoku-core/src/Kansoku/OpenApi.hs`) so the endpoint documents itself, and mention the
committed artifact path in the operation or info description. Regenerate `docs/api/openapi.json`
(`cabal run kansoku-openapi`) in this same commit; the SDK addition below also rides here.

Commit the artifact and its regenerator. Add an executable `kansoku-contracts`
(`kansoku-api/app/Contracts.hs`, mirroring plan 9's `kansoku-openapi`; add the executable
stanza to `kansoku-api/kansoku-api.cabal` with `aeson-pretty` in its `build-depends`) that
writes `docs/contracts/events.json`: `encodePretty'` with `confCompare = compare` (sorted
object keys), four-space or two-space indent (match whatever `kansoku-openapi` uses), and a
trailing newline, serializing `schemaCatalog defaultRegistry`. It writes relative to the
working directory, so it is run from the repository root. Create `docs/contracts/` and commit
the generated file. Add a justfile recipe:

```text
# Regenerate the committed event contract artifact from the registry.
contracts:
    cabal run kansoku-contracts
```

Add the golden test `kansoku-core/test/Kansoku/ContractSpec.hs` (register it in
`kansoku-core/test/Spec.hs` and the test-suite `other-modules` in
`kansoku-core/kansoku-core.cabal`). It has three groups. The golden comparison: read
`../docs/contracts/events.json` (cabal runs the test suite with the package directory
`kansoku-core/` as the working directory; if that assumption fails in this environment,
locate the repo root by walking up from the current directory to the first directory
containing `docs/contracts/` and note the discovery), decode it to an `Aeson.Value`, and
assert it equals `Aeson.toJSON (schemaCatalog defaultRegistry)` — with a failure annotation
telling the reader exactly what to do:

```haskell
it "matches the committed contract artifact" $ do
  committed <- either fail pure =<< Aeson.eitherDecodeFileStrict' "../docs/contracts/events.json"
  (committed :: Aeson.Value)
    `shouldBe` Aeson.toJSON (schemaCatalog defaultRegistry)
```

preceded by a comment (and, ideally, hspec's `expectationFailure` wrapping with the message)
"docs/contracts/events.json is stale — run `cabal run kansoku-contracts` from the repo root
and commit the result." Because both sides are `Aeson.Value`, formatting and key order are
irrelevant; any semantic registry change fails the test until the artifact is regenerated —
this is the CI drift guard. The invariants group asserts, for every entry in
`defaultRegistry`: versions are exactly `[1..n]` ascending (contiguous, starting at 1, no
duplicates), every `schemaEventName` matches its map key, every `schemaNote` is non-empty,
and property names are unique within each version. The round-trip group asserts
`Aeson.decode (Aeson.encode catalog) == Just catalog` for `catalog = schemaCatalog
defaultRegistry`, proving the SDK-facing `FromJSON` inverts the served `ToJSON`.

Extend the SDK in `kansoku-client/src/Kansoku/Client.hs`: derive the schemas call from the
shared route (post-plan-9, servant-client generation from the NamedRoutes record; the exact
mechanics follow however the tree derives `postBatch` at implementation time) and export

```haskell
fetchSchemaCatalog :: Client -> IO (Either ClientError SchemaCatalog)
```

running the derived `ClientM SchemaCatalog` against the client's `ClientEnv` and wrapping the
servant error in the SDK's `ClientError` type (extend `ClientError` with a constructor if its
current single `DeliveryFailed` shape does not fit; keep it additive).

Acceptance: `cabal test` is green, including the new `ContractSpec`; `curl -s
localhost:8080/v1/schemas | jq .` prints the catalog and `diff <(curl -s
localhost:8080/v1/schemas | jq -S .) <(jq -S . docs/contracts/events.json)` is empty; the
drift demonstration in Validation and Acceptance behaves as shown (registry edit fails the
test with the regeneration hint; `just contracts` then makes it pass); `GET /openapi.json`
(and the committed `docs/api/openapi.json`) contains the `/v1/schemas` path and the
`SchemaCatalog` component schema. Commit as Milestone 2.


### Milestone 3 — Governance guide, portfolio hook, full validation pass

Scope: after this milestone, a service author anywhere in the kikan portfolio can read one
document and know how to declare, evolve, and pin an event schema; and this plan's living
sections plus MasterPlan 3's registry rows record the completed state.

Author `docs/event-schema-governance.md`. It is written for a kikan service author who has
never seen kansoku's internals, so it opens by saying what the contract is and where to get
it (both `GET /v1/schemas` on a running kansoku and the committed
`docs/contracts/events.json` in this repo), then covers, in order: how to declare a new event
schema — open a PR against this repository editing `defaultRegistry` in
`kansoku-api/src/Kansoku/Event/Registry.hs`, adding an `EventSchema` with `schemaVersion = 1`,
a changelog note, and described properties, then run `just contracts` and commit the
regenerated `docs/contracts/events.json` (the test suite fails the PR otherwise); when to
bump a version — any change to a released schema whatsoever (new property, even optional;
type change; requiredness change) is a new `EventSchema` entry with the next contiguous
version and a note saying what changed, and released versions are never edited (reviewers
reject in-place edits, and the artifact diff makes them obvious); how producers pin — emit
`"schemaVersion": N` on the wire (the Haskell SDK's `trackEventWithVersion`, or set the field
in whatever client you use), omit it and you are asserting version 1, and consume
`GET /v1/schemas` (or `fetchSchemaCatalog` from `kansoku-client`) if you want to check the
contract at startup or in CI; and the compatibility policy — versions are immutable, absent
means 1, unknown event names are accepted without schema checks (declare a schema when you
want kansoku to start enforcing shape for your event), unknown versions of known events are
rejected with HTTP 400 naming the known versions, and the persisted `schema_version` column
lets analysts segment by schema era (include the example query from Validation and
Acceptance). Keep it under roughly two pages; link to this plan for design rationale.

Record the portfolio hook without implementing it: confirm the Decision Log entry (kikan's
`docs/architecture/signals/kansoku.md` and mori doc registration for `shinzui/kansoku` can
point at `docs/contracts/events.json` and `GET /v1/schemas`; that wiring belongs to the kikan
and mori sides) and, if anything about the hook changed during implementation, update the
entry.

Run the full validation pass in Validation and Acceptance from a clean checkout state:
migrations, tests, all transcripts. Paste the actual captured transcripts into this plan
(replacing or confirming the expected ones), tick off Progress, update MasterPlan 3's
Exec-Plan Registry row for EP-20 to Complete and its two EP-20 Progress checkboxes, add the
naming-coordination note to MasterPlan 3's Integration Points if EP-18 has not yet merged,
and write the Outcomes & Retrospective entry. Commit as Milestone 3.


## Concrete Steps

All commands run at the repository root
(`/Users/shinzui/Keikaku/bokuno/kansoku-project/kansoku`) inside `nix develop` unless stated
otherwise.

Orient first (M0):

```bash
git log --oneline -15                      # confirm MP-2 work has landed
ls db/clickhouse/migrations/               # find the next unused migration number
ls kansoku-api/src/Kansoku kansoku-api/src/Kansoku/Api kansoku-api/app 2>/dev/null
grep -rn "NamedRoutes" kansoku-api/src | head   # confirm the plan-9 record exists
ls docs/api/ 2>/dev/null                   # committed openapi.json present?
just build && just test                    # green baseline before touching anything
```

Milestone 1 edits, in dependency order: `kansoku-api/src/Kansoku/Event/Registry.hs`
(model + `defaultRegistry`), `kansoku-api/src/Kansoku/Event/Types.hs` (`schemaVersion`
field), `kansoku-api/src/Kansoku/Event.hs` (`baseEvent`),
`kansoku-api/src/Kansoku/Event/Validation.hs` (version resolution + new errors), then
`cabal build kansoku-api` and fix every call site the compiler reports (the removed
`lookupSchemaVersion` and the extended constructors will surface them all, including every EP-17/EP-19
code). Then `kansoku-core/src/Kansoku/ClickHouse/EventRow.hs`, the new migration file,
`kansoku-client/src/Kansoku/Client.hs`, tests in `kansoku-core/test/Kansoku/EventSpec.hs`.

```bash
just build
just test
just up                                    # separate terminal; postgres + clickhouse
just ch-migrate                            # applies 0016_events_raw_schema_version.sql
just run                                   # separate terminal; server on :8080
# then run the three ingest transcripts from Validation and Acceptance
cabal run kansoku-openapi                  # regenerate docs/api/openapi.json (post-plan-9)
```

Commit Milestone 1 (conventional commit, trailers mandatory):

```text
feat(events): version the event schema registry and carry schemaVersion on the wire

Registry maps each event name to a NonEmpty list of immutable versioned
schemas; events may declare an optional schemaVersion (absent = 1);
validation checks the named version and rejects unknown versions of known
events; the version persists to events_raw as schema_version UInt16.
kansoku-client and the OpenAPI document move in the same commit.

MasterPlan: docs/masterplans/3-kansoku-analytics-extensions-queryable-properties-multi-signal-identity-and-experiment-analytics.md
ExecPlan: docs/plans/20-event-schema-governance-versioned-registry-and-portfolio-event-contracts.md
```

Milestone 2 edits: `kansoku-api/src/Kansoku/Event/Contract.hs` (new),
`kansoku-api/kansoku-api.cabal` (exposed module + `kansoku-contracts` executable +
`aeson-pretty`), the NamedRoutes record and its server record (`schemas` route + handler),
the OpenAPI module (`ToSchema` instances), `kansoku-api/app/Contracts.hs` (new), `justfile`
(`contracts` recipe), `kansoku-core/test/Kansoku/ContractSpec.hs` (new, registered in
`Spec.hs` and the cabal test-suite), `kansoku-client/src/Kansoku/Client.hs`
(`fetchSchemaCatalog`).

```bash
mkdir -p docs/contracts
cabal run kansoku-contracts                # writes docs/contracts/events.json
just test                                  # ContractSpec now passes against the artifact
cabal run kansoku-openapi
curl -s localhost:8080/v1/schemas | jq .   # with the stack running
diff <(curl -s localhost:8080/v1/schemas | jq -S .) <(jq -S . docs/contracts/events.json)
```

Commit Milestone 2:

```text
feat(api): serve the versioned event contract at GET /v1/schemas

Public JSON catalog derived from the registry (SchemaCatalog), committed as
docs/contracts/events.json, regenerated by `cabal run kansoku-contracts`,
and guarded by a golden test that fails on any registry/artifact drift.
kansoku-client gains fetchSchemaCatalog; OpenAPI regenerated in the same
commit.

MasterPlan: docs/masterplans/3-kansoku-analytics-extensions-queryable-properties-multi-signal-identity-and-experiment-analytics.md
ExecPlan: docs/plans/20-event-schema-governance-versioned-registry-and-portfolio-event-contracts.md
```

Milestone 3: write `docs/event-schema-governance.md`, run the full Validation and Acceptance
pass, update this plan's living sections and MasterPlan 3's registry/progress. Commit:

```text
docs(governance): author the event schema governance guide for kikan producers

How a kikan service declares an event schema (PR to the kansoku registry),
when versions bump (every change), how producers pin (schemaVersion +
GET /v1/schemas), and the compatibility policy. Marks EP-20 complete.

MasterPlan: docs/masterplans/3-kansoku-analytics-extensions-queryable-properties-multi-signal-identity-and-experiment-analytics.md
ExecPlan: docs/plans/20-event-schema-governance-versioned-registry-and-portfolio-event-contracts.md
```


## Validation and Acceptance

Prerequisites for the live transcripts: `just up` running (postgres, clickhouse,
create_schema healthy), `just ch-migrate` applied, `just run` serving on port 8080. If EP-15
has landed, ingest requests need a write key — attach it the way EP-15's plan documents
(header on the curl calls); `GET /v1/schemas` needs nothing.

Contract endpoint. Expect HTTP 200, `content-type: application/json`, and the catalog:

```console
$ curl -s localhost:8080/v1/schemas | jq '{catalogVersion, service, page_view: .events.page_view}'
{
  "catalogVersion": 1,
  "service": "kansoku",
  "page_view": {
    "versions": [
      {
        "version": 1,
        "note": "Initial schema (kansoku MVP).",
        "properties": [
          {
            "name": "url",
            "type": "string",
            "required": true,
            "description": "Full URL of the viewed page."
          }
        ]
      }
    ]
  }
}
```

Unknown version of a known event is rejected, naming the known versions. Expect HTTP 400:

```console
$ curl -s -w '\nHTTP %{http_code}\n' -X POST localhost:8080/v1/events \
    -H 'content-type: application/json' -d '{
  "eventId": "11111111-1111-1111-1111-111111111111",
  "eventName": "page_view",
  "source": "web",
  "occurredAt": "2026-07-15T12:00:00Z",
  "receivedAt": "2026-07-15T12:00:00Z",
  "schemaVersion": 2,
  "properties": {"url": "https://example.test/pricing"},
  "context": {}
}'
{"code":"validation_failed","message":"validation failed: event 'page_view': schemaVersion 2 is unknown; known versions: [1]","retryable":false}
HTTP 400
```

(The message comes from `renderValidationError`. The load-bearing assertions are status 400,
the event name, requested version 2, and known-version list `[1]`.)

Versionless ingest is accepted as version 1, and a valid pinned version is accepted. Expect
HTTP 202 for both:

```console
$ curl -s -w '\nHTTP %{http_code}\n' -X POST localhost:8080/v1/events \
    -H 'content-type: application/json' -d '{
  "eventId": "22222222-2222-2222-2222-222222222222",
  "eventName": "page_view",
  "source": "web",
  "occurredAt": "2026-07-15T12:00:00Z",
  "receivedAt": "2026-07-15T12:00:00Z",
  "properties": {"url": "https://example.test/"},
  "context": {}
}'
{"accepted":1,"eventId":"22222222-2222-2222-2222-222222222222"}
HTTP 202
```

Repeat with `"eventId": "33333333-3333-3333-3333-333333333333"` and `"schemaVersion": 1`
added — also 202. An unknown event name with any declared version is also accepted
(permissive policy): posting `"eventName": "totally_new_thing", "schemaVersion": 7` returns
202.

Persistence — after the writer's next flush (a few seconds), the version column segments the
rows:

```console
$ clickhouse-client --port $CLICKHOUSE_TCP_PORT --query \
    "SELECT event_name, schema_version, count() FROM analytics.events_raw \
     WHERE event_id LIKE '2222%' OR event_id LIKE '3333%' \
     GROUP BY event_name, schema_version ORDER BY schema_version FORMAT PrettyCompact"
┌─event_name─┬─schema_version─┬─count()─┐
│ page_view  │              1 │       2 │
└────────────┴────────────────┴─────────┘
```

(Both the versionless and the pinned-v1 event report `schema_version = 1`.)

Golden-test drift guard, demonstrated. Make an illegal in-place edit — add
`PropertySpec "title" PTString False Nothing (Just "Page title.")` to the released `page_view`
version 1 in `kansoku-api/src/Kansoku/Event/Registry.hs` — then:

```console
$ cabal test kansoku-core-test 2>&1 | grep -A4 "committed contract"
  matches the committed contract artifact FAILED [1]
  ...
  docs/contracts/events.json is stale - run `cabal run kansoku-contracts`
  from the repo root and commit the result.
```

Regenerate and the suite passes again (`cabal run kansoku-contracts && cabal test`) — and
`git diff docs/contracts/events.json` now shows the reviewer-visible contract change,
which is precisely what a reviewer would reject as an in-place edit to a released version.
Restore the tree afterwards:

```bash
git checkout -- kansoku-api/src/Kansoku/Event/Registry.hs docs/contracts/events.json
```

Full-suite and regeneration checks, all green / empty:

```bash
just build
just test
cabal run kansoku-openapi   && git diff --exit-code docs/api/openapi.json
cabal run kansoku-contracts && git diff --exit-code docs/contracts/events.json
```

Acceptance summary: all transcripts above behave as shown; `docs/event-schema-governance.md`
exists and covers declaration, bumping, pinning, and compatibility; `docs/api/openapi.json`
contains the `/v1/schemas` path and the `schemaVersion` property on `AnalyticsEvent`;
`kansoku-client` exposes `trackEventWithVersion` and `fetchSchemaCatalog`; MasterPlan 3 marks
EP-20 complete.


## Idempotence and Recovery

Every step is safe to repeat. The ClickHouse migration uses `ADD COLUMN IF NOT EXISTS` and
the EP-12 runner skips recorded files, so `just ch-migrate` re-runs are no-ops; the column
addition is metadata-only and needs no data rewrite. `cabal run kansoku-contracts` and
`cabal run kansoku-openapi` overwrite their artifacts deterministically — re-running them
produces byte-identical output for an unchanged registry/API. `registerSchema` replaces on
duplicate `(name, version)`, so registry construction is idempotent. The ingest transcripts
use fixed event ids; re-posting them is deduplicated by the ReplacingMergeTree identity, and
the count query above is written to tolerate replays.

Recovery paths: each milestone is one commit, so `git revert <sha>` restores the previous
contract cleanly — reverting Milestone 1 also reverts the client and OpenAPI in the same
step, which is the point of the same-commit discipline. The `schema_version` column can be
left in place after a revert (it is additive and defaulted; a follow-up migration `ALTER
TABLE analytics.events_raw DROP COLUMN schema_version` is possible but destructive — do not
run it against a database whose rows you care about, and never edit the applied 0016 file).
If the golden test fails unexpectedly mid-work, the fix is always one of two commands: change
the registry back, or `cabal run kansoku-contracts` and commit — the failure message says so.
If `cabal test` cannot find `../docs/contracts/events.json`, the working-directory assumption
broke; fix the path resolution in `ContractSpec` (walk up to the directory containing
`docs/contracts/`) and record the discovery.


## Interfaces and Dependencies

No new external services and no new Haskell dependencies beyond `aeson-pretty`, added to the
`kansoku-contracts` executable stanza only (plan 9 already introduces it for
`kansoku-openapi`; it is on Hackage and in nixpkgs). Everything else uses libraries already
in the build: `aeson`, `containers`, `generic-lens`, `servant`/`servant-client`,
`ClickHaskell`, `hspec`. Code follows the repo standards
(`/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/core/`): GHC2024, `Kansoku.Prelude`
imported everywhere, postpositive qualified imports (`import Data.Map.Strict qualified as
Map`), generic-lens `#labels` access, strict fields, explicit `deriving stock` /
`deriving anyclass`.

At the end of Milestone 1, these exist with these signatures:

```haskell
-- kansoku-api/src/Kansoku/Event/Registry.hs
data PropertyType = PTString | PTNumber | PTBool | PTObject | PTArray | PTAny
data PropertySpec = PropertySpec
  { propName :: !Text, propType :: !PropertyType,
    propRequired :: !Bool, propPattern :: !(Maybe PropertyPattern),
    propDescription :: !(Maybe Text) }
data EventSchema = EventSchema
  { schemaEventName :: !EventName, schemaVersion :: !Int,
    schemaNote :: !Text, schemaProperties :: ![PropertySpec] }
newtype EventRegistry = EventRegistry (Map EventName (NonEmpty EventSchema))
emptyRegistry :: EventRegistry
defaultRegistry :: EventRegistry
registerSchema :: EventSchema -> EventRegistry -> EventRegistry
lookupVersions :: EventName -> EventRegistry -> Maybe (NonEmpty EventSchema)
lookupSchemaVersion :: EventName -> Int -> EventRegistry -> Maybe EventSchema
latestSchema :: EventName -> EventRegistry -> Maybe EventSchema
knownVersions :: EventName -> EventRegistry -> [Int]

-- kansoku-api/src/Kansoku/Event/Types.hs (AnalyticsEvent gains)
schemaVersion :: !(Maybe Int)   -- JSON key "schemaVersion"; absent = 1

-- kansoku-api/src/Kansoku/Event/Validation.hs
data ValidationError
  = EmptyEventId | EmptyEventName | ReceivedBeforeOccurred UTCTime UTCTime
  | InvalidSchemaVersion Int
  | UnknownSchemaVersion EventName Int [Int]
  | MissingRequiredProperty EventName Text
  | WrongPropertyType EventName Text PropertyType
validateEventWith :: EventRegistry -> AnalyticsEvent -> Either [ValidationError] AnalyticsEvent
validateEvent :: AnalyticsEvent -> Either [ValidationError] AnalyticsEvent

-- kansoku-core/src/Kansoku/ClickHouse/EventRow.hs (appended)
--   EventColumns gains: Column "schema_version" UInt16
--   EventRow gains:     schema_version :: !Word16

-- kansoku-client/src/Kansoku/Client.hs
trackEventWithVersion :: Client -> EventIds -> Text -> Int -> [Pair] -> IO ()
```

At the end of Milestone 2, additionally:

```haskell
-- kansoku-api/src/Kansoku/Event/Contract.hs
data ContractProperty = ContractProperty
  { name :: !Text, propertyType :: !Text,
    required :: !Bool, validationPattern :: !(Maybe Text),
    description :: !(Maybe Text) } -- wire keys: propertyType -> "type", validationPattern -> "pattern"
data VersionedEventSchema = VersionedEventSchema
  { version :: !Int, note :: !Text, properties :: ![ContractProperty] }
newtype EventVersions = EventVersions { versions :: NonEmpty VersionedEventSchema }
data SchemaCatalog = SchemaCatalog
  { catalogVersion :: !Int, service :: !Text, events :: !(Map Text EventVersions) }
propertyTypeText :: PropertyType -> Text
schemaCatalog :: EventRegistry -> SchemaCatalog

-- route field on the root NamedRoutes record (kansoku-api)
schemas :: mode :- "v1" :> "schemas" :> Get '[JSON] SchemaCatalog

-- kansoku-client/src/Kansoku/Client.hs
fetchSchemaCatalog :: Client -> IO (Either ClientError SchemaCatalog)
```

plus the executable `kansoku-contracts` (`kansoku-api/app/Contracts.hs`) writing
`docs/contracts/events.json`, and the test module `kansoku-core/test/Kansoku/ContractSpec.hs`.
At the end of Milestone 3, `docs/event-schema-governance.md` exists.

---

Revision note (2026-07-15): Fleshed out from the skeleton into a complete ExecPlan under
MasterPlan 3. Scope fixed as versioning + publication + process (no standalone registry
service); design decisions seeded in the Decision Log (in-source registry, immutable
versions, absence-means-1, public `/v1/schemas`, golden-artifact drift guard); client/OpenAPI
work folded into Milestones 1–2 to honor MasterPlan 2's same-commit wire-change discipline.

Revision note (2026-07-19): Reconciled the plan with the completed EP-17, EP-18, and EP-19
tree before implementation. The registry now has eight declarations and property patterns,
the wire/storage model already includes identifiers, the immutable migration ledger reaches
0015, validation renders stable messages, and the public catalog joins the root NamedRoutes
record without moving the WAI-level operational endpoints.
