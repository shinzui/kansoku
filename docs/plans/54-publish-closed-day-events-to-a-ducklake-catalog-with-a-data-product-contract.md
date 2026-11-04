---
id: 54
slug: publish-closed-day-events-to-a-ducklake-catalog-with-a-data-product-contract
title: "Publish closed-day events to a DuckLake catalog with a data-product contract"
kind: exec-plan
created_at: 2026-11-04T13:38:48Z
intention: "intention_01m6gzmpyde2nr3ywy1d2vhbn9"
master_plan: "docs/masterplans/6-publish-kansoku-analytics-as-a-ducklake-lakehouse-data-product.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-11-04T13:38:48Z
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-11-04T13:59:42Z
      mode: "update"
      note: "Use RustFS from the pinned nixpkgs as the realistic-gate object store, with garage as the recorded fallback, replacing MinIO at the owner's request."
---

# Publish closed-day events to a DuckLake catalog with a data-product contract

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.
Record friction met while implementing in the friction-log bundle as it occurs (see FRICTION.md).

This is the first child of
[MasterPlan 6](../masterplans/6-publish-kansoku-analytics-as-a-ducklake-lakehouse-data-product.md),
workstream alias LAKE-FOUNDATION. It has no hard dependency on another child. EP-55, EP-56 and
EP-57 build on the journal relations, the projection parameters, the DuckDB driver and the
fence helpers this plan creates, so their names and shapes are part of this plan's acceptance.


## Purpose / Big Picture

Today Kansoku's analytical facts can be read only through the HTTP metrics API or, for a
trusted operator, through the constrained ClickHouse reader views. An adopter who runs a
lakehouse, meaning Parquet files on object storage described by a table format and queried
with DuckDB, dbt, notebooks or BI tools, has to hand-roll an export and receives no deletion or
retention promise for the copy.

After this plan, an operator sets a handful of `KANSOKU_LAKE_*` environment variables naming a
DuckLake catalog and an object-store data path, runs the new executable `kansoku-lake close-day`
after a UTC day has closed, and every account's events for that day appear as one DuckLake
snapshot in a table named `events_v1`. Any DuckDB, from a laptop CLI to a scheduled connector,
attaches the catalog read-only and queries the day with plain SQL; the daily-users recipe over
`events_v1` returns the same numbers as the HTTP metric and as the ClickHouse reader recipe.
The same command can be run again without creating a duplicate, `kansoku-lake republish`
rewrites a day on demand, and `kansoku-lake status` reports what has been published. The
publication never makes ingest or metric reads slower than a measured budget, never holds the
maintenance traffic lock longer than a measured ceiling, and never publishes rows from the
middle of an erasure. A structured data-product contract, a capability record, terminology,
a guide and an architecture decision record describe the product in the vocabulary lakehouse
governance expects without naming any vendor.

Success is observable: `just lake-bench` prints a report whose every budget is met or
explicitly re-based on the ten-million-event fixture; `just acceptance` runs the deterministic
lake gate against a file catalog and a local data path; `just lake-realistic-acceptance` runs
the same scenarios against an owned PostgreSQL catalog and an owned S3-compatible object store,
attaches from both the pinned DuckDB and the oldest supported consumer release, and reads the
publication through the snapshot change feed exactly as Kikan's mesh connector does.


## Progress

- [ ] M1: Writer spike and read-side baseline. The three export candidates are measured on the
  ten-million-event fixture; the mechanism, the writer pin and the frozen dataset schema are
  recorded in the Decision Log with the report path.
- [ ] M2: ClickHouse migration 0026 adds the arrival-time index (materialized in every
  partition) and the arrival-bounded lake projection; the packaged migration CLI applies it on
  an owned server, the frozen reader views keep byte-identical parity, and the publisher role
  and settings profile exist.
- [ ] M3: PostgreSQL migration 0008 creates the publication journal; `kansoku-lake status`
  attaches a DuckDB-file catalog and a PostgreSQL catalog from configuration, creates
  `events_v1` with its partitioning and options, and never places a secret in a command line.
- [ ] M4: `kansoku-lake close-day` publishes a seeded closed day as exactly one snapshot through
  sliced, fenced reads; `republish` replaces it; crash, resume, concurrent-publisher and
  maintenance-job interleavings behave as specified under owned stores.
- [ ] M5: The pinned DuckDB CLI and its extensions are in the Nix closure for the developer
  shell and the Linux image; the image carries `kansoku-lake` as its fifth executable and the
  smoke test proves the 26-migration plan and offline extension loading.
- [ ] M6: `just lake-bench` measures every EP-54 budget on the ten-million-event fixture and
  writes a report; proposed figures are confirmed or re-based with reasons.
- [ ] M7: The two-tier conformance gate passes: deterministic lake scenarios inside
  `just acceptance`, and `just lake-realistic-acceptance` with a PostgreSQL catalog, an owned
  object-store emulator, the floor DuckDB release and the change-feed consumer proof, before
  and after an erasure and a retention job.
- [ ] M8: ADR-25, the data-product contract, CAP-20, the new terms, the publishing guide and
  the configuration and operations guide sections exist and pass their profile checks; the
  MasterPlan registry marks EP-54 Complete.


## Surprises & Discoveries

Planning-time findings on 2026-11-04, verified against the working tree and upstream:

- `wireform-parquet` is not on Hackage and has no release tag. Hackage lists only
  `wireform-core` 0.2.0.1, `wireform-derive` 0.2.0.0 and `wireform-proto` 0.2.0.0; the
  monorepo `main` was at commit `768b31ad08a7728dcc60b6eace4e00e403ef833e`. If M1 selects it,
  the pin is an immutable commit as a `source-repository-package` with subdirectories, as the
  repository already does for `clickhouse-migrate`. `dataframe-parquet` 1.5.1.0 is a released
  pure-Haskell Parquet writer on Hackage and is the second measured candidate.
- The pinned nixpkgs (`d5dfd8e6716dde34398bc14bc87c10dece9c8c68`) carries DuckDB 1.5.5, not
  2.0. The producer's DuckDB 2.0.0 CLI must be fetched as a hash-verified official release
  artifact, the way `nix/clickhouse-qualified.nix` fetches ClickHouse. The nixpkgs DuckDB 1.5.5
  is useful as the floor consumer release in conformance.
- DuckLake extension 2.0 (spec 1.1) shipped with DuckDB 2.0.0 on 2026-10-21. New catalogs
  default to spec 1.1; `DUCKLAKE_VERSION '1.0'` at `ATTACH` creates a 1.0 catalog, and the
  extension keeps reading and writing 1.0 catalogs. Kikan's connector runs DuckDB 1.5.4 with
  extension 1.0, which reads spec 1.0 only, so the catalog is created at 1.0 by default.
- `scripts/identity_acceptance.py` calls `analytics.events_resolved_internal` directly with
  its four named parameters. Adding arrival bounds to that view therefore requires updating
  that script and the two frozen views that delegate to it in the same change.
- The vendored ClickHaskell `select` hands each block to a callback and keeps only what the
  callback returns, but every existing caller concatenates the blocks; the publisher needs a
  new streaming consumer. The driver declares no decoder for the native `JSON` type, so the
  projection serializes `properties_json` to a string.


## Decision Log

- Decision: Create DuckLake catalogs at specification version 1.0 by default, configurable
  through `KANSOKU_LAKE_DUCKLAKE_VERSION`, and prove the floor by attaching from DuckDB 1.5.x.
  Rationale: the only concrete mesh consumer today reads spec 1.0; nothing in this plan needs a
  1.1 feature; a catalog can be migrated forward later and never backward.
  Date: 2026-11-04
- Decision: Place the lake modules and the Parquet writer dependency in `kansoku-server`, not
  `kansoku-core`.
  Rationale: `kansoku-core` is linked into every executable and the HTTP server; the writer
  pin and DuckDB driver belong only to `kansoku-lake`, as the migration toolkit belongs only to
  `kansoku-ch-migrate`.
  Date: 2026-11-04
- Decision: Generalize `analytics.events_resolved_internal` with arrival bounds and a derived
  evidence-day set, and recreate the frozen views to pass wide bounds, rather than copying the
  resolver into a second view.
  Rationale: the MasterPlan requires one conservative resolver; a copy would drift. Parity of
  the frozen views is proven by the existing reader and migration acceptance.
  Date: 2026-11-04
- Decision: Keep every string column `NOT NULL` with the empty string meaning absent, as the
  ClickHouse projection does, and publish `properties_json` as a JSON-text string column.
  Rationale: consumers comparing the lake with the reader recipes get identical predicates;
  typed columns arrive in EP-57 from the schema registry.
  Date: 2026-11-04
- Decision: `kansoku-lake` registers its Prometheus series and writes their values into the
  journal row and the JSON receipt; serving the registry over HTTP arrives with the long-running
  `publish-recent` loop in EP-55.
  Rationale: this plan's commands are one-shot and cannot be scraped; the values must still be
  recorded so M6 can measure them.
  Date: 2026-11-04
- Decision: Use RustFS as the owned S3-compatible object store for the realistic gate, with
  garage as the recorded fallback; MinIO is not used.
  Rationale: the owner asked for RustFS; it is Apache-2.0, present in the pinned nixpkgs for
  both acceptance platforms, and upstream reached a general-availability release in September
  2026, whereas MinIO's community distribution has been shrinking. The pinned package is a
  release candidate, so the matrix records it as such until a verified GA override lands.
  Date: 2026-11-04


## Outcomes & Retrospective

(To be filled during and after implementation. Record the pinned DuckDB, DuckLake extension,
writer and emulator versions; the selected export mechanism with measured throughput and peak
resident memory; the Parquet types DuckDB reads for the JSON and timestamp columns; every
budget's proposed and measured value; and the friction entries recorded under this plan with
their triage outcome.)


## Context and Orientation

### What exists today

Kansoku is a Haskell analytics service in four Cabal packages. `kansoku-core` holds the
application library: configuration in `kansoku-core/src/Kansoku/Config.hs`, ClickHouse
connections in `kansoku-core/src/Kansoku/ClickHouse.hs`, typed row decoding in
`kansoku-core/src/Kansoku/ClickHouse/EventRow.hs`, the maintenance fence in
`kansoku-core/src/Kansoku/Maintenance.hs` and `kansoku-core/src/Kansoku/Admin/`, the
PostgreSQL migration plan in `kansoku-core/src/Kansoku/Migrations.hs`, and Prometheus metrics
in `kansoku-core/src/Kansoku/Observability.hs`. `kansoku-server` holds the executables under
`kansoku-server/app/` (`kansoku-server`, `kansoku-migrate`, `kansoku-admin`,
`kansoku-ch-migrate`) and the embedded ClickHouse migration component under
`kansoku-server/migrations/clickhouse/`. The vendored ClickHouse driver is
`vendor/ClickHaskell` (see `vendor/ClickHaskell/KANSOKU.md`). Nix wiring lives in
`flake.module.nix`, `nix/clickhouse-qualified.nix` and `nix/kansoku-image.nix`; recipes live in
`justfile`; acceptance harnesses are Python scripts under `scripts/`.

Events arrive over HTTP, wait in a PostgreSQL queue (pgmq, a queue implemented as PostgreSQL
tables), and a writer inserts them in batches into the ClickHouse table
`analytics.events_raw`. That table is a `ReplacingMergeTree(received_at)` partitioned by
`toYYYYMM(occurred_at)` and ordered by `(account_id, event_name, occurred_at, event_id)`
(see `db/clickhouse/migrations/0004_events_raw_v2.sql`). Duplicates of one `event_id` are
removed at read time by the `FINAL` modifier through the view `analytics.events_canonical`.
There is no data-skipping index on `received_at`, the arrival time.

Identity is resolved at query time by the parameterized view
`analytics.events_resolved_internal` (defined in
`db/clickhouse/migrations/0018_conservative_identity_resolution.sql`). A parameterized view is
a ClickHouse view that takes named arguments in the `FROM` clause, for example
`analytics.events_analytics_v1(account='a', from_time=..., to_time=...)`. The internal view
takes `scope_all_accounts`, `scope_account`, `scope_from` and `scope_to`; it selects candidate
events by account and half-open `occurred_at` bounds, materializes the identity evidence for
those days from `analytics.identity_context_signals`, and joins the conservative binding
result to produce `canonical_user`. Two frozen reader views delegate to it:
`analytics.events_resolved_v3` and `analytics.events_analytics_v1` (defined in
`db/clickhouse/migrations/0023_stable_reader_surface.sql`). `events_analytics_v1` returns
`event_id, event_name, occurred_at, url, account_id, canonical_user, properties_json, source,
source_service, session_id, is_bot, browser_family, os_family, device_class, channel,
country_code` and is the ADR-18 analytical projection whose shape the lake publishes.
`db/clickhouse/reader-role.sql` creates the `kansoku_reader` role and the
`kansoku_reader_limits` settings profile (read-only, 30 seconds, 512 MiB, 10000 rows, four
threads); `scripts/reader_acceptance.py` proves that the recipes in `db/clickhouse/recipes/`
match the HTTP metrics. `db/clickhouse/recipes/daily-users.sql` is the recipe this plan
reproduces over the lake.

### The maintenance fence, exactly

Administrative jobs (erasure, retention, archive replay) and native migration sessions run
under a persisted fence (ADR-17, ADR-22). The fence is a row in `kansoku.maintenance_fence`
plus two PostgreSQL advisory locks: administrator lock `(726401,2)` and traffic lock
`(726401,1)`. Ordinary traffic admits itself with `pg_try_advisory_lock_shared(726401,1)` and
then checks that `active_job IS NULL AND active_migration_session IS NULL`; see
`Kansoku.Maintenance.withTraffic` (HTTP and the writer) and
`Kansoku.Admin.Store.admitMaintenanceTraffic` (administrative commands). A confirmed job
persists its fence row and then calls `pg_advisory_lock(726401,1)` in exclusive mode under
`SET statement_timeout='30s'` in `Kansoku.Admin.Coordination.trafficLock`. If shared holders
do not release within thirty seconds, that statement fails, the job fails, and the fence row
stays active until an operator resumes the job. This is the single most important constraint
on the publisher: a shared hold of a few seconds is harmless, a hold of a minute turns every
maintenance job into an operator-resumed failure. The journal of jobs is
`kansoku.maintenance_jobs`, whose `revision` column increases per job, and completed migration
sessions are rows of `kansoku.clickhouse_migration_sessions` with `completed_at` set.

### Migrations are explicit and append-only

ClickHouse schema changes are compiled into `kansoku-ch-migrate` from
`kansoku-server/migrations/clickhouse/manifest.json`, which lists migrations by name and their
step files under `kansoku-server/migrations/clickhouse/steps/<name>/statement-NN.sql`. The
plan currently has 25 migrations and 257 steps; `0025_organization_analytics` is the last.
The `original/` directory holds the retired shell-runner files as conversion evidence and is
not extended. Applying a migration requires a persistent maintenance session
(`kansoku-ch-migrate maintenance begin`, `up`, `maintenance finish`), stopped clients and
drain evidence, as `docs/guides/clickhouse-migrations.md` describes; owned acceptance applies
the plan through `scripts/native_clickhouse_migrations.py:initialize_owned` and
`scripts/isolated_clickhouse.py:apply_migrations`. The `just ch-migrate` recipe forwards
arguments to the compiled CLI; `clickhouse-migrate-embed-build` must wrap Cabal builds that
embed the manifest. The materialization policy for local mutations is `mutations_sync=1`, as
`kansoku-server/migrations/clickhouse/native-assertions/local-materialize-policy.sql` and the
converted migration 0018 show.

PostgreSQL schema changes are Haskell-embedded SQL migrations in
`kansoku-core/src/Kansoku/Migrations.hs`, numbered `0001-api-keys` through
`0007-clickhouse-administration`, applied by `kansoku-migrate`. Append `0008-lake-publication`;
never edit an applied migration's bytes.

### Configuration, executables and packaging

`Kansoku.Config.loadConfig` reads `PG_CONNECTION_STRING`, `KANSOKU_CLICKHOUSE_*`,
`CLICKHOUSE_TCP_PORT` and the rest of the service settings from the environment with typed
parsers (`parsePositiveInt`, `parseBool`, and so on). `kansoku-admin`
(`kansoku-core/src/Kansoku/Admin.hs`) shows the house style for an administrative command:
preview by default, `--confirm` for mutation, JSON on stdout, redacted messages on stderr,
exit code 1 on failure. `kansoku-ch-migrate`
(`kansoku-server/src/Kansoku/ClickHouseMigration/Command.hs`) shows `optparse-applicative`
subcommands with `--json`. The Linux image (`nix/kansoku-image.nix`, ADR-24) packages the
`kansoku-server` derivation with BusyBox, a CA bundle and `packaging/entrypoint.sh`; its smoke
test asserts four executables and a 25-migration plan, as does
`scripts/check_container_image.py`. The developer shell prepends the exact qualified
ClickHouse 26.8.28.14 artifact from `nix/clickhouse-qualified.nix`, whose record is
`db/clickhouse/qualification/matrix.json`; that file is the model for the DuckDB artifact
record this plan adds.

### Acceptance surfaces

`just check` runs deterministic tests and the OKF profile checks for `docs/adr`,
`docs/capabilities`, `docs/terminology` and `docs/guides`. `just acceptance` runs
`scripts/acceptance.py`, which owns a fresh PostgreSQL (`scripts/isolated_postgres.py`) and a
fresh ClickHouse (`scripts/isolated_clickhouse.py`, qualified artifact only, Darwin arm64 only
today), applies both migration plans, starts the packaged server and calls one `verify_*`
function per family, including `scripts/reader_acceptance.py`. `scripts/identity-bench.py`
seeds ten million events into an owned ClickHouse with `INSERT ... SELECT FROM numbers(...)`
and is the fixture model for this plan's benchmark. Owned evidence is written under
`.dev/acceptance/` with private files kept out of sanitized logs (ADR-10).

### Records

`docs/adr/` is a profile-governed OKF bundle; the next handle at planning time was `ADR-25`
(`okf id next docs/adr --profile docs/adr/profile.dhall ADR`). `docs/capabilities/` (next
`CAP-20`), `docs/terminology/` (next `TERM-80`) and `docs/guides/` (next `DOC-15`) are also
profile-governed; each has an `index.md` and a `log.md` maintained with `okf log add`.
`docs/capabilities/trusted-sql-consumption.md`, `docs/terminology/maintenance-fence.md` and
`docs/guides/consume-clickhouse.md` are the templates to follow. `docs/contracts/` holds the
generated event schema catalog and will hold the data-product contract.

### Terms used in this plan

A **DuckLake catalog** is a set of metadata tables in an ordinary database (PostgreSQL, SQLite,
a DuckDB file or MySQL) that records tables, schemas, the Parquet files that hold their rows,
per-file column statistics and **snapshots**, numbered versions of the whole catalog. The
**data path** is where the Parquet files live: an S3-compatible bucket, Google Cloud Storage,
Azure Blob Storage or a local directory. DuckDB's `ducklake` extension reads and writes
catalogs; `postgres`, `sqlite` and `mysql` extensions talk to catalog databases; `httpfs` and
`azure` talk to data paths. A **data product** is a dataset with a named owner, a contract, a
freshness objective, a lifecycle and evidence. A **closed day** is a UTC calendar day whose end
plus a grace period lies in the past. A **partition** of `events_v1` is one account and one
closed day. A **publication unit** is the work that publishes one partition. A **slice** is one
bounded ClickHouse query inside a unit, covering a range of occurred time within the day. A
**skipping index** is a ClickHouse data-skipping index; a `minmax` index stores the minimum and
maximum of a column per group of granules so a query with a range predicate can skip groups.
**Try-lock admission** means acquiring the shared traffic lock with `pg_try_advisory_lock_shared`
and failing immediately rather than waiting.

### Decisions this plan inherits

Local decisions that bind this work: [ADR-1](../adr/0001-sdk-grade-ingest-contract-boundaries.md)
keeps past occurrence times unchanged, so a closed day can receive late events;
[ADR-4](../adr/0004-queryable-event-properties-and-identity-resolved-projection.md) and
[ADR-5](../adr/0005-evidence-based-multi-signal-identity-resolution.md) define the identity
resolved projection and conservative resolution; [ADR-10](../adr/0010-owned-executable-acceptance-environments.md)
requires owned fresh stores, the actual packaged executables and nonzero non-skipping cases;
[ADR-17](../adr/0017-fenced-resumable-administration-and-applied-retention.md) defines the fence
and the shared traffic lock every writer insert holds; [ADR-18](../adr/0018-stable-reader-sql-and-real-consumer-conformance.md)
freezes the reader projections, requires `SQL SECURITY DEFINER` with the migration operator as
definer, and states that exports need their own deletion and retention; [ADR-22](../adr/0022-explicit-clickhouse-migrations-and-persistent-administrative-sessions.md)
governs how a ClickHouse migration is appended and applied; [ADR-23](../adr/0023-verified-tls-for-native-clickhouse-connections.md)
governs native TLS, which the publisher inherits from the shared connection code; and
[ADR-24](../adr/0024-package-tan-images-from-the-source-flake.md) governs the image this plan
extends. This plan records the new accepted decision as ADR-25. Cross-repository context:
the mesh connector that consumes DuckLake change feeds is designed in
`mori://shinzui/kikan` (project-relative
`docs/plans/15-data-mesh-ingestion-ducklake-duckdb-and-parquet-on-gcs-as-a-source.md` and the
fixture harness under `docs/architecture/evolution/conformance/data-mesh/`; artifact URIs
pending), the migration toolkit is `mori://shinzui/clickhouse-migrate`, the driver is
`mori://KovalevDima/ClickHaskell`, and the Haskell DuckDB bindings, not used in this plan, are
`mori://Tritlo/duckdb-haskell`.


## Plan of Work

The order matters. M1 freezes the dataset schema and selects the export mechanism before any
migration or table is created; M2 and M3 create the ClickHouse and PostgreSQL state; M4 makes
publication work; M5 packages the runtime; M6 measures; M7 proves; M8 documents. Each
milestone ends with an observable check that a contributor can run.


### M1 — Writer spike and read-side baseline

Scope: measure, do not build the product. Add a manual Cabal flag `lake-writer-spike` to
`kansoku-server/kansoku-server.cabal` and, behind it, an executable `kansoku-lake-spike` with
`kansoku-server/app/LakeSpike.hs`. The spike reads one account's ten-million-event day from
`analytics.events_analytics_v1` over the native protocol with the vendored driver's `select`,
streaming one block at a time into a writer, and produces a Parquet file under a private
directory. Three candidates are measured with identical input:

1. `wireform-parquet` from the monorepo at an immutable commit, added as a
   `source-repository-package` in `cabal.project` with the subdirectories it needs and
   mirrored in `flake.module.nix` with `fetchFromGitHub`, exactly as `clickhouse-migrate` is.
   Recheck Hackage and tags first; if a release appears, prefer it. Record the commit, the
   Cabal flags used for Snappy and Zstandard, and whether a system library is linked.
2. `dataframe-parquet` 1.5.1.0 from Hackage, pinned in `cabal.project` constraints and
   `flake.module.nix`, through its `DataFrame.IO.Parquet.Writer` module.
3. The ClickHouse fallback: the publisher issues
   `INSERT INTO FUNCTION file('<staging>.parquet', Parquet) SELECT ... FROM
   analytics.events_analytics_v1(...)` so the server writes the file itself. This measures what
   the Parquet representation of the native `JSON` column looks like and what credentials and
   egress a real object-store export would need.

For each candidate record, in a JSON report under `.dev/acceptance/lake-spike-*/report.json`:
rows per second, wall-clock, peak resident set size of the spike process sampled every second,
output bytes, whether the writer flushed row groups incrementally (resident memory flat across
the run) or buffered, and DuckDB's reading of the result: `DESCRIBE SELECT * FROM
read_parquet('<file>')` types for `occurred_at`, `received_at`, `is_bot` and `properties_json`,
and a round trip of ten sampled rows compared with the ClickHouse source. Also record the
ClickHouse-side cost of the read from `system.query_log` (`read_rows`, `read_bytes`,
`memory_usage`, duration) and a two-minute `received_at` window query before and after a
`minmax` skipping index exists, which is M2's design input.

Selection rule, in order: the writer must stream (resident memory bounded regardless of row
count); DuckDB must read millisecond UTC timestamps as timestamps with time zone, booleans as
`BOOLEAN` and the JSON string as `VARCHAR`; throughput must leave a ten-million-event day well
inside M6's wall-clock budget. If both Haskell writers fail the first rule, the ClickHouse
fallback is selected and the MasterPlan's named-collection and object-store staging settings
come into scope. Record the outcome in the Decision Log, the report path in Surprises &
Discoveries, and freeze the `events_v1` schema below. The spike flag and executable stay in the
tree, off by default, so M6 can rerun the comparison.

M1 passes when the report exists for all three candidates on a ten-million-event day, the
Decision Log names the mechanism and the exact pin, and the frozen schema is written into this
plan.


### M2 — Arrival index, lake projection and publisher identity (ClickHouse migration 0026)

Scope: one appended native migration named `0026_lake_projection`, authored as explicit
statement steps under `kansoku-server/migrations/clickhouse/steps/0026_lake_projection/` and
listed in `manifest.json` after `0025_organization_analytics`, plus one role file.

Statement one adds the index: `ALTER TABLE analytics.events_raw ADD INDEX IF NOT EXISTS
idx_received_at received_at TYPE minmax GRANULARITY 1`. Statement two materializes it for every
existing part: `ALTER TABLE analytics.events_raw MATERIALIZE INDEX idx_received_at SETTINGS
mutations_sync=1`, following the local materialization policy. Without this statement only
new parts carry the index, and an arrival-bounded query would read every unindexed historical
part in full on every cycle. Record the materialization duration per retained million events
from the owned fixture in M6 and in the migration runbook so operators can size the window.

Statement three recreates `analytics.events_resolved_internal` with two more parameters,
`scope_received_from` and `scope_received_to` (both `DateTime64(3,'UTC')`, half-open), applied
to the `candidates` selection beside the occurred bounds. Make `candidates` a `MATERIALIZED`
common table expression and derive the evidence day set from it: `candidate_signals` filters
`day IN (SELECT DISTINCT toDate(occurred_at) FROM candidates)` instead of the caller's
occurred bounds. For occurred-bounded callers the day set is unchanged, because every context
signal row comes from an event row of the same account and day; for arrival-bounded callers
it is the only correct choice, because an arrival window may contain any occurred day.
Statements four and five recreate `analytics.events_resolved_v3` and
`analytics.events_analytics_v1` with their exact current column lists, passing
`scope_received_from=toDateTime64('1970-01-01 00:00:00',3,'UTC')` and
`scope_received_to=toDateTime64('2100-01-01 00:00:00',3,'UTC')`, each declared
`DEFINER = CURRENT_USER SQL SECURITY DEFINER` as migration 0023 did.

Statement six creates the lake projection `analytics.events_lake_v1`, also
`DEFINER = CURRENT_USER SQL SECURITY DEFINER`, with parameters `scope_all_accounts UInt8`,
`scope_account String`, `occurred_from`, `occurred_to`, `received_from`, `received_to`. It
delegates to the generalized internal view and returns, in this order and with these wire
types: `event_id String, event_name String, occurred_at DateTime64(3,'UTC'), received_at
DateTime64(3,'UTC'), url String, account_id String, canonical_user String, properties_json
String, source String, source_service String, session_id String, is_bot Bool, browser_family
String, os_family String, device_class String, channel String, country_code String`. Cast
`LowCardinality(String)` columns to `String` and serialize `properties_json` with
`toJSONString(properties_json)`, so the Haskell row type has only `ChString`, `DateTime64 3
"UTC"` and `Bool` columns. Statement seven is a check in the style of the converted
assertions: a `SELECT` that fails with `throwIf` when the lake projection for a fixed window
over an empty table returns a column count other than seventeen.

Add `db/clickhouse/publisher-role.sql` beside `reader-role.sql`: `CREATE ROLE IF NOT EXISTS
kansoku_publisher`, `GRANT SELECT ON analytics.events_lake_v1 TO kansoku_publisher`, and a
settings profile `kansoku_publisher_limits` with `readonly=2 CONST`, `max_threads=2`,
`max_memory_usage=1073741824`, `max_execution_time=120`, `max_network_bandwidth` bounded,
`priority=1`, `do_not_merge_across_partitions_select_final=1` and
`max_block_size=65536`. Operators create a user with that default role; the publisher
authenticates as it when `KANSOKU_LAKE_CLICKHOUSE_USER` is set and otherwise uses the server
identity, which the configuration guide calls a development convenience. The exact numbers are
budgets measured in M6; change them there with a reason.

Update `scripts/identity_acceptance.py` to pass the two new parameters. Add a parity case to
`scripts/clickhouse_migrations_acceptance.py` that selects the same rows from
`events_analytics_v1` and from `events_lake_v1` with wide arrival bounds and compares them
column by column, and a case that proves `system.data_skipping_indices` lists
`idx_received_at` and that a two-minute arrival window query reads fewer granules than a full
partition scan (`system.query_log` `ProfileEvents['SelectedMarks']`, or the pinned release's
equivalent) on the seeded fixture.

M2 passes when `just ch-migrate plan --json` shows 26 migrations, the native test suite
(`just ch-migrations-acceptance`) passes with the new cases, `scripts/reader_acceptance.py`
still passes unchanged, and the image smoke expectation is updated from 25 to 26.


### M3 — Journal, configuration, catalog abstraction and DuckDB driver

Scope: the PostgreSQL state and the Haskell modules the publisher is built from, proven by
`kansoku-lake status` against two catalog kinds.

Append `0008-lake-publication` to `kansoku-core/src/Kansoku/Migrations.hs`:

```sql
CREATE TABLE kansoku.lake_publications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  dataset text NOT NULL,
  account_id text NOT NULL,
  partition_day date NOT NULL,
  state text NOT NULL CHECK (state IN ('staged','published','empty','superseded','failed')),
  snapshot_id bigint,
  row_count bigint,
  staged_digest text,
  resolution_digest text,
  maintenance_generation jsonb NOT NULL,
  longest_lock_hold_ms integer,
  duration_ms integer,
  started_at timestamptz NOT NULL DEFAULT now(),
  published_at timestamptz,
  revision bigserial NOT NULL
);
CREATE UNIQUE INDEX lake_publications_current
  ON kansoku.lake_publications (dataset, account_id, partition_day)
  WHERE state IN ('staged','published','empty');
CREATE TABLE kansoku.lake_watermarks (
  dataset text PRIMARY KEY,
  received_until timestamptz NOT NULL,
  snapshot_id bigint,
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE kansoku.lake_dirty_partitions (
  dataset text NOT NULL,
  account_id text NOT NULL,
  partition_day date NOT NULL,
  origin text NOT NULL CHECK (origin IN ('late_arrival','erasure','retention','re_resolution','operator')),
  reference jsonb,
  recorded_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (dataset, account_id, partition_day, origin)
);
```

`lake_watermarks` and `lake_dirty_partitions` are created now, unused by this plan's commands
except `status`, so EP-55 can record late arrivals and EP-56 can rewrite without a schema
change. `resolution_digest` is filled by this plan with the ClickHouse expression EP-56 will
recompute: `toString(sum(cityHash64(event_id, canonical_user)))` concatenated with the row
count over the published partition, computed by one extra query against `events_lake_v1`
right after the last slice.

Create `kansoku-server/src/Kansoku/Lake/Config.hs` with a `LakeConfig` record loaded by
`loadLakeConfig :: Config -> IO (Either ConfigError LakeConfig)` on top of
`Kansoku.Config.loadConfig`, using the same parser style. Settings and defaults:
`KANSOKU_LAKE_CATALOG` (required; a DuckLake catalog locator such as
`postgres:dbname=kansoku_lake host=db.internal user=kansoku_lake`, `sqlite:/var/lib/kansoku/lake.sqlite`,
`duckdb:/var/lib/kansoku/lake.ducklake` or `mysql:db=kansoku_lake host=...`),
`KANSOKU_LAKE_CATALOG_PASSWORD` (optional; exported to the subprocess as `PGPASSWORD` for a
PostgreSQL catalog and never written anywhere else), `KANSOKU_LAKE_DATA_PATH` (required on first
use; `s3://bucket/prefix/`, `gs://bucket/prefix/`, `az://container/prefix/` or an absolute
directory), `KANSOKU_LAKE_STAGING_DIR` (required; must be writable, created `0700`),
`KANSOKU_LAKE_DUCKDB_BINARY` (default `duckdb` on `PATH`), `KANSOKU_LAKE_DUCKDB_EXTENSIONS`
(a directory for `extension_directories`; default unset means DuckDB's own cache),
`KANSOKU_LAKE_DUCKDB_MEMORY_LIMIT` (default `1GB`), `KANSOKU_LAKE_DUCKDB_THREADS` (default 2),
`KANSOKU_LAKE_DUCKLAKE_VERSION` (default `1.0`), `KANSOKU_LAKE_CLICKHOUSE_USER` and
`KANSOKU_LAKE_CLICKHOUSE_PASSWORD` (default: the server identity), `KANSOKU_LAKE_SLICE_SECONDS`
(default 900), `KANSOKU_LAKE_LOCK_HOLD_CEILING_SEC` (default 10), `KANSOKU_LAKE_CLOSE_GRACE_SEC`
(default 3600), `KANSOKU_LAKE_BACKFILL_DAYS` (default 7). Object-store credentials are read from
the conventional variables of each store family (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
`AWS_REGION`, `KANSOKU_LAKE_S3_ENDPOINT`, `KANSOKU_LAKE_S3_URL_STYLE`, `KANSOKU_LAKE_S3_USE_SSL`;
`KANSOKU_LAKE_GCS_HMAC_KEY_ID`, `KANSOKU_LAKE_GCS_HMAC_SECRET`; `AZURE_STORAGE_CONNECTION_STRING`)
and are turned into DuckDB `CREATE SECRET` statements. No setting privileges a vendor; the guide
shows one example per family and the local-filesystem development form.

Create `kansoku-server/src/Kansoku/Lake/DuckDB.hs`, the subprocess driver. It renders a SQL
script into a `0600` file inside the staging directory containing, in order: `SET
extension_directories = [...]` when configured, `LOAD ducklake` and the catalog and data-path
extensions the locators need (`postgres`, `sqlite`, `mysql`, `httpfs`, `azure`), `SET
memory_limit`, `SET threads`, `SET temp_directory` to a subdirectory of the staging directory,
`CREATE SECRET` statements built from the environment, and `ATTACH 'ducklake:<locator>' AS lake
(DATA_PATH '<path>', DUCKLAKE_VERSION '<version>')`, adding `READ_ONLY` for `status`. It runs
`duckdb -bail -batch -json -init <script>` with the statements for the operation on stdin, the
publisher's environment minus everything but the variables the extensions need, parses the
JSON result sets from stdout, treats a nonzero exit as failure with stderr redacted of
connection strings, and deletes the script file in a `finally`. Credentials never appear in the
argument vector; a unit test asserts it by inspecting the rendered command. Confirm the flag
names against `duckdb --help` of the pinned release and record any difference in Surprises &
Discoveries.

The driver exposes `ensureDataset`, which runs once per invocation:

```sql
CREATE TABLE IF NOT EXISTS lake.events_v1 (
  event_id VARCHAR NOT NULL, event_name VARCHAR NOT NULL,
  occurred_at TIMESTAMP WITH TIME ZONE NOT NULL, received_at TIMESTAMP WITH TIME ZONE NOT NULL,
  url VARCHAR NOT NULL, account_id VARCHAR NOT NULL, canonical_user VARCHAR NOT NULL,
  properties_json VARCHAR NOT NULL, source VARCHAR NOT NULL, source_service VARCHAR NOT NULL,
  session_id VARCHAR NOT NULL, is_bot BOOLEAN NOT NULL, browser_family VARCHAR NOT NULL,
  os_family VARCHAR NOT NULL, device_class VARCHAR NOT NULL, channel VARCHAR NOT NULL,
  country_code VARCHAR NOT NULL
);
ALTER TABLE lake.events_v1 SET PARTITIONED BY (account_id, day(occurred_at));
CALL lake.set_option('parquet_compression', 'zstd');
CALL lake.set_option('data_inlining_row_limit', 0, table_name => 'events_v1');
```

Partitioning by account and day means every data file belongs to one partition, so a
republish deletes whole files and writes no delete files. Inlining is off for the closed
dataset because a closed day is never small enough to belong in the catalog database; EP-55
chooses its own limit for the recent dataset. If the pinned release rejects `NOT NULL` or the
`day` transform on a timestamp with time zone, record the exact error, adjust the DDL, and
state the resulting nullability in the contract. The spike's measured Parquet types decide
whether `occurred_at` is declared with or without time zone; the contract states the choice.

Create `kansoku-server/src/Kansoku/Lake/Journal.hs` for the PostgreSQL side using
`Kansoku.Postgres.Direct` (`withPostgres`, `pg`, `pgScript`) as `Kansoku.Admin.Store` does:
begin a unit (`staged` row with the maintenance generation), complete it (`published` with
snapshot identifier, row count, digests, durations), mark `empty`, supersede on republish,
list for `status`, and read the maintenance generation as the JSON object
`{"job_revision": <max(revision) of kansoku.maintenance_jobs or 0>, "migration_sessions":
<count of completed kansoku.clickhouse_migration_sessions>}`.

Create `kansoku-server/src/Kansoku/Lake/Command.hs` with `optparse-applicative` subcommands
`close-day`, `republish` and `status`, each accepting `--json`, and
`kansoku-server/app/Lake.hs` with `main = getArgs >>= runLake`. Add the `kansoku-lake`
executable stanza to `kansoku-server/kansoku-server.cabal` beside `kansoku-ch-migrate`, a
`kansoku-lake` package output in `flake.module.nix` like `kansoku-admin`, and a test suite
`kansoku-server:test:lake` with hspec specs under `kansoku-server/test/Lake/` for
configuration parsing, script rendering, slice arithmetic and journal state transitions
(the PostgreSQL cases use the existing owned-PostgreSQL test support pattern from
`kansoku-core/test/Kansoku/PostgresTestSupport.hs`).

M3 passes when, against an owned PostgreSQL with migration 0008 applied, `kansoku-lake status
--json` succeeds with `KANSOKU_LAKE_CATALOG=duckdb:<tmp>/lake.ducklake` and a local data path,
and again with `KANSOKU_LAKE_CATALOG=postgres:...` pointing at a second database on the same
owned PostgreSQL, reporting zero publications, the attached catalog's DuckLake version `1.0`,
the existence of `events_v1` with its partition keys, and no secret in `ps`-visible arguments.


### M4 — Sliced, fenced publication and republish

Scope: `close-day` and `republish` publish partitions through the mechanism M1 selected.

Create `kansoku-server/src/Kansoku/Lake/Projection.hs` with the `LakeRow` type and its
`ClickHaskell` column instance for the seventeen columns of `events_lake_v1`, and
`streamSlice :: Connection -> SliceQuery -> ([LakeRow] -> IO ()) -> IO ()` built on the
vendored `select` with a callback that returns unit, so the driver retains nothing. Create
`kansoku-server/src/Kansoku/Lake/Parquet.hs` with a small writer interface (`openStaging`,
`writeBlock`, `closeStaging` returning the path, row count and a SHA-256 digest) implemented
over the selected writer, flushing a row group every `KANSOKU_LAKE_ROW_GROUP_ROWS` rows
(default from the spike, in the order of one hundred thousand). Create
`kansoku-server/src/Kansoku/Lake/Fence.hs` with `withSliceLock :: PQ.Connection -> IO a -> IO
(a, Int)` that performs try-lock admission exactly as `Kansoku.Admin.Store.admitMaintenanceTraffic`
does, runs the action, releases with `pg_advisory_unlock_shared(726401,1)` in a `finally`,
and returns the hold duration in milliseconds, and `withPublisherLock`, an exclusive
`pg_try_advisory_lock(726401,3)` that makes a second concurrent publisher exit with a clear
message instead of racing.

Create `kansoku-server/src/Kansoku/Lake/Publish.hs`, the unit orchestration. For one
partition: clean any staging files left by a previous crash; read the maintenance generation
and insert the `staged` journal row (a conflict on the unique index means the partition is
already current and the unit is skipped unless republishing); split the day into slices of
`KANSOKU_LAKE_SLICE_SECONDS`; for each slice, under `withSliceLock`, run `streamSlice` with the
account, the slice's occurred bounds and wide arrival bounds, writing blocks into the slice's
staging file; after the slices, outside any lock, compute the resolution digest with one query,
re-read the maintenance generation, and if it differs from the one recorded, delete the staged
files, mark the row `failed` with the reason `maintenance_interleaved`, and retry the unit once
from the start before giving up for this run; otherwise run one DuckDB transaction:

```sql
BEGIN TRANSACTION;
DELETE FROM lake.events_v1
  WHERE account_id = $account AND occurred_at >= $day AND occurred_at < $day + INTERVAL 1 DAY;
INSERT INTO lake.events_v1 SELECT * FROM read_parquet([$slice_files]);
COMMIT;
SELECT max(snapshot_id) FROM ducklake_snapshots('lake');
```

The `DELETE` is a no-op for a first publication and makes `republish` a replacement in the same
snapshot; confirm the snapshot-listing function name against the pinned release. Record the
snapshot identifier, row count, staged digest, resolution digest, longest slice hold and unit
duration in the journal, delete the staging files, and emit a JSON receipt line. A unit with
zero rows records `empty` and writes nothing to the lake. If any slice hold exceeds
`KANSOKU_LAKE_LOCK_HOLD_CEILING_SEC`, the receipt and stderr carry a warning naming the slice
length to reduce; the unit still completes.

`close-day` without options publishes every partition for every account whose day is closed
(`now() >= day + 1 day + grace`) and not current in the journal, from the most recent closed
day back through `KANSOKU_LAKE_BACKFILL_DAYS`; accounts come from `SELECT DISTINCT account_id
FROM kansoku.api_keys`, and a partition with no events is recorded `empty`. `--day YYYY-MM-DD`
and `--account` narrow it. `republish --day D [--account A]` previews the partitions it would
replace and performs them with `--confirm`, superseding the previous journal rows. Both
commands refuse to start when `kansoku.maintenance_fence` has an active job or migration
session, run under `withPublisherLock`, and process one unit at a time. Register
`Kansoku.Lake.Metrics` with the series `kansoku_lake_unit_duration_seconds`,
`kansoku_lake_lock_hold_seconds` (both histograms), `kansoku_lake_rows_published_total`,
`kansoku_lake_bytes_staged_total` and `kansoku_lake_last_publication_timestamp_seconds`
labelled by dataset; this plan records their values in the journal and receipt, and EP-55
serves the registry.

Owned tests in `scripts/lake_acceptance.py` (also used by M7) prove: a seeded closed day for
two accounts publishes as one snapshot per partition; rerunning `close-day` publishes nothing;
`republish --confirm` creates exactly one new snapshot and the catalog's file listing for the
partition shows the old files superseded; killing the process between the last slice and the
DuckDB commit leaves a `staged` row that the next run reconciles by re-staging; a second
publisher started during a run exits without publishing; a `kansoku-admin apply-retention
--confirm` started while a unit is mid-slice succeeds within its thirty-second budget and the
unit discards and republishes; the longest hold stays under the ceiling on the fixture.

M4 passes when those cases pass against owned stores with a DuckDB-file catalog and local
data path, and an unmodified pinned DuckDB CLI attaching the catalog read-only returns the
seeded day's rows from `events_v1`.


### M5 — Package the DuckDB runtime and the fifth executable

Scope: the Nix closure and the image. Add `db/duckdb/qualification/matrix.json` in the style
of the ClickHouse matrix, recording the DuckDB release used, its CLI artifact per platform
and digest, the DuckLake extension version, and the extension binaries pinned for offline
loading. At planning time the current release was DuckDB v2.0.0 (tag `v2.0.0`, 2026-10-21,
commit `d54cbbe3df17e8e5ce68312f483b4155836112aa`) with CLI assets
`duckdb-cli-osx-arm64.tar.gz` and `duckdb-cli-linux-amd64.tar.gz`; the digests read from the
release page were `188a36fe8883ef52e69165a0cbb6031ef679c8e6c448a1ce22951964149b7f96` and
`c6507206baf7793c6013dbd82368469a45f20dc0e17a6f92f204602f652ed2bc`. Verify both independently
before recording them, recheck for a later 2.0.x patch, and never guess a digest.

Add `nix/duckdb-qualified.nix` that fetches the CLI for `aarch64-darwin` and `x86_64-linux`
from the matrix, unpacks it, and assembles an extensions directory for the pinned version and
platform containing `ducklake`, `postgres`, `sqlite`, `mysql`, `httpfs` and `azure`, each
fetched by URL and digest recorded in the matrix (the DuckDB extension repository serves
`<version>/<platform>/<name>.duckdb_extension.gz`; confirm the exact layout the pinned
release expects under `extension_directories` by installing one extension online once and
copying its on-disk path into the matrix). Also pin the floor consumer: `pkgs.duckdb` 1.5.5
from the pinned nixpkgs with its own `ducklake` extension binary, used only by M7. Expose
both through `haskellProject.extraDevPackages`, export `KANSOKU_LAKE_DUCKDB_EXTENSIONS` in the
shell hook, and add `kansoku-lake` plus the DuckDB runtime to `nix/kansoku-image.nix`
contents with `KANSOKU_LAKE_DUCKDB_EXTENSIONS` in the image environment. Add a package output
`kansoku-lake` and `duckdb-qualified` in `flake.module.nix`. If the selected writer links a
system codec library, add it to `haskellProject.extraBuildInputs` and the image.

Update the image smoke test and `scripts/check_container_image.py` to expect five
executables, a 26-migration plan and a successful `duckdb -c "LOAD ducklake"` with the network
disabled. Append a dated note to ADR-24 stating that the image now carries five executables
and the DuckDB runtime, and update `docs/guides/container-image.md` accordingly.

M5 passes when `nix build .#kansoku-lake` and `nix build .#duckdb-qualified` succeed on
Darwin, the Linux image builds and its smoke test passes on the configured Linux builder (or
the blocker is recorded exactly as ADR-24 did), and `nix develop` offers `kansoku-lake`,
`duckdb` 2.0.0 and offline `LOAD ducklake`.


### M6 — Performance harness and budgets

Scope: `scripts/lake_bench.py` and `just lake-bench`, modeled on `scripts/identity-bench.py`.
The harness owns a ClickHouse and a PostgreSQL, applies both plans, seeds ten million events
for one account on one closed UTC day plus the identity evidence that `identity-bench.py`
generates, creates a second database for a PostgreSQL catalog, starts the packaged server with
a service token, and then measures with the packaged `kansoku-lake`:

- Peak resident set size of the publisher during `close-day`, sampled every second. Budget
  512 MiB.
- Longest slice lock hold from the receipt. Budget 10 seconds. Also report the hold
  distribution so the default `KANSOKU_LAKE_SLICE_SECONDS` can be tuned.
- Wall-clock for the ten-million-event day. Proposed budget 10 minutes.
- Ninety-ninth percentile latency of the daily-users HTTP metric and of the two-step funnel
  metric, measured for sixty seconds idle and again during the export, as a ratio. Budget 1.5.
  During the export, the harness also streams events at two hundred per second through the
  ingest route, as `scripts/outage-acceptance.py` does, and asserts that writer flush latency
  and queue depth metrics do not change beyond their idle variance.
- ClickHouse-side cost of the whole export from `system.query_log`: read rows and bytes, peak
  memory, and that every publisher query ran under the `kansoku_publisher_limits` profile.
- Granules read by a two-minute `received_at` window query through `events_lake_v1` on the
  seeded month, compared with the partition's total marks, proving the arrival index prunes.
- The index materialization duration recorded when the owned fixture applies migration 0026
  with ten million rows present (run the seed before applying 0026 in this harness).
- DuckDB-side insert time and the resulting file count and sizes from the catalog's file
  listing for the partition.

Write `.dev/acceptance/lake-bench-*/report.json` and a human summary. A budget that fails is a
design change, not a number to relax: reduce the slice length, bound the profile tighter, or
revisit the writer selection, then rerun. Record the confirmed or re-based figures in this
plan's Outcomes & Retrospective and in the MasterPlan's performance budgets integration point.

M6 passes when the report shows every budget met at ten million events, or re-based with a
recorded reason and a Decision Log entry.


### M7 — Two-tier conformance gate

Scope: `scripts/lake_acceptance.py` wired into `scripts/acceptance.py` for the deterministic
tier, and `scripts/lake_realistic_acceptance.py` with `just lake-realistic-acceptance` for the
realistic tier. Both are required and non-skipping; an absent prerequisite is a failure.

The deterministic tier uses a DuckDB-file catalog and a local data path under the acceptance
root. It seeds the adversarial fixture `scripts/reader_acceptance.py` already uses for a day
two days in the past, publishes it, and compares three answers for the daily-users recipe:
the HTTP metric, the ADR-18 reader recipe executed as `kansoku_reader`, and the lake recipe
executed by the pinned DuckDB CLI:

```sql
SELECT CAST(occurred_at AT TIME ZONE 'UTC' AS DATE) AS day, count(DISTINCT canonical_user) AS value
FROM lake.events_v1
WHERE account_id = $account AND source_service = $source_service AND canonical_user <> ''
  AND NOT is_bot AND event_name NOT IN ('identify','identify_once','alias','group')
GROUP BY day ORDER BY day;
```

It then runs `kansoku-admin erase-user --confirm` for one subject and `kansoku-admin
apply-retention --confirm` with a cutoff inside the fixture, runs `kansoku-lake republish
--confirm` for the day, and compares the three answers again; after the republish the erased
subject's rows are absent from `events_v1` at the newest snapshot. It asserts uniqueness of
`(account_id, event_id)` within the partition and that the partition is exactly one snapshot
in `ducklake_snapshots` and `ducklake_table_changes('lake','main','events_v1', s, s)`, read
inclusively as Kikan's `mesh-connector.py` does. It also runs the M4 interleaving cases.

The realistic tier repeats the same scenarios with a PostgreSQL catalog in a second database
on the owned PostgreSQL and an owned S3-compatible object store. The emulator is RustFS
(`mori://rustfs/rustfs` is not registered; upstream is `https://github.com/rustfs/rustfs`,
Apache-2.0), taken from the pinned nixpkgs as `pkgs.rustfs`, which builds for
`aarch64-darwin` and `x86_64-linux`. The pinned nixpkgs carries 1.0.0-rc.5 while upstream
reports a 1.0.0 general-availability release in September 2026; pin the nixpkgs package first,
record its version and store hash in `db/duckdb/qualification/matrix.json`, and move to the
GA tag through a verified `src` override in `flake.module.nix` (as `geoipReader` does for
libmaxminddb) once its release digest is checked, never by guessing. Start it from the harness
on a free loopback port with a private data directory and disposable access keys, as the
ClickHouse helper does, and make the harness fail with the S3 operation named when RustFS
rejects one that DuckDB's `httpfs` needs: bucket creation, multipart upload, range `GET`,
`ListObjectsV2` and `DELETE`. `garage` 1.3.1 from the same nixpkgs is the recorded fallback if
that happens; swapping it is a Decision Log entry, not a silent change. This tier additionally attaches the catalog read-only from the floor release
(DuckDB 1.5.5 with its DuckLake extension 1.0) and runs the lake recipe there, proving the
version floor, and records an `s3://` data path round trip through DuckDB's `httpfs`. Google
Cloud Storage and Azure remain documented compatibility, not owned acceptance, and the guide
says so.

M7 passes when `just acceptance` includes the deterministic lake family with nonzero cases
and `just lake-realistic-acceptance` passes, both with private evidence under the acceptance
root and sanitized summaries.


### M8 — Records: ADR, contract, capability, terms, guides

Scope: the durable documents. Allocate the ADR handle with `okf id next docs/adr --profile
docs/adr/profile.dhall ADR` (expected `ADR-25`) and write
`docs/adr/0025-publish-analytics-as-a-kansoku-owned-ducklake-data-product.md` with the
profile's frontmatter (`type`, `title`, `description`, `docId`, `status: Accepted`, `date`,
`timestamp`, `originatingPlan`). Its decision records: export-then-commit because no
ClickHouse-native DuckLake catalog exists; a Kansoku-owned publisher with try-lock admission
and a per-slice hold budget derived from ADR-17's thirty-second exclusive wait; Kansoku's own
catalog and data path, created at DuckLake 1.0 with a named consumer floor; the closed-day
dataset in the ADR-18 projection shape with string JSON; the publisher's bounded ClickHouse
identity; vendor-neutral configuration; measured budgets as acceptance; and the exclusions the
MasterPlan lists. State that EP-55 and EP-56 amend it. Run `okf log add` for the bundle,
update `docs/adr/index.md`, and run the strict validation command from the Concrete Steps.

Write `docs/contracts/lake-data-product.md` with these stable sections, in this order: Product
identity and owner; Catalog and storage location (how to find it, never a deployment value);
Datasets and schemas (`events_v1`, every column with type, nullability, meaning and source
column; partitioning; uniqueness of account and event identifier); Evolution and
compatibility policy (additive columns in place, a new major version is a new dataset name,
DuckLake version floor); Freshness objective (closed days after grace; EP-55 adds the
provisional tier); Classification and access policy (trusted single-tenant, account column is
scope not authorization, read-only catalog role); Consumers (DuckDB CLI, mesh connectors
through the change feed); Quality checks (the three-way recipe parity, uniqueness, snapshot
per partition); Lifecycle (republish on demand now, erasure and retention propagation in
EP-56); Evidence and runbook (links to the acceptance scripts, the benchmark report and the
guide). Link it from `docs/README.md` under Contract references and state that it migrates to
the OKF Data Product profile when `mori://shinzui/okf-profiles` releases one.

Add `docs/capabilities/lakehouse-data-product-publication.md` as `CAP-20` (status `shipped`,
stability `experimental`, requires `CAP-19` and `CAP-5`, interface `kansoku-lake`,
`analytics.events_lake_v1`, `events_v1`, evidence pointing at the acceptance scripts and the
guide). Add terms `data product`, `closed dataset`, `provisional dataset`, `publication
snapshot` and `publication unit` to `docs/terminology/` with the next handles from `okf id
next`, related to `maintenance fence` and `reader projection`. Add
`docs/guides/publish-lake.md` as `DOC-15`, a Guide covering: configuring a catalog and data
path with one example per store family and the local development form; creating the publisher
ClickHouse user with `db/clickhouse/publisher-role.sql`; running `close-day`, `republish` and
`status`; attaching read-only from the DuckDB CLI and running the recipe; the consumer floor;
and what is not yet published (recent tier, erasure propagation). Add a `Lake publication`
section to `docs/guides/configuration.md` listing every `KANSOKU_LAKE_*` setting and default,
and a `Lake publication` section to `docs/guides/operations.md` covering scheduling
`close-day` after midnight UTC plus grace, reading receipts, the lock-hold warning, and the
interaction with maintenance jobs. Update each bundle's `index.md` and `log.md` and run the
four profile checks.

Finally update the MasterPlan: mark EP-54 Complete in the registry, refresh Progress, record
measured budgets in Outcomes & Retrospective, and add any cross-plan discovery to Surprises &
Discoveries. Record provenance on both files.

M8 passes when `just check` is green (it runs the four profile checks), the strict ADR
validation passes, every new document resolves its links, and the MasterPlan registry row
reads Complete.


## Concrete Steps

All commands run from the repository root inside `nix develop`. Record friction with
`bun agents/skills/exec-plan/record-friction.ts` as it occurs, naming this plan's path.

Verify upstream before pinning, and record what you saw:

```bash
curl -s https://hackage.haskell.org/package/wireform-parquet/preferred -H 'Accept: application/json'
git ls-remote --tags https://github.com/iand675/wireform- | tail -20
curl -s https://api.github.com/repos/duckdb/duckdb/releases/latest | jq -r '.tag_name, .published_at'
```

Expected at planning time: `Package not found` for `wireform-parquet`, tags only for
`wireform-core`, `wireform-derive` and `wireform-proto`, and `v2.0.0` dated 2026-10-21.

Build and run the spike (M1):

```bash
cabal build -flake-writer-spike kansoku-server:exe:kansoku-lake-spike
python3 scripts/lake_spike.py --rows 10000000
```

Expected: a report path under `.dev/acceptance/lake-spike-*/` and one line per candidate with
rows per second, peak resident bytes and DuckDB types.

Append the ClickHouse migration (M2) and prove it:

```bash
ls kansoku-server/migrations/clickhouse/steps/0026_lake_projection/
just ch-migrate plan --json | jq '.result.schedule | length'
just ch-migrations-acceptance
python3 scripts/reader_acceptance.py
```

Expected: statement files `statement-01.sql` through `statement-07.sql`, the number `26`, and
both harnesses passing with nonzero cases.

Apply the PostgreSQL migration and check the journal (M3):

```bash
just migrate
psql "$PG_CONNECTION_STRING" -Atc "\dt kansoku.lake_*"
cabal build kansoku-server:exe:kansoku-lake
KANSOKU_LAKE_CATALOG="duckdb:$PWD/.dev/lake/catalog.ducklake" \
KANSOKU_LAKE_DATA_PATH="$PWD/.dev/lake/data/" \
KANSOKU_LAKE_STAGING_DIR="$PWD/.dev/lake/staging" \
  "$(cabal list-bin kansoku-server:exe:kansoku-lake)" status --json
```

Expected: three tables, and a JSON object with `"publications": 0`, `"ducklake_version": "1.0"`
and `"datasets": ["events_v1"]`.

Publish and read a day (M4), after sending events for a day that has closed:

```bash
"$(cabal list-bin kansoku-server:exe:kansoku-lake)" close-day --day 2026-11-02 --json
duckdb -c "ATTACH 'ducklake:$PWD/.dev/lake/catalog.ducklake' AS lake (READ_ONLY); \
  SELECT account_id, count(*) FROM lake.events_v1 GROUP BY 1;"
```

Expected: one receipt line per account with `"state": "published"`, a `snapshot_id`,
`longest_lock_hold_ms` well under 10000, and the DuckDB query returning the published counts.

Package (M5):

```bash
nix build .#kansoku-lake .#duckdb-qualified
nix develop -c duckdb -c "LOAD ducklake; SELECT 'offline ok';"
```

Expected: both builds succeed and the offline load prints `offline ok`.

Measure (M6) and prove (M7):

```bash
just lake-bench
just acceptance
just lake-realistic-acceptance
```

Expected: a benchmark report whose `budgets` object has every entry `"met": true` or a
`"rebased_reason"`, and both acceptance runs ending with their sanitized summary and exit code
zero.

Records (M8):

```bash
okf id next docs/adr --profile docs/adr/profile.dhall ADR
okf id next docs/capabilities --profile docs/capabilities/profile.dhall CAP
okf id next docs/terminology --profile docs/terminology/profile.dhall TERM
okf id next docs/guides --profile docs/guides/profile.dhall DOC
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
just capabilities-check terminology-check guides-check
```

Expected at planning time: `ADR-25`, `CAP-20`, `TERM-80`, `DOC-15`; the validations print no
errors.

Commit at each milestone boundary with both trailers and the intention:

```text
feat(lake): publish closed-day events to a DuckLake catalog

<body>

MasterPlan: docs/masterplans/6-publish-kansoku-analytics-as-a-ducklake-lakehouse-data-product.md
ExecPlan: docs/plans/54-publish-closed-day-events-to-a-ducklake-catalog-with-a-data-product-contract.md
Intention: intention_01m6gzmpyde2nr3ywy1d2vhbn9
```


## Validation and Acceptance

Required acceptance for this plan, all against actual packaged executables in owned stores
(ADR-10), none skippable:

1. Three-way parity. For the adversarial fixture day, the daily-users answer from the HTTP
   metric, from the ADR-18 reader recipe as `kansoku_reader`, and from the lake recipe over
   `events_v1` through the pinned DuckDB CLI are equal, before and after an erasure and a
   retention job followed by `republish`.
2. One snapshot per partition. `ducklake_snapshots` and the inclusive change feed show exactly
   one snapshot for a first publication and exactly one for a republish, and the superseded
   files are listed as such.
3. Frozen views unchanged. `scripts/reader_acceptance.py` and the migration parity case pass
   with byte-identical rows from `events_analytics_v1` before and after migration 0026, and
   `events_lake_v1` with wide arrival bounds matches it column by column.
4. Fence behaviour. A retention job started mid-unit completes within its thirty-second
   budget; the interrupted unit is discarded and republished; a second publisher exits
   without publishing; the longest hold on the ten-million-event fixture is under ten seconds.
5. Budgets. The M6 report meets, or re-bases with a recorded reason, every EP-54 budget:
   resident memory, lock hold, wall-clock, metric latency ratio with unchanged writer flush and
   queue depth, index pruning, and index materialization duration.
6. Packaging. The Linux image smoke test proves five executables, a 26-migration plan and
   offline extension loading; the developer shell offers the pinned DuckDB.
7. Consumer floor. DuckDB 1.5.5 attaches the catalog read-only and runs the recipe.
8. Records. `just check` passes with the new ADR, capability, terms and guide; the contract
   document exists and is linked.

Proposals, not required by this plan: zero-copy registration of very large closed-day files;
Google Cloud Storage and Azure owned acceptance; serving the metrics registry over HTTP, which
EP-55 owns.


## Idempotence and Recovery

Every command may be rerun. `close-day` skips partitions whose journal row is `published` or
`empty`; a `staged` row from a crash is reconciled on the next run by deleting the stale
staging files, checking the catalog for a snapshot whose change feed carries that partition's
rows (and completing the row if one exists), and otherwise re-staging. `republish` always
replaces inside one DuckDB transaction, so a failure before `COMMIT` leaves the previous
snapshot intact and the journal row `failed`; nothing is half published. The DuckDB
transaction is the only commit point for the lake; the journal row advances only after it,
and no cross-store transaction is claimed.

Migration 0026 is append-only; a failed native step is recovered through the existing
`kansoku-ch-migrate` repair contract and must never be edited after it has been applied. The
index materialization is a mutation that can be re-run with `MATERIALIZE INDEX` without harm.
Migration 0008 adds tables only. Creating `events_v1` and setting its options is guarded by
`IF NOT EXISTS` and is repeated on every invocation.

The staging directory is private to the publisher; on startup, files older than the running
unit are removed. The DuckDB init script is written `0600` and deleted in a `finally`; if a
crash leaves one behind, the next run removes it before doing anything else. If the pinned
DuckDB CLI, an extension or the emulator cannot be fetched by the recorded digest, stop and
record the discrepancy rather than widening or guessing a hash.


## Interfaces and Dependencies

Libraries and runtimes whose choice matters: the vendored `ClickHaskell` `select` for
block-streamed reads (`vendor/ClickHaskell/ClickHaskell.hs`); the Parquet writer selected in M1
(`wireform-parquet` at an immutable commit, or `dataframe-parquet` 1.5.1.0, or the ClickHouse
`file` table function); DuckDB 2.0.0 CLI with DuckLake extension 2.0 writing spec 1.0
catalogs; DuckDB `postgres`, `sqlite`, `mysql`, `httpfs` and `azure` extensions pinned for
offline loading; `optparse-applicative` 0.19.0.0 for the CLI; `prometheus-client` 1.1.2 for
the registry; RustFS from the pinned nixpkgs for the realistic gate.

Types and modules other work depends on, all under `kansoku-server/src/Kansoku/Lake/`:
`Config.LakeConfig` and `Config.loadLakeConfig`; `DuckDB.runScript`, `DuckDB.ensureDataset`
and `DuckDB.Locator` (the parsed catalog and data-path forms); `Journal.beginUnit`,
`Journal.completeUnit`, `Journal.markEmpty`, `Journal.supersede`, `Journal.maintenanceGeneration`
and the `lake_dirty_partitions` relation EP-55 and EP-56 write; `Fence.withSliceLock` and
`Fence.withPublisherLock`; `Projection.LakeRow`, `Projection.SliceQuery` (account scope,
occurred bounds, arrival bounds) and `Projection.streamSlice`; `Parquet.Staging`;
`Publish.publishPartition`; `Metrics.LakeMetrics`. The ClickHouse interface other children
call is `analytics.events_lake_v1` with its six parameters and seventeen columns, and the
generalized `analytics.events_resolved_internal` with six parameters. The PostgreSQL advisory
key `(726401,3)` is the publisher lock and must not be reused.

Prerequisites: none from another child. Dependents: EP-55 (recent dataset and maintenance)
extends `Publish` with arrival-bounded units and serves `Metrics`; EP-56 (lifecycle) consumes
`lake_dirty_partitions`, `resolution_digest` and `Publish.publishPartition`; EP-57 (typed
datasets) reuses `DuckDB` and `Parquet`. Changing the names above after EP-54 completes is a
MasterPlan integration decision, not a local refactor.
