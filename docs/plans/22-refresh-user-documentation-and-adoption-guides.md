---
id: 22
slug: refresh-user-documentation-and-adoption-guides
title: "Refresh user documentation and adoption guides"
kind: exec-plan
created_at: 2026-07-20T14:21:18Z
---

# Refresh user documentation and adoption guides

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Kansoku has a generated API contract and extensive implementation plans, but a developer
cannot currently follow one supported path from a fresh checkout to a running service, an
authenticated event, and a metric result. The root README also describes an older product:
it treats authentication, experiments, schema versions, multi-signal identity, and pipeline
telemetry as absent or future work.

After this change, `docs/README.md` is the stable user-documentation entry point and the
guides under `docs/guides/` take an adopter through local startup, event production, metrics
queries, the Haskell SDK, configuration, and operations. A developer can validate the path
by starting PostgreSQL and ClickHouse, applying both migration systems, issuing credentials,
posting a schema-valid event, and querying an account-scoped metric. The generated OpenAPI
and event-contract artifacts remain the exact machine-readable references.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] (2026-07-20 14:21Z) Audited the repository, existing user-facing documents, generated
  contracts, route types, handlers, configuration, migrations, Haskell client, relevant ADRs,
  and current dependency documentation located through Mori.
- [x] (2026-07-20 14:21Z) Created this ExecPlan and recorded the documentation structure,
  corrections, validation criteria, and implementation decisions.
- [x] (2026-07-20 14:32Z) Milestone 1: added the user-documentation index and six end-to-end
  guides covering local startup, HTTP ingestion, metrics, the Haskell SDK, configuration, and
  operations.
- [x] (2026-07-20 14:32Z) Milestone 2: corrected the stale root README and product-vision status,
  and repaired the checked-in Haskell example so it emits the required `userId` property.
- [x] (2026-07-20 14:44Z) Milestone 3: validated generated artifacts, formatting, 62 local
  Markdown links, seven JSON examples, the SDK example build, the fresh migration path, the live
  HTTP adoption flow, 133 core examples, and 13 client examples including the live integration.
- [x] (2026-07-20 14:44Z) Completed the ADR distillation pass; this documentation structure and
  the discovered legacy-ledger warning do not change Kansoku's durable architecture, so no ADR
  was added or revised.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The root README says experiment analytics is later scope, but the current API implements
  exposure, per-variant conversion, and per-variant funnel endpoints. Evidence: the generated
  `docs/api/openapi.json` contains `/metrics/experiments`,
  `/metrics/experiments/conversion`, and `/metrics/experiments/funnel`, and
  `kansoku-core/src/Kansoku/Metrics/Handler.hs` binds all three to live handlers.
- The current `kansoku-client/example/Main.hs` sends a `user_registered` event with a `plan`
  property, while version 1 of that published event requires the `userId` property. Evidence:
  `docs/contracts/events.json` declares `userId` as required, so the example is rejected by
  current server validation.
- PostgreSQL no longer needs the upstream PGMQ extension. Kansoku's explicit `kansoku-migrate`
  plan installs the vendored PGMQ schema through `pgmq-migration`, then installs the
  application-owned `kansoku.api_keys` table. Normal server startup only provisions the queue.
- The migration CLI exposes more read-only inspection commands than the older user prose named.
  Evidence: `kansoku-migrate --help` lists `plan`, `status`, `verify`, `list`, and `check`, while
  mutating commands are separated under Execution and Authoring.
- The identity-retention runbook's ClickHouse version statement is still current. Evidence:
  `nix develop -c clickhouse-client --version` reports `26.5.1.882`.
- The checkout's existing local `kansoku` database contains a PGMQ schema that predates the
  current pg-migrate history. Evidence: `just migrate` refused to replay the baseline with
  PostgreSQL error `42710 type "message_record" already exists`. The database was preserved;
  a separate temporary database applied all three migrations, and its second `up` reported every
  migration `already_applied`.
- The guide's accepted-event-to-query delay cannot be asserted only from configuration; it must
  be observed with the running writer. Evidence: the end-to-end test received HTTP 202, then
  `/metrics/events` returned the dated point for the authenticated test account while `/ready`
  reported all four checks healthy.


## Decision Log

Record every decision made while working on the plan.

- Decision: Make `docs/README.md` the boundary between adopter documentation and repository
  history, and place task-oriented pages in `docs/guides/`.
  Rationale: `docs/plans/`, `docs/masterplans/`, and `docs/adr/` are valuable project records,
  but they are not a safe sequential onboarding path and historical statements in completed
  plans should not be rewritten as current user documentation.
  Date: 2026-07-20
- Decision: Cover six adoption tasks: local startup, raw HTTP ingestion, metric queries,
  Haskell SDK use, configuration, and operations.
  Rationale: Together these explain the complete supported deployment and integration surface
  without inventing unavailable browser or React SDKs.
  Date: 2026-07-20
- Decision: Treat `docs/api/openapi.json`, `docs/contracts/events.json`, and the corresponding
  Haskell route/registry sources as authoritative; make prose link to them rather than copy every
  field or endpoint schema.
  Rationale: Generated references have golden/check commands and therefore provide a stronger
  drift boundary than manually duplicated tables.
  Date: 2026-07-20
- Decision: Keep `docs/initial-spec.md` as a vision document but add a prominent status boundary
  and replace its obsolete TypeScript event sketch and component/MVP claims with links to the
  implemented contract and current documentation.
  Rationale: The product thesis remains useful, while unmarked aspirational API text currently
  looks like supported behavior.
  Date: 2026-07-20
- Decision: Update the checked-in Haskell example alongside the guide.
  Rationale: An adoption guide must not point to an executable example that the current schema
  rejects.
  Date: 2026-07-20
- Decision: Document current PostgreSQL migration commands as a fresh/current-ledger path and add
  an explicit legacy-installation warning.
  Rationale: pg-migrate correctly refuses to infer old PGMQ history. Calling `up` idempotent
  without that qualification would encourage operators to replay or drop a database whose
  provenance has not been verified.
  Date: 2026-07-20


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

Kansoku now has one adopter-oriented entry point and six task guides spanning installation
through production operations. The root README reports the current product rather than the
pre-hardening MVP: it includes mandatory authentication, separate database migrations,
multi-signal identity, schema versions, property/revenue metrics, experiment analytics, and
operational telemetry; it also names the three stub metric routes honestly. The product spec is
retained as vision with an explicit current-contract boundary. The checked-in Haskell example now
conforms to the published `user_registered` schema and has a smaller direct dependency set.

Validation went beyond prose inspection. Generated OpenAPI and event catalogs remained clean;
all local Markdown targets resolved; JSON examples parsed; the Haskell example compiled; a fresh
PostgreSQL database applied and reapplied the documented migration plan; the live server returned
healthy readiness, accepted the documented page view, exposed it through an account-scoped
metric, and served the expected eight-event catalog and eighteen-path OpenAPI document. With
ClickHouse running, all 133 core examples passed, and all 13 client examples passed with the live
integration enabled.

No requested adoption surface remains undocumented. Browser/React SDKs, container distribution,
and a dashboard remain product gaps, but the docs now state those gaps rather than implying that
they ship. The only operational caveat found was an older local PGMQ installation without current
ledger provenance; the operations guide now stops users from treating that as a normal fresh
install. No architecture decision changed, so no ADR promotion was necessary.


## Context and Orientation

Kansoku is a Haskell analytics service whose local runtime consists of the
`kansoku-server` process, PostgreSQL for the durable PGMQ event queue and API-key records,
and ClickHouse for analytics storage and queries. `process-compose.yaml` starts the two
databases inside the Nix development shell. `justfile` exposes the supported local commands.
PostgreSQL migrations are applied by `just migrate`; ClickHouse migrations are independent
and are applied by `just ch-migrate`. A write key can ingest for one account. A service token
can ingest and can query metrics for that same account. The credential, not a caller-supplied
`accountId`, determines the stored and queried account.

The public HTTP contract is defined in `kansoku-api/src/Kansoku/Api.hs`,
`kansoku-api/src/Kansoku/Ingest/Api.hs`, and
`kansoku-api/src/Kansoku/Metrics/Api.hs`. It is generated into
`docs/api/openapi.json` and served at `GET /openapi.json`. The event model and validation
rules live under `kansoku-api/src/Kansoku/Event/`; the public versioned catalog is generated
into `docs/contracts/events.json` and served without credentials at `GET /v1/schemas`.
`kansoku-core/src/Kansoku/Config.hs` is the source of truth for environment variables and
defaults. `kansoku-client/src/Kansoku/Client.hs` and
`kansoku-client/src/Kansoku/Client/Metrics.hs` are the supported Haskell client modules.

The relevant accepted ADRs are all user-contract boundaries rather than incidental
implementation notes. `docs/adr/0001-sdk-grade-ingest-contract-boundaries.md` defines partial
batch acceptance, CORS, and request limits. `docs/adr/0002-pipeline-observability-readiness-and-writer-recovery.md`
defines operational routes, readiness, and telemetry. `docs/adr/0003-api-key-authentication-and-account-scoped-analytics.md`
defines credentials and tenant isolation. `docs/adr/0004-queryable-event-properties-and-identity-resolved-projection.md`
defines safe property grouping and revenue aggregation. `docs/adr/0005-evidence-based-multi-signal-identity-resolution.md`
defines accepted identifier kinds and conflict-aware stitching. `docs/adr/0006-exposure-based-experiment-analytics.md`
defines experiment exposure, conversion, and funnel meaning. `docs/adr/0007-versioned-event-schema-governance-and-publication.md`
defines immutable event versions and the two published contract forms. This documentation
change does not revise those durable decisions, so it should not create another ADR.


## Plan of Work

### Milestone 1 — A navigable adoption path

Create `docs/README.md` as a short documentation map that distinguishes adopter guides,
generated references, governance/runbooks, and internal project records. Add
`docs/guides/getting-started.md`, `docs/guides/send-events.md`,
`docs/guides/query-metrics.md`, `docs/guides/haskell-sdk.md`,
`docs/guides/configuration.md`, and `docs/guides/operations.md`. Use runnable commands and
payloads copied from current types and generated contracts. Every page links back to the docs
index and forward to the next useful task. This milestone is accepted when all guide-local
links resolve and the quickstart describes an end-to-end event and metric flow with separate
write and service credentials.

### Milestone 2 — Correct current claims and examples

Rewrite current-state sections of `README.md`: document authentication and explicit migrations,
list implemented and stubbed metric routes accurately, describe shipped identity, experiment,
schema, and telemetry capabilities, and replace the old roadmap/documentation pointers with the
new guides. Add a status boundary near the top of `docs/initial-spec.md`, update its event-model
section to point to the generated current contract, and label future-only components clearly.
Update `kansoku-client/example/Main.hs` so its emitted event satisfies the published schema.
This milestone is accepted when no user-facing page claims implemented features are future work,
no page presents a stub as live, and the SDK example uses a contract-valid payload.

### Milestone 3 — Prove the documentation matches the software

Regenerate and diff-check the OpenAPI and event catalog, compile the executable SDK example, run
the complete test suite, scan Markdown links, and search user-facing prose for known obsolete
claims. Record exact results in this plan. This milestone is accepted when generated checks are
clean, every relative documentation link resolves, the example builds, and project tests pass.


## Concrete Steps

All commands run from `/Users/shinzui/Keikaku/bokuno/kansoku-project/kansoku`.

Create and review the documentation with normal repository tools, then run:

```bash
just openapi-check
just contracts-check
cabal build kansoku-client:exe:kansoku-client-example
cabal test all
```

Expected result: every command exits zero and both generated checks leave
`docs/api/openapi.json` and `docs/contracts/events.json` unchanged.

Final evidence on 2026-07-20:

```text
just openapi-check: passed; generated artifact unchanged
just contracts-check: passed; generated artifact unchanged
cabal build kansoku-client:exe:kansoku-client-example: passed
cabal test all with ClickHouse running: kansoku-core 133 examples, 0 failures;
  kansoku-client 13 examples, 0 failures, 1 pending without live-server variables
cabal test kansoku-client:test:kansoku-client-test with KANSOKU_SERVER_URL and
  KANSOKU_API_KEY: passed, including the live integration
```

The fresh-install and live HTTP proof used an isolated PostgreSQL database and port 18080. The
temporary database was removed after validation; the repository's older local `kansoku` database
was not dropped or imported. The observed API evidence was:

```text
PostgreSQL up #1: pgmq/0001, pgmq/0002, kansoku/0001 applied_now
PostgreSQL up #2: all three already_applied
GET /health: OK
GET /ready: ready; writer_alive, pgmq_reachable, queue_depth, writer_flush_stale all true
POST /v1/events: {"accepted":1,"eventId":"docs-e2e-page-view-20260720-long"}
GET /metrics/events: one 2026-07-20 point with value 1 for the isolated account
GET /v1/schemas: catalogVersion 1, 8 events
GET /openapi.json: OpenAPI 3.1.0, 18 paths
```

Check local Markdown links using a repository-scoped script that extracts relative link targets,
removes optional fragments, resolves them against the source document, and reports only missing
paths. The expected transcript is:

```text
checked 62 local Markdown links: no missing targets
```

Inspect the final diff and worktree:

```bash
git diff --check
git status --short
```

Expected result: `git diff --check` is silent; status lists only this plan, the user-documentation
changes, and the corrected client example.

Final formatting/example evidence was `nix fmt` with zero changed files, seven parsed JSON
examples, and a silent `git diff --check`.


## Validation and Acceptance

A new adopter starting at `docs/README.md` can identify the prerequisites, enter `nix develop`,
start PostgreSQL and ClickHouse, run both independent migrations, issue a write key and service
token, and start Kansoku. The guide explains that normal server startup does not run schema
migrations and that credentials are always required for analytics routes.

The ingestion guide contains a complete event accepted by the current
`AnalyticsEvent` decoder and version 1 `page_view` schema. It explains single-event HTTP 202,
partial batch acceptance with zero-based rejections, effective schema version 1, server-stamped
`receivedAt` and account, payload limits, retryability, identifier rules, and browser CORS.

The metrics guide distinguishes the twelve live metric paths from the three contract stubs,
documents required service-token authentication, date ranges, time grains, group dimensions,
ordered funnel and retention semantics, experiment semantics, and the common result shape. Its
examples use only current query parameter names from `docs/api/openapi.json`.

The SDK guide builds from the checked-in `kansoku-client` package and accurately describes
buffering, explicit flush/close behavior, retry and drop accounting, schema version pinning,
catalog fetching, and the current typed experiment clients. The standalone example compiles and
emits a schema-valid event.

The configuration and operations guides enumerate every field parsed by
`Kansoku.Config.loadConfig`, the four operational endpoints, all seven exported pipeline metric
names, explicit migration ownership, safe ClickHouse migration behavior, readiness meanings,
telemetry opt-in, and the existing identity-erasure runbook. Generated artifact checks, link
checks, the example build, and `cabal test all` all exit successfully.


## Idempotence and Recovery

Documentation edits and generated checks are repeatable. `just migrate` and `just ch-migrate`
are forward-only migration commands but are idempotent after successful application; the guides
must not recommend the destructive development-only `just ch-reset` as part of ordinary startup.
`just up` may be restarted after interruption, and server queue provisioning is idempotent once
PostgreSQL migrations exist. If a generated check changes an artifact, inspect the diff and fix
the source-of-truth route or registry documentation rather than hand-editing generated JSON.


## Interfaces and Dependencies

This work adds no runtime dependencies and changes no HTTP interface. It documents the existing
`NamedRoutes KansokuAPI`, the `AnalyticsEvent`, `BatchAck`, `MetricResult`, and `SchemaCatalog`
JSON types, and the `Client`, `ClientConfig`, and `EventIds` Haskell client types. The documented
runtime services are PostgreSQL with the migration-installed PGMQ schema, ClickHouse with
repository-owned SQL migrations, and the single `kansoku-server` process containing HTTP,
writer, and queue-poller lifetimes.

Dependency behavior was located through Mori before it was described. The registered
`shinzui/pgmq-hs` source confirms that `pgmq-migration` installs a vendored PGMQ schema without
the PostgreSQL extension and is composed into a `pg-migrate` plan. The registered
`shinzui/shibuya` source defines the supervised batch-processing role. Kansoku's own migration,
queue, writer, and server modules remain the final authority for how those libraries are used in
this application.

Revision note (2026-07-20): implemented and completed the documentation refresh. The completed
plan incorporates the fresh-install migration evidence, legacy-ledger caveat, live HTTP proof,
test results, and ADR distillation outcome discovered during validation.
