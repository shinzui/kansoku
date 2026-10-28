---
type: Research Document
title: Practices Kansoku can adopt from Hex
description: Compare Hex's 2026 AI analytics platform practices with Kansoku's shipped service and identify which transfer to a self-hosted, ClickHouse-native metrics API.
generated:
  by: anthropic/claude-fable-5-1
  at: "2026-10-28T21:15:24Z"
researchId: RES-1
status: complete
scope: >-
  Hex's public homepage, product documentation, changelog, and engineering blog as
  read on 2026-10-28, compared with Kansoku at revision 8076997: the README, product
  vision, query-metrics guide, event-schema governance, metric registry and query
  compiler modules, request logging, readiness and observability modules, ClickHouse
  migrations, Hurl acceptance suite, OpenAPI document, and event catalog. Hex claims
  are vendor documentation and marketing statements, not independently verified. Two
  Hex pages were unreachable (the semantic-model YAML specification and the Explore
  cell reference), and Hex's official MCP tool list was not published on any page
  read. No Hex account was used, no benchmark was run, and no Kansoku code was
  changed.
relatedDecisions:
  - docs/adr/0004-queryable-event-properties-and-identity-resolved-projection.md
  - docs/adr/0006-exposure-based-experiment-analytics.md
  - docs/adr/0007-versioned-event-schema-governance-and-publication.md
  - docs/adr/0009-bounded-complete-aggregate-responses.md
  - docs/adr/0010-owned-executable-acceptance-environments.md
relatedPlans:
  - docs/plans/6-semantic-metrics-layer-and-typed-query-api.md
  - docs/plans/16-pipeline-observability-queue-depth-writer-lag-and-exported-telemetry.md
  - docs/plans/20-event-schema-governance-versioned-registry-and-portfolio-event-contracts.md
  - docs/plans/26-bound-analytics-query-inputs-and-result-cardinality.md
  - docs/plans/28-gate-service-releases-with-isolated-hurl-acceptance-and-ci.md
reviews:
  - kind: model
    reviewer: anthropic/claude-fable-5-1
    reviewed_at: "2026-10-28T21:40:00Z"
    document_timestamp: "2026-10-28T21:15:24Z"
    scope: content-and-metadata
    outcome: commented
    provider: anthropic
    model: claude-fable-5-1
    effort: unspecified
    context: >-
      Author self-review in the Kansoku checkout. Every Kansoku claim was checked
      against the cited file at revision 8076997 by reading or grepping it. Hex
      claims were re-read from the cited pages but not verified against a live
      workspace. This is not an independent review or an approval attestation and
      is therefore not mirrored into `verified`.
sources:
  - id: hex-home
    resource: https://hex.tech/
    title: Hex homepage positioning and feature names
  - id: hex-semantic-intro
    resource: https://learn.hex.tech/docs/connect-to-data/semantic-models/intro-to-semantic-models
    title: Intro to Hex semantic models
  - id: hex-modeling-workbench
    resource: https://learn.hex.tech/docs/connect-to-data/semantic-models/semantic-authoring/semantic-authoring-overview
    title: Hex Modeling Workbench and semantic authoring
  - id: hex-semantic-sync
    resource: https://learn.hex.tech/docs/connect-to-data/semantic-models/semantic-model-sync/intro
    title: Hex Semantic Model Sync
  - id: hex-context-studio
    resource: https://hex.tech/blog/introducing-context-studio/
    title: Introducing Context Studio
    last_modified: 2026-01-28
  - id: hex-endorsements
    resource: https://learn.hex.tech/docs/agent-management/context-management/endorsements-in-context-studio
    title: Endorsements in Context Studio
  - id: hex-evals
    resource: https://learn.hex.tech/docs/agent-management/evals
    title: Hex Evals overview
  - id: hex-eval-blog
    resource: https://hex.tech/blog/evaluate-data-agents/
    title: How Hex evaluates data agents
  - id: hex-caching
    resource: https://learn.hex.tech/docs/explore-data/cells/sql-cells/query-caching
    title: Hex query caching
  - id: hex-api
    resource: https://learn.hex.tech/docs/api/api-overview
    title: Hex API overview
  - id: hex-changelog
    resource: https://learn.hex.tech/changelog
    title: Hex changelog, 2026 entries
  - id: hex-changelog-usage
    resource: https://learn.hex.tech/changelog/2026-10-22
    title: Agent usage and credit spend via API, MCP, and CLI
    last_modified: 2026-10-22
  - id: hex-mcp-blog
    resource: https://hex.tech/blog/mcps-with-hex/
    title: MCPs with Hex
  - id: hex-clickhouse
    resource: https://hex.tech/blog/announcing-clickhouse-partnership/
    title: Hex and ClickHouse are official partners
    last_modified: 2026-03-11
  - id: hex-chdb
    resource: https://learn.hex.tech/docs/connect-to-data/data-connections/clickhouse-chdb
    title: Hex ClickHouse connection with chDB
  - id: kansoku-readme
    resource: README.md
    title: Kansoku README, shipped surface and scope
  - id: kansoku-vision
    resource: docs/initial-spec.md
    title: Kansoku product vision
  - id: kansoku-query-guide
    resource: docs/guides/query-metrics.md
    title: Query metrics guide, bounds and accuracy map
  - id: kansoku-governance
    resource: docs/event-schema-governance.md
    title: Event schema governance
  - id: kansoku-event-catalog
    resource: docs/contracts/events.json
    title: Generated event schema catalog
  - id: kansoku-openapi
    resource: docs/api/openapi.json
    title: Generated OpenAPI document
  - id: kansoku-metric-definition
    resource: kansoku-core/src/Kansoku/Metrics/Definition.hs
    title: MetricDefinition and RatioMetric types
  - id: kansoku-metric-registry
    resource: kansoku-core/src/Kansoku/Metrics/Registry.hs
    title: Built-in metric registry
  - id: kansoku-metric-query
    resource: kansoku-core/src/Kansoku/Metrics/Query.hs
    title: Metric query compiler
  - id: kansoku-metric-handler
    resource: kansoku-core/src/Kansoku/Metrics/Handler.hs
    title: Metric route handlers and stubs
  - id: kansoku-request-log
    resource: kansoku-core/src/Kansoku/RequestLog.hs
    title: Correlated HTTP access log fields
  - id: kansoku-readiness
    resource: kansoku-core/src/Kansoku/Readiness.hs
    title: Readiness checks including writer flush staleness
  - id: kansoku-observability
    resource: kansoku-core/src/Kansoku/Observability.hs
    title: Prometheus pipeline instruments
  - id: kansoku-ch-migrations
    resource: db/clickhouse/migrations/
    title: ClickHouse forward-only migrations 0001 to 0016
  - id: kansoku-hurl
    resource: kansoku-api/test/hurl/README.md
    title: Executable HTTP acceptance contracts
---

# Practices Kansoku can adopt from Hex

## Research question

Hex is a venture-backed AI analytics platform that sits on top of a data
warehouse. Kansoku is a self-hosted, ClickHouse-native analytics service that
owns ingestion, identity, storage, and a typed metrics API, and deliberately
refuses to become a general BI tool[^kansoku-readme][^kansoku-vision]. Which of
Hex's product and engineering practices, as visible in its 2026 public material,
transfer to Kansoku, and which do not?

## Executive finding

The product shape does not transfer. Hex's notebooks, generative apps, chat
threads, and model marketplace all presuppose a UI and a warehouse underneath,
and Kansoku is the layer underneath. Six practices do transfer, and most of them
amount to publishing, hardening, or instrumenting things Kansoku already has
internally:

1. Publish the metric registry as a versioned contract and implement the custom
   metric route as a declared definition, not SQL.
2. Treat the event and metric catalogs as agent context, with an explicit
   declared-versus-observed split that mirrors Hex's endorsements.
3. Extend the acceptance suite into an evaluation suite with tolerance semantics
   for approximate answers and scheduled drift runs.
4. Return an explicit data-freshness watermark, then add a closed-bucket result
   cache.
5. Give the service one surface with three faces, CLI, API, and MCP, and attribute
   query cost per credential.
6. Add impact analysis for contract changes.

A seventh finding is about position rather than imitation: Kansoku should be the
best possible source for a Hex-class tool, which costs an afternoon of ClickHouse
column comments and a semantic-model export.

## Method and evidence limits

Hex was read through its homepage, product documentation, changelog, and
engineering blog on 2026-10-28. Kansoku was read at revision 8076997 by
inspecting the cited documents and modules and grepping for the specific
capabilities in question. Counts quoted below (operations with descriptions,
migrations without comments, log fields) were produced by scripts over the
committed artifacts and are reproducible from the checkout.

Limits: Hex statements are vendor claims. The Hex semantic-model YAML
specification and Explore cell documentation returned HTTP 404 during the
session, so field names for those features are not asserted here. Hex's official
MCP server page does not list its tools, and only a community wrapper's tool list
was visible[^hex-mcp-blog]. No Hex workspace was exercised.

## What Hex does

Hex's 2026 positioning is "conversational analytics and context management for
the agentic era", with named pillars Notebook Agent, Threads, Context Engine,
Context Studio, Evals, data apps, Explore, semantic models, an MCP server, a CLI,
and the Hex API[^hex-home]. The practices relevant to a metrics service are:

**Semantic models as versioned, published definitions.** Each model is a YAML
file with a source table or SQL, dimensions, measures, and relationships. Hex
imports every source column as a dimension and carries over column descriptions
by default. Publishing opens a preview with four tabs: Changes (a diff since the
last publish plus validation), References (where the model is used), Explore, and
Threads. A History page keeps drafts, published versions, and agent
checkpoints[^hex-modeling-workbench]. Models can also be imported one way from
Git, with Cube, dbt MetricFlow, Snowflake Semantic Views, and Apache Ossie as
sources, translated into four objects: models, measures, dimensions, and
joins[^hex-semantic-sync][^hex-semantic-intro]. Hex describes the result as
"deterministic SQL generation" so that human and agent analyses use the same
definitions[^hex-context-studio].

**Endorsements and context as a managed, observable product surface.** Admins
and Managers mark schemas, tables, projects, and semantic models as endorsed;
agents prioritize endorsed assets, and Endorsed mode restricts them to those
assets. Endorsements can be set through three API operations:
`UpdateSemanticProject`, `UpdateDataConnectionSchema`, and
`UpdateProject`[^hex-endorsements]. Context Studio adds a dashboard of what
people ask across Slack, MCP, the Notebook Agent, and Threads, AI-extracted
topics, warnings for confusion, and a workflow of observe, diagnose, curate,
stage and test in a preview, then publish with version history and
attribution[^hex-context-studio].

**Evals as a regression gate for answers.** A suite is one YAML file with up to
100 cases; each case has a prompt, one to five attempts, and one to fifteen
rubrics. Rubric graders are `judge_thread`, `judge_final_answer`, and
`numeric_value`. A numeric rubric can name an `expectedSql` query that is run at
grading time, with `tolerancePercentage` (default 1) or `absoluteTolerance`.
Rubrics can be grouped under a `measure` so the suite reports a pass rate per
measure. Hex distinguishes baseline suites, which must keep passing, from
hill-climbing suites for questions the agent cannot yet answer. Suites run from
the CLI against published context or against a context preview created by
`hex context preview`, and published suites can run on a daily, weekly, or
monthly schedule to catch drift from upstream data or dependencies[^hex-evals].
Hex's own evaluation lab recommends pairwise comparison against a refreshed
production baseline, hybrid judging with ground truth available at judge time,
and reading trajectories rather than trusting aggregates[^hex-eval-blog].

**Explicit caching and freshness.** A query result is reused for 60 minutes by
default, with separate workspace defaults for development and published apps and
per-project overrides. Cached data is retained for 30 days after last access.
Non-SELECT statements, results over 16 GB, and queries that depend on a changing
variable are never cached. Apps show the age of the oldest cached result and
expose a Refresh that bypasses the cache; a scheduled run can refresh the shared
cache, and other projects reuse the newer result[^hex-caching].

**One surface, three faces, with attributed cost.** The Hex CLI shipped on
2026-04-07, Hex became an MCP client on 2026-05-28, the Hex Agent became available
through CLI and API on 2026-07-30, Evals on 2026-08-04, semantic projects via CLI
on 2026-08-18, and agent usage and credit spend via API, MCP, and CLI on
2026-10-22[^hex-changelog][^hex-changelog-usage]. The API uses bearer tokens with
distinct prefixes: personal tokens (`hxtp_`) must expire within 7 to 120 days,
workspace tokens (`hxtw_`) are admin-issued and scoped. Rate limits are 60
requests per minute per user with remaining and reset headers, pagination is
cursor based with an `after` token, and `ListAgentUsage` returns per-run usage for
chargeback[^hex-api].

**ClickHouse as a first-class source.** Hex and ClickHouse became official
partners on 2026-03-11, Hex's ClickHouse connection can enable chDB, and Hex
positions chDB 4 as a Pandas interface for agents over ClickHouse
performance[^hex-clickhouse][^hex-chdb].

## Kansoku's current state

The following facts were verified at revision 8076997.

- **A semantic metric layer exists but is unpublished.** `Kansoku.Metrics.Registry`
  defines thirteen built-in `MetricDefinition` and `RatioMetric` values with
  descriptions, event names, aggregations, and default grains[^kansoku-metric-registry][^kansoku-metric-definition].
  The handler resolves a route key through `builtinMetric` and the compiler turns
  the definition into SQL against the event registry through
  `compileSimpleMetric`[^kansoku-metric-handler][^kansoku-metric-query]. No
  endpoint publishes these definitions. The event registry, by contrast, is
  published at `GET /v1/schemas` and committed as a generated
  catalog[^kansoku-event-catalog][^kansoku-governance].
- **The custom metric route is a stub.** `/metrics/custom`, `/metrics/acquisition`,
  and `/metrics/organizations` return HTTP 404 with code
  `not_implemented`[^kansoku-metric-handler][^kansoku-query-guide].
- **Declared versus undeclared events is already a real split.** Unknown event
  names are accepted without property checks; declaration is the point at which
  enforcement starts. The governance guide offers a hand-run SQL query to find
  legacy producers by schema version[^kansoku-governance].
- **The accuracy map lives in prose.** The query guide states which routes are
  exact and which use `uniqCombined` sketches with about 0.8 percent relative
  error[^kansoku-query-guide]. The OpenAPI document has 18 operations, 16 of which
  carry a summary or description, and 24 component schemas, 2 of which carry a
  description[^kansoku-openapi].
- **No result cache and no freshness in responses.** The only cache in the service
  is the writer's ClickHouse connection cell. Metric responses contain `metric`
  and `points` only[^kansoku-query-guide]. The ingredients for a watermark exist:
  seven Prometheus pipeline instruments including
  `kansoku_queue_oldest_message_age_seconds` and
  `kansoku_writer_batch_flush_seconds`[^kansoku-observability], and a readiness
  check `writer_flush_stale` that carries the last flush time and
  backlog[^kansoku-readiness].
- **Credentials are prefixed but unattributed.** Write keys and service tokens use
  `ksk_w_` and `ksk_s_` prefixes[^kansoku-readme]. The access log records
  `time`, `method`, `path`, `status`, `duration_ms`, `trace_id`, `span_id`, and a
  truncated user agent, and no account or key identifier[^kansoku-request-log].
  Nothing captures ClickHouse rows or bytes read per query.
- **Acceptance is a baseline suite.** `just acceptance` builds the Nix executable,
  owns fresh PostgreSQL and ClickHouse processes, seeds fixtures for July 1 to 12,
  2026, and asserts exact values for every implemented route, plus a
  high-cardinality account for bound checks[^kansoku-hurl].
- **ClickHouse storage is not self-describing.** The sixteen forward-only
  migrations contain no `COMMENT` clauses on tables or columns[^kansoku-ch-migrations].

## Transferable practices

### 1. Publish the metric registry; make the custom route a definition

Hex's whole 2026 story rests on semantic definitions that are versioned,
published with a diff and a references view, and compiled deterministically for
humans and agents alike[^hex-modeling-workbench]. Kansoku already compiles
definitions deterministically; it only lacks publication.

Adoption:

- Add `GET /v1/metrics` and a generated `docs/contracts/metrics.json` with a
  `catalogVersion`, following the event catalog's shape and the `just contracts`
  and golden-test discipline[^kansoku-governance]. Each entry carries name,
  description, event names, aggregation and property, allowed `groupBy`
  dimensions, default grain, and an accuracy class (`exact` or `approximate`
  with the stated error).
- Implement `/metrics/custom` as a POST that accepts a `MetricDefinition` body,
  which already derives `FromJSON`[^kansoku-metric-definition], and runs it
  through `compileSimpleMetric` under the existing input and result bounds of
  ADR 9. This is Hex's Explore over a semantic model in API form and stays
  inside the vision's rule of typed APIs instead of arbitrary SQL[^kansoku-vision].
- Treat metric definitions like event schemas: immutable released versions, a
  note per version, and a change process that moves the catalog, OpenAPI, and
  client together.

### 2. Catalogs as agent context, with a declared-versus-observed split

Hex's endorsements give agents a trusted subset and a mode that refuses the
rest[^hex-endorsements]. Kansoku's declared-versus-undeclared distinction is the
same idea and is already enforced on the write path; it is not surfaced on the
read path.

Adoption:

- Add an observed view, for example `GET /v1/schemas/observed`, listing event
  names, property keys, and schema-version distribution seen in `events_raw`
  but not declared, which productizes the SQL in the governance guide.
- Add a `declaredOnly` query parameter that rejects undeclared event names in
  custom definitions and funnel steps, mirroring Endorsed mode.
- Move the accuracy class out of prose and into the metric catalog and OpenAPI
  descriptions, and raise component-schema description coverage from 2 of 24,
  so an agent reading the specification learns that `users` at day grain is a
  sketch without reading the guide.
- Package an MCP server with three tools: list schemas, list metrics, query
  metric. Hex's agents retrieve exactly this kind of context: semantic models,
  warehouse metadata, and guides[^hex-context-studio]. The OpenAPI document is
  close enough that this is mostly packaging once descriptions are complete.

### 3. Evaluation suites with tolerance semantics and drift runs

Hex's `numeric_value` rubric with `expectedSql`, tolerance bands, per-`measure`
pass rates, baseline versus hill-climbing suites, and scheduled drift
runs[^hex-evals] map cleanly onto Kansoku's existing acceptance harness.

Adoption:

- Add a ground-truth assertion mode to the acceptance harness that computes the
  expected value directly in ClickHouse from the seeded rows and compares the
  HTTP answer within a per-route band. Exact routes get zero tolerance.
  Approximate routes (`users` at day and week grain, `experiments` exposures)
  get a declared band consistent with ADR 6 and the guide.
- Tag assertions by accuracy class so the report reads per class, which is
  Hex's `measure` concept.
- Write hill-climbing cases for the three stubbed routes so they are specified
  before they are built, and add a case that cross-checks a rollup answer
  against a raw-resolution answer on the same fixture.
- Run the suite on a schedule against a long-lived environment, not only the
  disposable one, to catch drift from ClickHouse upgrades or migration changes.

### 4. Freshness watermark first, then a closed-bucket cache

Hex shows result age, lets apps bound it, refreshes a shared cache from
scheduled runs, and refuses to cache time-dependent queries[^hex-caching].
Kansoku serves every dashboard poll from ClickHouse and says nothing about how
fresh the answer is.

Adoption:

- Return a `dataAsOf` watermark on every metric response, derived from the last
  successful writer flush and the oldest queued message age that the readiness
  and Prometheus layers already compute[^kansoku-readiness][^kansoku-observability].
  This is the honest version of Hex's age indicator and is more useful to an
  agent than a cache age.
- Add a result cache keyed on account, metric, and normalized query. Only
  buckets whose window has fully closed before the watermark are cacheable; the
  current bucket is Kansoku's equivalent of Hex's changing variable. Half-open
  UTC date ranges make closed-bucket detection trivial.
- Accept `maxAge` and `refresh` request parameters, and return the computed-at
  time, mirroring "Run without cached results" and app run settings.

### 5. One surface, three faces, and per-credential cost

Hex built CLI, API, and MCP access to one agent and then shipped usage and
credit attribution for chargeback[^hex-changelog][^hex-changelog-usage][^hex-api].
Kansoku's token prefixes already match Hex's discipline, but administration
lives in `just` recipes, service tokens do not expire, and no query is
attributed to a credential or costed.

Adoption:

- Ship a `kansoku` CLI that issues and revokes keys, validates an event payload
  against the live catalog, diffs catalogs between revisions, and queries a
  metric. The migrate executable is the natural home.
- Add optional expiry to service tokens, following Hex's mandatory expiry for
  personal tokens.
- Record a hashed key identifier and account in the access log, and capture
  ClickHouse read rows and bytes per metric call, for example from the
  `X-ClickHouse-Summary` response header. Expose per-credential aggregates
  through Prometheus labels or an internal usage route. This is Hex's
  token-spend observability translated into scan-cost observability.

### 6. Impact analysis for contract changes

Hex's publish preview shows Changes and References and keeps a history
timeline[^hex-modeling-workbench]. Kansoku's golden tests catch registry and
artifact drift, but property grouping requires every event in a metric to
declare the property[^kansoku-query-guide], so a new schema version can silently
remove a `prop:<name>` grouping from a metric.

Adoption: a `contracts-impact` check that, from the registry diff, lists which
built-in metrics reference each changed event or property and which `groupBy`
options appear or disappear. This is cheap once the metric catalog from
practice 1 exists.

## Be a source for Hex-class tools, not a clone

Hex and ClickHouse are official partners, Hex connects to ClickHouse directly,
and Hex's Modeling Workbench imports every column and its description as a
dimension by default[^hex-clickhouse][^hex-chdb][^hex-modeling-workbench]. Two
low-cost changes make Kansoku's storage and definitions legible to Hex and to
any other tool:

- Add `COMMENT` clauses to ClickHouse tables and columns in a new migration,
  and maintain a stable, read-only public view set over `events_raw`, the
  identity tables, and the rollups[^kansoku-ch-migrations].
- Export the metric registry as a semantic-model file in a format Hex syncs.
  Cube and dbt MetricFlow are documented sync sources[^hex-semantic-sync]; Hex's
  native YAML field names could not be confirmed because the specification page
  was unreachable. With this export, a dashboard built in Hex and a response from
  Kansoku's API agree on what a metric means, which fulfills the vision's promise
  that the semantic layer keeps numbers consistent across dashboards, reports,
  and product UI[^kansoku-vision].

## Not transferable

Notebooks and Python kernels, generative data apps, chat threads inside the
product, model selection and bring-your-own-key, Slack delivery, and
TV mode[^hex-home][^hex-changelog]. Kansoku has no UI, and the vision states it
must not become a generic BI tool[^kansoku-vision]. Natural-language querying
is listed as later scope; the path consistent with the vision is the catalogs
plus MCP from practice 2, so that any agent, Hex's included, does the language
part while Kansoku remains the deterministic answer.

## Suggested sequencing

1. Practice 1, practice 2's catalog and description work, and practice 4's
   watermark. These mostly publish what exists and unblock everything else.
2. Practice 3's tolerance assertions, since the metric catalog gives each route
   a declared accuracy class to assert against.
3. Practice 5 and practice 6.
4. ClickHouse column comments can land at any point and need no design.

## Open questions

- Should metric definitions be versioned per metric like event schemas, or
  should the whole metric catalog carry one version? Event schemas chose
  per-event versions in ADR 7; metrics compose events, so a per-metric version
  that pins its event versions seems more honest.
- Which semantic-model export format should be first: Cube, MetricFlow, or
  Hex's native YAML once its specification is readable?
- Does a closed-bucket cache need invalidation for late-arriving events, or is
  the watermark plus a documented late-arrival window sufficient?

[^hex-home]: Hex homepage, read 2026-10-28, for positioning and the names of
    product pillars.
[^hex-semantic-intro]: Hex documentation introducing semantic models, their YAML
    specification, and the supported import sources.
[^hex-modeling-workbench]: Hex Modeling Workbench documentation, for YAML per
    model, default column import with descriptions, the publish preview tabs, and
    the History page.
[^hex-semantic-sync]: Hex Semantic Model Sync documentation, for Cube, MetricFlow,
    Snowflake Semantic Views, and Apache Ossie as one-way sources translated into
    models, measures, dimensions, and joins.
[^hex-context-studio]: Hex blog post introducing Context Studio, for the three
    context layers, the usage dashboard, and the observe-to-publish workflow.
[^hex-endorsements]: Hex documentation on endorsements, for endorsable assets,
    roles, agent prioritization, and the three API operations.
[^hex-evals]: Hex Evals documentation, for suite structure, graders, tolerance
    fields, measures, baseline versus hill-climbing, preview runs, and schedules.
[^hex-eval-blog]: Hex engineering blog on evaluating data agents, for pairwise
    baselines, hybrid judging, and judge calibration findings.
[^hex-caching]: Hex query caching documentation, for the 60-minute default,
    30-day retention, non-cacheable cases, age display, and scheduled refresh.
[^hex-api]: Hex API overview, for token prefixes and expiry, rate limits,
    cursor pagination, and the usage endpoints.
[^hex-changelog]: Hex changelog, for the 2026 dates of the CLI, MCP, agent API,
    Evals, and semantic project features.
[^hex-changelog-usage]: Hex changelog entry of 2026-10-22, for agent usage and
    credit spend data via API, MCP, and CLI.
[^hex-mcp-blog]: Hex blog post on MCPs, which describes the official server's
    purpose without listing its tools and documents a community wrapper's tools.
[^hex-clickhouse]: Hex announcement of the ClickHouse partnership and chDB 4
    positioning.
[^hex-chdb]: Hex documentation for enabling chDB on a ClickHouse connection.
[^kansoku-readme]: Kansoku README, for the shipped surface, credential
    prefixes, scope, and the statement that a dashboard UI is not shipped.
[^kansoku-vision]: Kansoku product vision, for the semantic metrics layer
    intent, typed APIs instead of SQL, later scope, and the design philosophy.
[^kansoku-query-guide]: Query metrics guide, for the common contract, bounds,
    stubbed routes, property-grouping rule, and the exact-versus-approximate map.
[^kansoku-governance]: Event schema governance, for permissive undeclared
    events, immutable versions, the contract regeneration workflow, and the
    schema-version distribution query.
[^kansoku-event-catalog]: Generated event schema catalog, as the model for a
    metric catalog.
[^kansoku-openapi]: Generated OpenAPI document; counts of described operations
    and schemas were produced by a script over this file.
[^kansoku-metric-definition]: `MetricDefinition` and `RatioMetric` with derived
    `FromJSON` and `ToJSON` instances.
[^kansoku-metric-registry]: The thirteen built-in metric definitions.
[^kansoku-metric-query]: `compileSimpleMetric` and the property, grouping, and
    filter compilation against the event registry.
[^kansoku-metric-handler]: Route handlers resolving `builtinMetric` and the
    `notImplemented` stubs.
[^kansoku-request-log]: The access log field set, which carries no account or
    credential identifier.
[^kansoku-readiness]: The `writer_flush_stale` readiness check with last flush
    time, age, limit, and backlog.
[^kansoku-observability]: The seven Prometheus pipeline instruments, including
    queue length and oldest message age.
[^kansoku-ch-migrations]: The sixteen ClickHouse migrations, none of which
    carries a `COMMENT` clause.
[^kansoku-hurl]: The acceptance suite README, for the owned-database harness,
    fixture semantics, and exact assertions.
