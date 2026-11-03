---
id: 6
slug: publish-kansoku-analytics-as-a-ducklake-lakehouse-data-product
title: "Publish Kansoku analytics as a DuckLake lakehouse data product"
kind: master-plan
created_at: 2026-11-03T15:16:12Z
intention: "intention_01m6gzmpyde2nr3ywy1d2vhbn9"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-11-03T15:16:12Z
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-03T15:42:12Z
      mode: "update"
      note: "Replace uncreated child number reservations with workstream names to prevent allocation conflicts; preserve scope and dependencies"
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-11-03T15:49:25Z
      mode: "update"
      note: "Prefer a Kansoku-written Parquet staging file (wireform-parquet over native ClickHaskell reads) with ClickHouse table-function export as the measured fallback; record the writer cohort and proof obligations."
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-11-03T15:59:59Z
      mode: "update"
      note: "Restore numeric child identifiers EP-54 to EP-57 with reserved paths, the next unclaimed numbers after MasterPlan 7's children, so the registry parses; keep workstream names as aliases."
---

# Publish Kansoku analytics as a DuckLake lakehouse data product

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Vision & Scope

Kansoku is an open-source, self-hosted analytics service. Its analytical facts live in
ClickHouse and reach consumers through the account-scoped HTTP metrics API and, for trusted
single-tenant operators, the constrained reader projections of
[ADR-18](../adr/0018-stable-reader-sql-and-real-consumer-conformance.md). Many adopters also
run, or are building, a lakehouse: Parquet on object storage described by a table format and
queried with DuckDB, MotherDuck, dbt, notebooks or BI tools. They want product analytics there
too, next to billing, CRM and warehouse facts, under the ownership, freshness, classification
and lifecycle rules that lakehouse and data-mesh governance expects. Today they must hand-roll
an export from the reader views, and ADR-18 is explicit that such copies carry no deletion or
retention guarantee from Kansoku.

After this initiative is complete, an operator can configure a **DuckLake** catalog and an
object-store data path, start one new executable, `kansoku-lake`, and obtain a governed data
product that any DuckLake-capable consumer attaches read-only:

- `events_v1` holds closed UTC days per account: deduplicated canonical facts in the ADR-18
  analytical projection shape, identity resolved as of publication, enrichment preserved,
  erasure-clean, with one DuckLake snapshot per published partition.
- `events_recent_v1` holds a rolling provisional window appended by micro-batches every few
  minutes, so consumers that tolerate duplicates and provisional identity see events within a
  stated freshness objective. Partitions leave this dataset once their day closes.
- Erasure, applied retention and identity reclassification propagate into the lake, and
  snapshot expiry makes erased rows unreachable through time travel. The lake has a lifecycle
  owner: Kansoku.
- Freshness is measured and exported through the existing Prometheus surface, not promised.
- A structured data-product contract records identity, owner, catalog and storage location,
  datasets and schemas, evolution policy, freshness objective, classification, consumers,
  quality checks, lifecycle and executable evidence, in the vocabulary data-mesh governance
  uses, without binding Kansoku to any one organisation's platform.

The design is generic. The catalog may be PostgreSQL (recommended; Kansoku already requires
one), SQLite or a DuckDB file for small installations, or MySQL. The data path may be S3 or
any S3-compatible store, Google Cloud Storage, Azure Blob Storage, or a local filesystem for
development and acceptance. The publisher reads ClickHouse over the native protocol it already
uses and writes the Parquet itself; ClickHouse's own storage table functions remain a measured
fallback. DuckDB commits to the catalog. No vendor is assumed by defaults or by documentation
examples. Concrete adopters exist and inform requirements: the TAN platform's
data-mesh standard (`mori://tan/tan-platform`, project path
`docs/architecture/standards/data-mesh.md`; artifact-level URI pending) requires every service
to own a discoverable DuckLake-backed product with exactly the contract fields above, and the
Kikan portfolio's deferred mesh connector
(`mori://shinzui/kawa/plans/10-data-mesh-connector-deferred-build`, designed in
`mori://shinzui/kikan/plans/15-data-mesh-ingestion-ducklake-duckdb-and-parquet-on-gcs-as-a-source`)
consumes DuckLake tables through the snapshot change feed. They are examples the acceptance
must satisfy, not the design authority; the data product must be equally usable from a
laptop running the DuckDB CLI against a SQLite catalog and a MinIO bucket. The Mori registry does
not yet resolve the two plan URIs above; the registered projects and files were verified directly.

Micro-batching is the accepted freshness model. The initiative delivers minutes, not seconds;
second-level reaction belongs to an integration event stream and is a separate initiative.

Excluded from this initiative: a ClickHouse-native DuckLake catalog, which does not exist in
the qualified ClickHouse cohort; Iceberg or Delta Lake targets, although the publisher keeps
Parquet export and catalog commit as separable steps so another table format can be added
later; a Kafka or other stream publisher; per-account catalogs or any multi-tenant lake
authorization beyond the `account_id` partition of a trusted single-tenant deployment, as in
ADR-18; hosted-service specific features; and a machine-checkable data-product profile, which
is pending upstream in `mori://shinzui/okf-profiles/okf/improvement-requests/concepts/IR-3`
and adopted when released. Publishing internal rollups, identity evidence, sketches or raw
storage relations remains out of scope; they are not stable interfaces.

## External Dependencies

- **DuckLake and DuckDB.** The DuckLake specification and its DuckDB reference implementation
  are at version 1.1, shipped with DuckDB 2.0, and provide the catalog, the snapshot change
  feed, zero-copy registration of existing Parquet files with name mapping, data inlining for
  small inserts, and the flush, merge, expire and cleanup maintenance operations this design
  relies on. EP-54 pins exact versions after checking upstream releases, since the local
  corpus may lag, and proves that the `ducklake`, `httpfs`, `azure` and the catalog driver
  extensions are available inside the Nix closure and the image. No guessed package is
  approved here.
- **DuckDB access from Haskell.** `mori://Tritlo/duckdb-haskell` (packages `duckdb-ffi`,
  `duckdb-simple`) is tested against DuckDB 1.5.0. The publisher drives the `duckdb` CLI as a
  subprocess first, as Kikan's fixture harness did, and adopts the FFI bindings only after a
  recorded compatibility proof against the pinned DuckDB 2.0 release.
- **Haskell Parquet writer.** `wireform-parquet`
  (<https://github.com/iand675/wireform-/tree/main/wireform-parquet>, BSD-3-Clause, GHC 9.10 or
  later) is the preferred writer for the staging files. Its owner reports it as release-grade
  and the README development caution as outdated. As of 2026-11-03 the sibling
  `wireform-proto` 0.1.0.0 is on Hackage while the Parquet package and its monorepo
  dependencies (`wireform-core`, `wireform-columnar-core`, `wireform-arrow`, `wireform-derive`,
  `wireform-thrift`) are expected this week. EP-54 pins an exact released cohort, or
  an immutable upstream source commit as
  [ADR-22](../adr/0022-explicit-clickhouse-migrations-and-persistent-administrative-sessions.md)
  did for `clickhouse-migrate`, after checking Hackage and upstream tags; it never builds
  against a moving branch. Snappy and Zstandard are Cabal flags on by default; LZ4 binds to the
  system library and needs Nix packaging. Logical-type coverage (UTC millisecond timestamps,
  UTF8 strings, JSON), column statistics, row-group sizing and streaming output are not
  documented in the README and are EP-54's first measurements.
- **ClickHouse export fallback.** Parquet export through the `s3`, `gcs`, `azureBlobStorage`
  and `file` table functions with named collections and partitioned writes, on the qualified
  cohort of ADR-22 and
  [ADR-23](../adr/0023-verified-tls-for-native-clickhouse-connections.md). It requires the
  ClickHouse server to hold object-store credentials and network egress, and the Parquet
  representation of its native JSON type is unverified. EP-54 keeps it as the
  fallback if the Haskell writer's measured throughput or type coverage falls short. Other
  ClickHouse versions are documented compatibility, not qualified.
- **Owned acceptance stores.** Under
  [ADR-10](../adr/0010-owned-executable-acceptance-environments.md), the deterministic gate uses
  a file-backed catalog and a local data path; the realistic gate uses an owned PostgreSQL
  catalog and an owned S3-compatible object-store process. Selection and pinning of that
  emulator is EP-54 work with a recorded hash, in the manner of
  `docs/examples/consumer-versions.json`.
- **Packaging.** [ADR-24](../adr/0024-package-tan-images-from-the-source-flake.md) builds the
  image from the source flake with all executables; EP-54 adds `kansoku-lake`, its
  DuckDB runtime and the Parquet writer's native codec libraries to that closure without
  changing the entrypoint or deployment acceptance.

## Decomposition Strategy

Four children, delivered in order. The closed dataset is the governed product and must exist
before provisional data has anywhere to be reconciled; erasure propagation needs both datasets
and the maintenance operations; typed datasets are additive on top of a proven publisher.

**EP-54 (LAKE-FOUNDATION) — Publish closed-day events to a DuckLake catalog with a data-product contract.**
Owns the ADR, the structured contract document, configuration, the catalog and storage
abstraction, the arrival-bounded lake projection and the arrival-time index migration, the
PostgreSQL publication journal, the `kansoku-lake` executable with `close-day`, `republish`
and `status`, the fenced read-stage-commit mechanism and the writer spike that selects it,
packaging, the capability, terminology and guide records, and the two-tier conformance gate. At its end the
closed dataset is declared and confirmed by an observed refresh and query.

**EP-55 (LAKE-RECENT) — Micro-batch a provisional recent dataset with maintenance and freshness telemetry.**
Owns `publish-recent` and `maintain`, the arrival watermark, the recent dataset's semantics
and partition drops, DuckLake inlining and compaction policy, snapshot retention, the
publish-lag metrics and readiness interaction, and the consumer guidance on provisional data
and the change-feed window.

**EP-56 (LAKE-LIFECYCLE) — Propagate erasure, retention and identity re-resolution to the lake.** Owns dirty
partition recording inside the existing administrative jobs, partition rewrite in both
datasets, snapshot expiry and file cleanup after erasure, applied-retention partition drops,
the trailing re-resolution window, administration guide updates and the amendments to ADRs
16, 17 and 18 that give exports a lifecycle owner.

**EP-57 (LAKE-TYPED) — Derive typed event datasets from the versioned schema registry.** Owns per-event
family datasets generated from the same typed contracts that produce OpenAPI and the event
schema catalog, their evolution and compatibility policy, and a consumer example. The
Kansoku-written staging file lets typed columns come straight from the registry's declared
types without extra ClickHouse projections. It is last, additive, and may be rescoped or
cancelled if no adopter needs typed columns before release.

Relevant accepted decisions were read: ADRs
[1](../adr/0001-sdk-grade-ingest-contract-boundaries.md),
[4](../adr/0004-queryable-event-properties-and-identity-resolved-projection.md),
[5](../adr/0005-evidence-based-multi-signal-identity-resolution.md),
[7](../adr/0007-versioned-event-schema-governance-and-publication.md),
[10](../adr/0010-owned-executable-acceptance-environments.md),
[16](../adr/0016-governed-current-user-traits-and-replay-safe-erasure.md),
[17](../adr/0017-fenced-resumable-administration-and-applied-retention.md),
[18](../adr/0018-stable-reader-sql-and-real-consumer-conformance.md),
[22](../adr/0022-explicit-clickhouse-migrations-and-persistent-administrative-sessions.md),
[23](../adr/0023-verified-tls-for-native-clickhouse-connections.md) and
[24](../adr/0024-package-tan-images-from-the-source-flake.md). EP-54 records the new accepted
decision as the next ADR; EP-56 amends the affected accepted ADRs rather than restating them.

## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 54 | Publish closed-day events to a DuckLake catalog with a data-product contract | docs/plans/54-publish-closed-day-events-to-a-ducklake-catalog-with-a-data-product-contract.md | None | None | Not Started |
| 55 | Micro-batch a provisional recent dataset with maintenance and freshness telemetry | docs/plans/55-micro-batch-a-provisional-recent-dataset-with-maintenance-and-freshness-telemetry.md | EP-54 | None | Not Started |
| 56 | Propagate erasure, retention and identity re-resolution to the lake | docs/plans/56-propagate-erasure-retention-and-identity-re-resolution-to-the-lake.md | EP-54; EP-55 | None | Not Started |
| 57 | Derive typed event datasets from the versioned schema registry | docs/plans/57-derive-typed-event-datasets-from-the-versioned-schema-registry.md | EP-54 | EP-56 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled. Hard and soft dependencies
reference rows by their EP number. Numbers 54 to 57 are the next unclaimed ExecPlan numbers
after MasterPlan 7's children 50 to 53, and the paths are reserved: create each child at its
reserved path, never through a file-counting allocator, so these numbers stay correct. The
workstream aliases LAKE-FOUNDATION, LAKE-RECENT, LAKE-LIFECYCLE and LAKE-TYPED name the same
rows in the Decomposition Strategy.

## Dependency Graph

The sequence is EP-54 → EP-55 → EP-56 → EP-57 and is the only valid topological order for
the hard dependencies. EP-57 may begin once EP-54 is Complete, but its acceptance against
erasure must wait for EP-56, hence the soft dependency. No cycle exists with the
administrative executable: EP-56 extends the existing erasure and retention jobs to record
dirty partitions and calls the EP-54 publisher; the publisher never calls back into those
jobs. No cycle exists with migrations: EP-54 takes the next unclaimed ClickHouse migration
number under the ADR-22 session, and later children add PostgreSQL journal migrations only.

## Integration Points

**Lake projection and arrival index — EP-54 owner.** Add a parameterized ClickHouse view that
takes an account and half-open `received_at` bounds and delegates to the same conservative
resolver as `analytics.events_analytics_v1`, returning that projection's columns plus
`received_at`. The current analytical view accepts only occurred-at bounds and cannot drive an
arrival watermark. Add a minmax skipping index on `received_at` to the canonical events table,
which has none today, so a two-minute arrival window does not scan the active month
partition. Both changes are one ClickHouse migration applied through `kansoku-ch-migrate` in a
persistent maintenance session. The view uses SQL SECURITY DEFINER with the migration operator
as definer, as ADR-18 requires. The publisher authenticates with its own ClickHouse identity;
the `kansoku_reader` role's result and time bounds are consumer limits and never apply to
publication.

**Publisher executable and configuration — EP-54 owner, EP-55 and EP-56 extend.** `kansoku-lake`
ships in the `kansoku-server` package beside the existing executables and reads the shared
configuration. New `KANSOKU_LAKE_*` settings name the DuckLake catalog connection, the data
path, the local staging directory, and in later children the cycle interval, grace, recent
window and snapshot retention; a ClickHouse named collection and an object-store staging
prefix exist only when the fallback export is selected. Secrets are never command-line
arguments; object-store and catalog credentials are supplied through the environment or
operator files and become DuckDB secrets at run time. Catalog and data path are URIs; the
same code path serves PostgreSQL, SQLite, DuckDB-file and MySQL catalogs, and S3-compatible,
GCS, Azure and local-filesystem data paths. The configuration guide documents every setting
with one example per store family; no example privileges a vendor.

**Export mechanism — EP-54 owner, EP-55 extends.** The publisher reads each
publication unit from the lake projection over the native protocol, streaming blocks through
the typed row decoding Kansoku already uses, and writes a Parquet staging file itself with the
Haskell writer. Kansoku therefore controls the dataset schema at the source: UTC millisecond
timestamps, UTF8 strings, a JSON-typed `properties_json`, explicit nullability, row-group
sizing and Zstandard compression, independent of the ClickHouse version and with no
object-store credentials or network egress on the ClickHouse server. DuckDB then inserts from
the staged file into the target dataset, `events_v1` for a closed day and `events_recent_v1`
for a micro-batch, so DuckLake owns every data file, assigns field identifiers, writes
statistics and inlines small batches; one code path serves every store family because
DuckDB's `httpfs` and `azure` extensions own the data path. Staged files are deleted after the
commit. Zero-copy registration of very large closed-day files is a later optimization with a
measured trigger, since it needs the publisher to upload to the data path itself. The
ClickHouse table-function export is the fallback: EP-54's first milestone measures
the Haskell writer on a ten-million-event day for throughput, memory, DuckDB readability and
type fidelity, and selects the mechanism on that evidence before the dataset schema is frozen.

**Publication journal and watermark — EP-54 owner, EP-55 and EP-56 extend.** PostgreSQL is the
authoritative journal, in the `kansoku` schema beside the retention policy and dispositions:
publications (dataset, account, partition date, DuckLake snapshot identifier, staged file
digest, published time, state), arrival watermarks per dataset, and dirty partitions. A
watermark or publication row advances only after the DuckLake commit succeeds. A crash
re-exports the same unit; the closed-day publication reconciles any duplicate created by the
provisional tier. No cross-store transaction is claimed; the journal and DuckLake snapshots
are reconciled on resume by comparing recorded snapshot identifiers with the catalog.

**Maintenance fence — EP-54 owner.** Each publication unit holds the shared session lock that
ADR-17 gives every writer insert, and refuses to start while an ADR-22 migration session is
open. The publisher therefore pauses during erasure and retention jobs and can never publish
rows in the middle of a scrub. ADR-18 could not offer this to direct SQL readers; a
Kansoku-owned publisher can, and that is the reason the publisher is part of Kansoku rather
than an external pull.

**Recent dataset semantics — EP-55 owner.** `events_recent_v1` is append-only per cycle,
partitioned by account and occurred date, and bounded to a rolling window, forty-eight hours
by default. An event may appear more than once across cycles because the writer is
at-least-once and arrival windows are disjoint but retries are not; `canonical_user` may still
be anonymous when later evidence binds it. Consumers dedupe on `event_id` or read `events_v1`.
Partitions whose day has closed are deleted from the recent dataset in the same transaction
that publishes them to the closed dataset. The default cycle is 120 seconds with a 90-second
grace behind the current time; with the writer's five-second maximum flush latency the
end-to-end budget is about four minutes, stated as the freshness objective and measured.

**Maintenance and snapshot retention — EP-55 owner.** After each closed-day publication and
on demand through `maintain`, flush inlined data, merge adjacent files, expire snapshots
older than the configured retention, seven days by default, and clean up orphaned files.
Consumers reading the snapshot change feed must stay within that retention; the guide says
so, and the publication journal exposes the oldest retained snapshot through `status`.

**Freshness telemetry — EP-55 owner.** Export the publish lag, the last successful
publication time per dataset, the number of dirty partitions and the oldest retained
snapshot through the existing Prometheus registry. Readiness is not coupled to lake
publication; a lake outage degrades the data product and is visible, but never fails ingest
or metric reads.

**Erasure, retention and re-resolution — EP-56 owner.** Identity unlinking, explicit-fact
deletion and `apply-retention` record the affected dataset partitions as dirty inside their
own PostgreSQL transaction, after discovery and before completion, so a job that fails or
resumes cannot lose the obligation. The publisher rewrites dirty partitions: replace in
`events_v1`, delete and re-append in `events_recent_v1`. After an erasure rewrite it expires
every snapshot older than the rewrite commit and cleans files, so time travel cannot reach
erased rows; this deliberately shortens consumers' change-feed window and is documented.
Applied retention drops partitions older than the applied cutoff. A trailing window, seven
days by default, is rewritten nightly to absorb identity reclassification, and `republish`
rewrites any range on demand. ADRs 16, 17 and 18 are amended to state that the lake is a
Kansoku-owned export with these guarantees; external copies of the lake remain the
consumer's responsibility.

**Data-product contract — EP-54 owner, EP-55, EP-56 and EP-57 extend.** One structured Markdown
document with stable sections: product identity and owner, catalog and storage location,
datasets and schemas, evolution and compatibility policy, freshness objective, classification
and access policy, consumers, quality checks, lifecycle, evidence and runbook. It uses the
vocabulary data-mesh governance expects and cites Kansoku's own capability, terminology and
guide records. When `mori://shinzui/okf-profiles` releases a Data Product profile, the
document migrates to it; until then the Markdown form is the contract. Deployment-specific
values such as bucket names and catalog hosts belong to the adopter, never to this document.

**Capability, terminology and guide records — EP-54 owner, EP-55, EP-56 and EP-57 extend.** Add the
next capability record for lake publication with evidence, terminology for data product,
closed dataset, provisional dataset and publication snapshot, and a guide for publishing and
consuming the lake, including examples for the DuckDB CLI, a PostgreSQL catalog and each
supported store family. `just capabilities-check`, `just terminology-check` and
`just guides-check` remain green under the pinned OKF profiles.

**Acceptance — every child, ADR-10 owner.** Mutating tests use owned environments only. The
deterministic gate runs the Nix executable against an owned ClickHouse and PostgreSQL, a
file-backed DuckLake catalog and a local data path. The realistic gate adds an owned
PostgreSQL catalog and an owned S3-compatible object-store process with recorded version and
hash. Conformance attaches the catalog from an unmodified DuckDB CLI, runs the daily-users
recipe over `events_v1`, and compares it with the HTTP metric and the ADR-18 reader recipe,
before and after an erasure and a retention job. EP-55 adds a measured freshness proof; EP-56
adds a snapshot-expiry proof that erased rows are unreachable at every retained snapshot. A
mesh-style consumer proof reads the snapshot change feed exactly as Kikan's fixture harness
does. Successful compilation or skipped native cases are never acceptance.

**Typed datasets — EP-57 owner.** One dataset per event family whose declared schema versions
map properties to typed columns, generated from the same typed contracts as OpenAPI and the
event schema catalog of ADR-7 so the three cannot drift. Additive columns within a major
schema version evolve in place; a new major version is a new dataset name. The generic
`events_v1` and `events_recent_v1` remain the complete record; typed datasets are derived
views of the same closed partitions and inherit their lifecycle through EP-56.

## Progress

Not started. The MasterPlan was authored on 2026-11-03 after the design discussion recorded in
the Decision Log and revised the same day for child numbering and for the Haskell Parquet
writer. EP-54 is the next plan to author; its first milestone is the proof set in
Surprises & Discoveries below, led by the writer spike, because the dataset schema cannot be
frozen before those measurements exist.

## Surprises & Discoveries

Planning-time findings on 2026-11-03, each with the child that must resolve it:

- ClickHouse's data-lake catalog engine supports Glue, Unity, Hive Metastore, Iceberg REST and
  OneLake catalogs, not DuckLake. A ClickHouse-native commit path is not available; the
  export-then-commit design is a necessity, not a preference. (Scope)
- DuckLake 1.1 ships with DuckDB 2.0, while the Haskell bindings in the local corpus are
  tested against DuckDB 1.5.0. The CLI subprocess path is the de-risked default. (EP-54)
- The canonical events table is ordered by account, event name, occurred time and event
  identifier, partitioned by month, and has no skipping index on arrival time. An arrival
  watermark needs the index. (EP-54)
- The analytical reader view takes occurred-at bounds only and does not expose `received_at`;
  a new parameterized projection is required. (EP-54)
- The `kansoku_reader` profile caps results at ten thousand rows and thirty seconds. It is
  the right consumer boundary and the wrong publisher identity. (EP-54)
- DuckLake's zero-copy registration transfers file ownership and relies on name mapping for
  files without field identifiers; staged paths must be unique and never reused. (EP-54)
- The Parquet type ClickHouse emits for its native JSON column is not documented clearly
  enough to freeze a dataset schema. Writing the staging file in Kansoku removes the question
  from the primary path; it must still be measured for the fallback. (EP-54)
- A Haskell Parquet writer, `wireform-parquet`, reaches release this week. Its README still
  carries an outdated development caution and does not document logical types, statistics or
  row-group controls, and a May 2026 commit recorded writes five times slower than pyarrow
  before later performance work. Its monorepo cohort is not yet on Hackage. The owner reports
  it as release-grade; the plan treats that as a lead to measure, not a result.
  (EP-54)
- Lakehouse loading guidance discourages file loads more often than once a minute; DuckLake's
  catalog inlining relaxes that, but no published commit-rate figure exists, so the cycle
  interval is settled by measuring catalog growth, not assumed. (EP-55)

## Decision Log

On 2026-11-03 replace uncreated child IDs and paths with stable workstream names. Rationale:
the initializer allocates ExecPlan IDs from existing files, so reserving absent files allowed
another initiative to receive the same IDs. Scope and dependency order remain unchanged;
assign actual child IDs only when their documents are created.

On 2026-11-03, superseding the entry above, restore numeric child identifiers as EP-54 to EP-57
with reserved paths and keep the workstream names as aliases. Rationale: mina's registry parser
accepts only numeric identifiers with paths, so name-only rows removed the registry, dependency
graph and critical path from every view; 54 to 57 are unclaimed now that MasterPlan 7 holds 50
to 53; and the collision came from an allocator that counts files, so children are created at
their reserved paths rather than allocated.

On 2026-11-03 frame the initiative as a generic open-source lakehouse capability. Rationale:
Kansoku has many potential adopters with DuckLake or DuckDB lakehouses and the same need; the
TAN data-mesh standard and the Kikan mesh connector are concrete adopters whose requirements
the acceptance must satisfy, but the configuration, defaults and documentation must not assume
one organisation's cloud, catalog or governance tooling.

On 2026-11-03 accept micro-batching as the freshness model and exclude a stream publisher.
Rationale: DuckLake can deliver minutes with full governance through snapshots; seconds
require an integration event stream from an acceptance-time outbox, which is a different
contract with different erasure semantics and belongs to its own initiative.

On 2026-11-03 publish two datasets, a provisional recent dataset and a closed-day dataset,
rather than one table with in-place corrections. Rationale: the contract stays honest about
duplicates and provisional identity, the closed dataset receives one snapshot per partition,
and change-feed consumers are not flooded by nightly rewrites.

On 2026-11-03 publish the ADR-18 analytical projection shape, not raw storage relations.
Rationale: base tables, identity evidence and sketches are not stable interfaces; the reader
projection already carries the resolved subject, enrichment and bot flag consumers need.

On 2026-11-03 make the publisher a Kansoku-owned fenced job and give Kansoku its own catalog
rather than writing into a shared one. Rationale: only a Kansoku process can hold the ADR-17
shared session lock and propagate erasure; DuckLake producers write the catalog directly, so a
shared catalog would mean cross-service writes; lakehouse governance expects the product to
declare its own catalog and storage location, and DuckDB consumers attach several catalogs.

On 2026-11-03 let ClickHouse write Parquet and DuckDB commit, with zero-copy registration for
closed days and DuckDB inserts for micro-batches. Rationale: ClickHouse is the right engine
for the scan and the Haskell process should not stream rows; DuckDB owning the small files
gives field identifiers, statistics and inlining for free.

On 2026-11-03, revising the export decision above after learning that a Haskell Parquet writer
is about to be released, prefer a staging file written by Kansoku from native ClickHouse reads,
with DuckDB inserting it into DuckLake for both tiers, and keep the ClickHouse table-function
export as the measured fallback. Rationale: Kansoku controls the Parquet schema and types,
including the JSON column and timestamps; the ClickHouse server needs no object-store
credentials, egress or named-collection configuration, which matters for open-source adopters
on unqualified ClickHouse versions; DuckDB owning every data file removes the field-identifier
and name-mapping dependency; and typed datasets can be produced from the registry directly.
The cost is that rows flow through the publisher, so the choice is confirmed by measurement in
EP-54 before the dataset schema is frozen.

On 2026-11-03 freeze identity as of publication and rewrite a trailing window nightly.
Rationale: query-time resolution can reclassify retained history without bound; a bounded
rewrite plus on-demand republish is the honest, affordable approximation and is stated in the
contract.

On 2026-11-03 keep `properties_json` as a JSON string column in version 1 and derive typed
datasets later from the versioned registry. Rationale: the generic dataset must be complete
and stable first; typed columns are additive and should come from the governed contracts, not
from inference over stored rows.

## Outcomes & Retrospective

Pending. Record here, when the children complete: the pinned DuckDB, DuckLake, Parquet-writer
and emulator versions; the selected export mechanism with its measured throughput and memory;
the measured Parquet type of the JSON column on the fallback; the measured freshness distribution
and catalog growth at the default cycle; the erasure-to-unreachable latency; which store
families and catalogs were proven in owned environments versus documented as compatibility;
and whether EP-57 shipped, was rescoped or was cancelled, with the adopter evidence behind
that choice.
