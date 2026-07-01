---
id: 3
slug: clickhouse-storage-schema-and-batch-writer
title: "ClickHouse storage schema and batch writer"
kind: exec-plan
created_at: 2026-07-01T16:04:44Z
intention: "intention_01kwf425fxenc904ear54cr2n7"
master_plan: "docs/masterplans/1-kansoku-analytics-service-mvp.md"
---

# ClickHouse storage schema and batch writer

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Kansoku (観測, "observation") is a self-hostable analytics service. Its whole reason for
existing is to swallow a very large number of behavioral events and let people ask
aggregate questions about them later. The events land in ClickHouse, a columnar SQL
database tuned for high-volume append-only inserts and analytical queries (it is already
provided by this repository's development environment; see the Context section). This plan
builds the storage foundation everything else in the service sits on: the physical table
that holds raw events, and the Haskell code that writes a whole batch of events into that
table in a single database round-trip.

After this plan is complete, a developer working in this repository can, on their laptop,
start the ClickHouse server, apply the schema, and run a test that inserts a batch of sample
events and reads them back — proving the round-trip works. Concretely, after this plan they
can run one command and see a row count come back:

```bash
clickhouse-client --port 9000 --query 'SELECT count() FROM analytics.events_raw'
```

and observe a number that matches the events they just inserted. They can also insert the
same event twice (simulating a redelivered message from the durable queue that feeds this
table in a later plan) and observe that after a merge the duplicate collapses to a single
row. That deduplication behavior is the second load-bearing outcome of this plan: because
the queue-to-ClickHouse boundary built in a later plan is *at-least-once* (the insert and
the queue acknowledgement cannot share one transaction, so a crash can replay a batch), the
storage layer itself must be able to swallow duplicate events without double-counting.

Nothing in this plan requires the HTTP ingestion API, the message queue, or any other part
of Kansoku. The storage layer is deliberately verifiable in isolation: connect to
ClickHouse, insert rows, query them back.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Confirm EP-1 artifacts exist (`kansoku.cabal`, `cabal.project`, `Kansoku.Config`, the
  `justfile`, the effectful runtime). If EP-1 is not yet merged, stop and coordinate — this
  plan hard-depends on it (see Interfaces and Dependencies).
- [ ] Narrow the repository `.gitignore`: replace the `db/` line with `db/*` followed by
  `!db/clickhouse/` so migration files under `db/clickhouse/` are committable while the
  Postgres state directory stays ignored. Verify:
  `git check-ignore -v db/clickhouse/migrations/0001_events_raw.sql` must report the file as
  NOT ignored (prints nothing, exits nonzero). See Milestone 1 and the Decision Log.
- [ ] Add the pinned `source-repository-package` stanza for `ClickHaskell` (tag `v1.1.0`,
  subdir `ClickHaskell/library`) to `cabal.project` — this is the primary mechanism, because
  Hackage's latest release is 1.0.0 and 1.1.0 exists only as a Hackage candidate — then add
  `ClickHaskell` to the `build-depends` of the library stanza in `kansoku.cabal` (see
  Concrete Steps).
- [ ] Create the DDL file `db/clickhouse/migrations/0001_events_raw.sql` containing
  `CREATE DATABASE IF NOT EXISTS analytics` and `CREATE TABLE IF NOT EXISTS
  analytics.events_raw (...)` with the engine, ordering, and partitioning specified below.
- [ ] Add a `ch-migrate` recipe to the repository `justfile` that applies every
  `db/clickhouse/migrations/*.sql` file in filename order with `clickhouse-client --multiquery`.
- [ ] Milestone 1: start ClickHouse, apply the schema, verify the table exists with
  `clickhouse-client` (`DESCRIBE` and a `SELECT count()` returning `0`).
- [ ] Create `src/Kansoku/ClickHouse/EventRow.hs`: the type-level `EventColumns` schema, the
  `EventRow` record deriving the ClickHaskell column mapping, and `eventRowFromEvent`.
- [ ] Create `src/Kansoku/ClickHouse.hs`: connection configuration wired from
  `Kansoku.Config`, `openClickHouse`, `ensureSchema`, `insertEvents`, `selectAllEvents`,
  and `countEvents`.
- [ ] Extend `Kansoku.Config` with `clickHouseHost`, `clickHouseTcpPort`, and
  `clickHouseDatabase` read from the environment (`CLICKHOUSE_TCP_PORT`), following EP-1's
  config pattern.
- [ ] Add the two new modules to `exposed-modules` in `kansoku.cabal`.
- [ ] Milestone 2: add a guarded test `test/Kansoku/ClickHouseSpec.hs` that ensures the
  schema, inserts a batch of sample events, selects them back, and asserts count and content.
  `cabal test` passes (or skips cleanly when ClickHouse is not reachable).
- [ ] Milestone 3: add a deduplication test/demonstration — insert the same `event_id` twice,
  force a merge with `OPTIMIZE TABLE ... FINAL` (or read with `SELECT ... FINAL`), and observe
  exactly one row. Document the semantics for downstream plans.
- [ ] Update the parent MasterPlan Progress checkboxes for EP-3 and this plan's living
  sections; write an Outcomes & Retrospective entry.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Use `ReplacingMergeTree(received_at)` as the table engine, and append
  `event_id` to the end of the `ORDER BY` sorting key so the full sorting key is unique per
  event.
  Rationale: `ReplacingMergeTree` deduplicates rows that share the *entire* `ORDER BY`
  sorting key, collapsing them to one during background merges (keeping the row with the
  largest value of the version column, here `received_at`). The MasterPlan requires
  deduplication on `event_id` because the queue→ClickHouse boundary (built in EP-4) is
  at-least-once and a replayed batch re-inserts rows with identical `event_id`. The spec's
  suggested ordering is `(account_id, user_id, event_name, occurred_at)`, which is *not*
  unique per event, so on its own it would collapse genuinely distinct events. Appending
  `event_id` keeps the spec's prefix (so range scans filtered by `account_id`, `user_id`,
  etc. still use the primary index) while making the key unique per event, so only true
  replays of the same event collapse. `received_at` is the version column so that if a
  replay carries a later receive time, the freshest copy wins.
  Date: 2026-07-01

- Decision: Make the sorting-key id columns `account_id` and `user_id` non-nullable
  `String` with the empty string meaning "absent", rather than `Nullable(String)`.
  Rationale: ClickHouse requires the setting `allow_nullable_key = 1` to place a
  `Nullable` column in the `ORDER BY` key, and nullable keys carry NULL-ordering and
  performance caveats. Since `account_id` and `user_id` are in the sorting key, storing them
  as plain `String` (empty = absent) is cleaner. The `eventRowFromEvent` mapping uses
  `fromMaybe ""` for these two fields. All other optional ids (`organization_id`,
  `session_id`, `anonymous_id`, the UTM fields, correlation fields) remain
  `Nullable(String)`. Downstream queries treat an empty `account_id`/`user_id` as "unknown".
  The alternative — keeping them `Nullable` and enabling `allow_nullable_key` — was rejected
  to avoid the nullable-key caveats; if a future need arises it is a localized change.
  Date: 2026-07-01

- Decision: Store `properties` and `context` (the two free-form
  `Record<string, unknown>` maps from the canonical event model) as ClickHouse `String`
  columns holding JSON text, not `Map(String, String)`.
  Rationale: `properties` and `context` can hold arbitrarily nested, mixed-type values, which
  `Map(String, String)` cannot represent. JSON-as-String is the simplest faithful encoding,
  is still queryable through ClickHouse's JSON functions (`JSONExtractString`,
  `JSONExtractInt`, `simpleJSONExtractRaw`, etc.), and keeps the Haskell mapping trivial (the
  event's already-serialized JSON object is written verbatim). Later plans that need typed
  access can add generated columns or materialized views.
  Date: 2026-07-01

- Decision: Represent `source` and `event_name` as `LowCardinality(String)` rather than a
  ClickHouse `Enum8`.
  Rationale: `LowCardinality(String)` gives dictionary compression (both columns have very
  few distinct values relative to row count) without pinning the allowed values in the table
  DDL. `source` is a small closed set today (`web`, `app`, `service`, `worker`, `email`,
  `agent`) but new sources should not require an `ALTER TABLE`; `event_name` is open-ended by
  design. `Enum8` would require a DDL migration to add a value.
  Date: 2026-07-01

- Decision: Use `DateTime64(3, 'UTC')` (millisecond precision, UTC) for `occurred_at` and
  `received_at`.
  Rationale: Analytics ordering and funnels need sub-second resolution; milliseconds are
  enough and keep storage compact. Fixing the timezone to UTC avoids ambiguity. ClickHaskell
  maps `DateTime64 p tz` to Haskell `UTCTime`, and `DateTime64` is a valid
  `ReplacingMergeTree` version column type.
  Date: 2026-07-01

- Decision: Apply the schema two ways — a plain, idempotent `.sql` file under
  `db/clickhouse/migrations/` invoked by a `just ch-migrate` recipe, *and* a Haskell
  `ensureSchema :: Connection -> IO ()` that runs the same `CREATE ... IF NOT EXISTS`
  statements via ClickHaskell's `command`.
  Rationale: The file/`just` path mirrors the existing Postgres pattern in this repo
  (`process-compose.yaml` runs `just create-database`) and is what operators and
  `process-compose` use at startup. The Haskell path lets the test suite and the server's
  startup guard create the schema without shelling out, so tests are self-contained. Both use
  `IF NOT EXISTS`, so running either (or both) repeatedly is safe.
  Date: 2026-07-01

- Decision: `event_id` is stored as `String`, not `UUID`.
  Rationale: The canonical event model types `eventId` as an opaque `string`; callers are not
  required to send a UUID. Storing it as `String` avoids rejecting valid non-UUID ids and
  keeps the Haskell field a `ByteString`.
  Date: 2026-07-01

- Decision: Narrow the repository `.gitignore` from `db/` to `db/*` plus `!db/clickhouse/`,
  keeping the migration path `db/clickhouse/migrations/` unchanged.
  Rationale: `db/` is the PostgreSQL state directory (the dev shell sets `PGHOST=$PWD/db`
  and `PGDATA=db/db`), so it is rightly ignored — but the blanket `db/` pattern excludes the
  *directory itself*, and git cannot re-include any path inside an excluded directory. As
  written, `db/clickhouse/migrations/0001_events_raw.sql` could never be committed, which
  would silently break Milestone 1 and every downstream plan that reads the migrations. The
  fix (taken at the MasterPlan level: narrow the ignore rather than relocate the migrations)
  is to replace the single `db/` line with `db/*` (ignore every child of `db/`, so Postgres
  sockets and data stay untracked) followed by `!db/clickhouse/` (re-include the ClickHouse
  subtree, so migrations are tracked). Relocating the migrations was rejected because the
  `db/clickhouse/migrations/` path is already the shared contract with EP-5 and the
  `ch-migrate` recipe.
  Date: 2026-07-01

- Decision: Supply `ClickHaskell` 1.1.0 via a `cabal.project` `source-repository-package`
  git pin (tag `v1.1.0`, subdir `ClickHaskell/library`) as the *primary* mechanism, not a
  fallback.
  Rationale: Hackage's latest *release* of `ClickHaskell` is 1.0.0; version 1.1.0 exists
  only as a Hackage *candidate* (uploaded but unpublished), and cabal's dependency solver
  never considers candidates — so a plain `ClickHaskell ^>=1.1` bound will not resolve from
  Hackage today. The pin is therefore not a contingency but the required path. The `subdir`
  was verified against the local corpus checkout of the upstream monorepo: the library's
  cabal file sits at `ClickHaskell/library/ClickHaskell.cabal` (package `ClickHaskell`,
  version `1.1.0`).
  Date: 2026-07-01


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section assumes you know nothing about this repository. Read it fully before editing.

Kansoku is a greenfield Haskell project. It builds with GHC 9.12.4 and is developed inside a
Nix flake: running `nix develop` at the repository root drops you into a shell with the
compiler, `cabal`, the `clickhouse` package (which puts both `clickhouse-server` and
`clickhouse-client` on your `PATH`), PostgreSQL, `just` (a command runner that reads a file
called `justfile`), `jq`, and `process-compose` (a small process supervisor). The flake's
Haskell wiring lives in `nix/haskell.nix`.

**A note on `nix build`.** EP-3's acceptance criteria are cabal-only: everything below is
verified with `cabal build` / `cabal test` from inside the dev shell. Be aware, though, that
`nix build` compiles the package through `callCabal2nix`, which resolves `build-depends`
from the nixpkgs Haskell package set — where `ClickHaskell` may be absent or older than
1.1.0 — and which does not honor `cabal.project` `source-repository-package` pins. After
adding the dependency, run `nix build` once to check: if it fails on `ClickHaskell`, record
that in Surprises & Discoveries as a known limitation to be resolved with a flake overlay
(pinning ClickHaskell into the Haskell package set) in a follow-up change. Do not treat a
red `nix build` as blocking this plan's acceptance, but do not silently assume it stays
green either.

**ClickHouse in this repo.** ClickHouse is the columnar database this plan targets. The
development shell's `shellHook` (in `nix/haskell.nix`) exports these environment variables
every time you enter `nix develop`:

- `CLICKHOUSE_HOME="$PWD/clickhouse"` — where the server keeps all of its state (data,
  logs, config). It is created automatically.
- `CLICKHOUSE_TCP_PORT=9000` — the native TCP protocol port. ClickHaskell (the Haskell
  client, see below) speaks this protocol.
- `CLICKHOUSE_HTTP_PORT=8123` — the HTTP interface port (not used by this plan, but the
  server listens on it too).

The server is started for you by `process-compose`. The file `process-compose.yaml` at the
repository root defines a `clickhouse` process that runs:

```bash
clickhouse-server --path=$CLICKHOUSE_HOME/ --tcp_port=$CLICKHOUSE_TCP_PORT \
  --http_port=$CLICKHOUSE_HTTP_PORT --listen_host=127.0.0.1 \
  --logger.log=$CLICKHOUSE_HOME/clickhouse-server.log \
  --logger.errorlog=$CLICKHOUSE_HOME/clickhouse-server.err.log
```

So the server listens only on `127.0.0.1` (localhost), TCP port `9000`. You start
everything with `process-compose up` from inside `nix develop`, or you can start just
ClickHouse manually with the command above. Its readiness probe in `process-compose.yaml` is
`clickhouse-client --port $CLICKHOUSE_TCP_PORT --query 'SELECT 1'` (the env var expands to
`9000` in the dev shell).

**`clickhouse-client`** is the official command-line SQL client, on your `PATH` from Nix.
You will use it to apply the schema file and to verify results. It connects to the native
TCP port; pass `--port 9000`.

**What EP-1 (the project skeleton plan) already created**, and which this plan builds on
(see the parent MasterPlan `docs/masterplans/1-kansoku-analytics-service-mvp.md`, "Exec-Plan
Registry" — EP-3 hard-depends on EP-1):

- `kansoku.cabal` — the Cabal package file describing the library and the
  `kansoku-server` executable. `nix/haskell.nix` builds it via
  `callCabal2nix "kansoku" inputs.self { }`. Its library stanza has `exposed-modules` and
  `build-depends` lists that later plans extend.
- `cabal.project` — the Cabal project file. EP-1 documents it as the place to add
  non-Hackage or pinned dependencies via `packages:` / `source-repository-package` stanzas.
- `Kansoku.Config` (in `src/Kansoku/Config.hs`) — a record parsed from environment
  variables, plus the pattern for adding fields to it. EP-1 already reads
  `PG_CONNECTION_STRING`, `CLICKHOUSE_TCP_PORT`, and `CLICKHOUSE_HTTP_PORT` from the
  environment.
- The `justfile` — the command-runner file that EP-1 creates, holding the Postgres
  `create-database` recipe that `process-compose.yaml` runs. It does not exist in the repo
  today; EP-3 only *appends* its `ch-migrate` recipe to the file EP-1 created.
- An **effectful** application runtime. "effectful" is the effect-system library the whole
  codebase uses: application code runs in a monad `Eff es` where `es` is a type-level list of
  capabilities (for example `IOE :> es` means "this code may perform arbitrary IO"). EP-1
  established the base effect stack (`IOE`, a `Reader Config`, logging) and the
  `runEff . …` interpreter chain in the `kansoku-server` executable, plus a `cabal test`
  test-suite stanza.

If, when you begin, `kansoku.cabal` / `cabal.project` / `Kansoku.Config` / the `justfile`
do not yet exist, EP-1 has not landed; do not proceed — EP-3 cannot compile (or register its
`ch-migrate` recipe) without them. Coordinate per the MasterPlan.

**The canonical event model and the EP-2 soft dependency.** The events this table stores
follow Kansoku's canonical event model. The normative TypeScript shape lives in
`docs/initial-spec.md` under "Canonical Event Model":

```text
type AnalyticsEvent = {
  eventId: string
  eventName: string
  source: "web" | "app" | "service" | "worker" | "email" | "agent"
  sourceService?: string
  occurredAt: string
  receivedAt: string
  anonymousId?: string
  userId?: string
  organizationId?: string
  accountId?: string
  sessionId?: string
  url?: string
  referrer?: string
  utmSource?: string
  utmMedium?: string
  utmCampaign?: string
  utmContent?: string
  utmTerm?: string
  correlationId?: string
  causationId?: string
  sourceEventId?: string
  sourceGlobalPosition?: number
  properties: Record<string, unknown>
  context: Record<string, unknown>
}
```

EP-2 (the "Canonical event model and schema registry" plan) owns the Haskell version of this
type: a record named `AnalyticsEvent` in `src/Kansoku/Event.hs` (module `Kansoku.Event`),
with `FromJSON`/`ToJSON` instances that define the on-the-wire JSON. EP-3 *soft*-depends on
EP-2: this plan's `EventRow` mirrors those fields and `eventRowFromEvent` maps
`Kansoku.Event.AnalyticsEvent` to an `EventRow`.

Because EP-3 may begin before EP-2 finishes, this plan defines a small **placeholder** event
type so the storage layer compiles and is testable on its own, and it states explicitly:
**the final mapping must consume `Kansoku.Event.AnalyticsEvent` once EP-2 lands.** The
placeholder is a temporary local record with exactly the fields above; when EP-2 is
available you delete the placeholder and change the import. This is called out again in the
Plan of Work (Milestone 2) and Interfaces sections. This is the shared-artifact contract the
MasterPlan records under "Integration Points → The `AnalyticsEvent` type" and "→ The
ClickHouse `analytics.events_raw` schema and `EventRow` type".

**ClickHaskell — the ClickHouse client library.** We use `ClickHaskell` (package name
`ClickHaskell`, version 1.1.0; upstream `github: KovalevDima/ClickHaskell`). It was chosen
over `scarf-sh/haskell-clickhouse` because it supports GHC 9.12.* (this repo pins
`ghc9124`) while the alternative is only tested on 9.8/9.10. The facts below were verified
by reading the library's own documentation and cabal file on disk (via the `mori` dependency
tool: `mori registry show KovalevDima/ClickHaskell --full`, sources under
`/Users/shinzui/Keikaku/hub/haskell/clickhaskell-project`). You do not need to read those;
everything required is embedded here.

- You import the module `ClickHaskell` (public re-exports) and, if you need the connection
  setters explicitly, `ClickHaskell.Connection`. The protocol is ClickHouse's native binary
  TCP protocol (port 9000). A `Connection` wraps an `MVar`, so it is thread-safe and can be
  shared across threads; a single connection serializes concurrent use.
- You open a connection with `openConnection` applied to modifiers composed onto
  `defaultConnectionArgs`:

  ```haskell
  openConnection
    $ setHost "127.0.0.1"
    . setPort "9000"
    . setUser "default"
    . setDatabase "analytics"
    $ defaultConnectionArgs
  ```

  The setters have types `setHost :: HostName -> ConnectionArgs -> ConnectionArgs`,
  `setPort :: ServiceName -> ConnectionArgs -> ConnectionArgs` (note: port is a *string*),
  `setUser`, `setPassword`, `setDatabase :: String -> ConnectionArgs -> ConnectionArgs`.
  `ping :: Connection -> IO ()` verifies liveness. `HostName` and `ServiceName` are the
  `network` package's `String` aliases.
- You describe a table's columns at the *type level* as a list of `Column name chType`, and
  you declare a matching Haskell record whose field names equal the column names; deriving the
  `ClickHaskell` class connects the two. Example from the library's docs:

  ```haskell
  type MyCols = '[ Column "id" Int64
                 , Column "name" ChString
                 , Column "created_at" (DateTime "")
                 ]

  data MyRow = MyRow
    { id         :: Int64
    , name       :: ByteString
    , created_at :: UTCTime
    } deriving (Generic, ClickHaskell MyCols)
  ```

- The Haskell-to-ClickHouse type conversions you need (verified from the library's type
  reference): ClickHouse `String` ↔ Haskell `ByteString` via the `ChString` newtype;
  `DateTime64 p tz` ↔ `UTCTime` (POSIX time scaled by `10^p`); `Nullable(T)` ↔ `Maybe`;
  `LowCardinality(T)` transparently wraps the inner type (so its Haskell field type is the
  same as the inner type's, e.g. `LowCardinality ChString` ↔ `ByteString`); `UInt64` is a
  type alias for `Word64`. `LowCardinality` may only wrap `ChString`, `DateTime`, or a
  `Nullable` of those — which is why `event_name`/`source` use `LowCardinality ChString`.
- Batch INSERT — the whole point of this plan — is:

  ```haskell
  insert :: ClickHaskell columns record => Insert columns record -> Connection -> [record] -> IO ()
  ```

  built with `intoTable`, e.g.
  `insert (intoTable @"events_raw" @EventColumns @EventRow) conn rows`. The list of records
  is written in one INSERT (one network round-trip), which is exactly the amortization the
  MasterPlan calls "high write throughput".
- SELECT is:

  ```haskell
  select :: ClickHaskell columns output => Select columns output -> Connection -> ([output] -> IO r) -> IO [r]
  ```

  built with `fromTable`, e.g. `select (fromTable @"events_raw" @EventColumns @EventRow) conn pure`.
  The callback runs once per **block** (ClickHouse streams results in blocks), and the
  results are collected into a list of the callback's results — so to get a flat list of rows
  you write `concat <$> select ... conn pure`.
- DDL / statements that return no rows use
  `command :: Connection -> Command -> IO ()`, where `Command` is an `IsString`, so you pass
  a SQL string literal:
  `command conn "CREATE DATABASE IF NOT EXISTS analytics"`.
- Errors from `command`/`select`/`insert` are thrown as exceptions of type `ClientError`.
  Its constructors, verified in the 1.1.0 source, are: `UnmatchedResult UserError` (the
  query result did not match the declared columns/types — the wrapped `UserError` is
  `UnmatchedColumn` for a column-name mismatch, `UnmatchedType` for a column-type mismatch,
  or `UnmatchedColumnsCount` for a column-count mismatch), `DatabaseException` (the server
  replied with an exception packet), and `InternalError`. Connection-level failures are a
  *separate* exception type, `ConnectionError`, with constructors `NoAdressResolved`,
  `EstablishTimeout`, and `ServerClosedConnection` (note upstream's spelling
  `NoAdressResolved`, one "d"). Catch them with `Control.Exception.try`/`catch` when you
  want to guard (the test uses this to skip when no server is running).

**Coding standards for the Haskell in this plan.** All Haskell added here follows the shared
conventions in `/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/core/` (`standards.md`,
`custom-prelude.md`, `record-patterns.md`, `multiline-strings.md`). In practice this means:
every module opens with `import Kansoku.Prelude` — the project prelude EP-1 exposes from the
`kansoku:kansoku-api` sub-library, which re-exports `Text`, `Generic`, aeson, `time`,
`NonEmpty`, and the `lens` operators — so individual modules do not re-import those. EP-1's
`common` cabal stanza sets `default-language: GHC2024` and
`default-extensions: DeriveAnyClass, DuplicateRecordFields, OverloadedLabels, OverloadedStrings,
MultilineStrings`, and every stanza does `import: common`; because of this the per-file
`{-# LANGUAGE ... #-}` pragmas you might expect are unnecessary. Qualified imports use the
postpositive form (`import Data.Text qualified as Text`, never `import qualified`). Records use
strict `!` fields with no field-name prefixes and explicit deriving
(`deriving stock (Generic, Eq, Show)`, `deriving anyclass (...)`, `deriving newtype (...)`).
Field reads and updates go through generic-lens `#label` access (`x ^. #field`, `x & #field .~ v`)
rather than record selectors or record-update syntax; a module that uses `#label` adds
`import Data.Generics.Labels ()`. Embedded SQL/DDL is written as a `"""..."""` MultilineString
literal, not `unlines` or an escaped one-liner. The `Kansoku.ClickHouse.*` modules below all
import `Kansoku.Prelude`; the `kansoku` library gains `ClickHaskell` as a runtime dependency, and
the generic-lens `#label` access relies on `generic-lens`/`lens`, which EP-1 already provides
transitively through the prelude.

**Where new files go.** This plan adds two library modules under `src/Kansoku/ClickHouse/`
and `src/Kansoku/ClickHouse.hs`, one SQL file under `db/clickhouse/migrations/`, one recipe in
the `justfile`, and one test module under `test/`. Full paths and contents are in the Plan of
Work and Concrete Steps.


## Plan of Work

The work is three milestones. Each is independently verifiable: the schema exists and is
inspectable with `clickhouse-client` before any Haskell is written; the Haskell round-trip is
provable with a test before deduplication is considered; deduplication is a separate,
demonstrable behavior. Do the milestones in order and commit at each boundary.

Before starting, from the repository root
`/Users/shinzui/Keikaku/bokuno/kansoku-project/kansoku`, enter the dev shell with
`nix develop` (all commands below assume you are inside it) and confirm EP-1's artifacts
exist by listing `kansoku.cabal`, `cabal.project`, `src/Kansoku/Config.hs`, and the
`justfile`. If any is missing, stop (see Context: EP-1 dependency).

### Milestone 1 — The schema exists and is verifiable

Scope: create the `analytics` database and the `analytics.events_raw` table, apply them
idempotently, and confirm with `clickhouse-client`. At the end of this milestone the table
exists with the correct columns, engine, ordering, and partitioning, and
`SELECT count() FROM analytics.events_raw` returns `0`. No Haskell yet.

First, make the migrations directory committable. This repository's `.gitignore` currently
ignores `db/` wholesale, because `db/` is the PostgreSQL state directory (the dev shell sets
`PGHOST=$PWD/db` and `PGDATA=db/db`). Left as-is, the migration file below could never be
committed: the `db/` pattern excludes the directory itself, and git cannot re-include any
path inside an excluded directory. Edit `.gitignore` and replace the single `db/` line with
these two lines — order matters, the negation must come after the wildcard:

```gitignore
db/*
!db/clickhouse/
```

`db/*` ignores every child of `db/` (so the Postgres socket and data directory stay
untracked), while `!db/clickhouse/` re-includes the `db/clickhouse/` subtree so migration
files are tracked. Verify both directions:

```bash
git check-ignore -v db/clickhouse/migrations/0001_events_raw.sql; echo "exit: $?"
git check-ignore -v db/db; echo "exit: $?"
```

Expected: the first command prints nothing and exits nonzero (`exit: 1`) — the migration
file is NOT ignored; the second prints the `db/*` rule and exits `0` — Postgres state is
still ignored. (See the Decision Log entry dated 2026-07-01 for why narrowing the ignore was
chosen over relocating the migrations.)

Now create the directory `db/clickhouse/migrations/` and the file
`db/clickhouse/migrations/0001_events_raw.sql` with the following exact content. Every column is typed deliberately per the Decision Log. The
sorting key is the spec's prefix with `event_id` appended so `ReplacingMergeTree`
deduplicates per event; the version column is `received_at`.

```sql
CREATE DATABASE IF NOT EXISTS analytics;

CREATE TABLE IF NOT EXISTS analytics.events_raw
(
    event_id               String,
    event_name             LowCardinality(String),
    source                 LowCardinality(String),
    source_service         Nullable(String),
    occurred_at            DateTime64(3, 'UTC'),
    received_at            DateTime64(3, 'UTC'),
    anonymous_id           Nullable(String),
    user_id                String,
    organization_id        Nullable(String),
    account_id             String,
    session_id             Nullable(String),
    url                    Nullable(String),
    referrer               Nullable(String),
    utm_source             Nullable(String),
    utm_medium             Nullable(String),
    utm_campaign           Nullable(String),
    utm_content            Nullable(String),
    utm_term               Nullable(String),
    correlation_id         Nullable(String),
    causation_id           Nullable(String),
    source_event_id        Nullable(String),
    source_global_position Nullable(UInt64),
    properties             String,
    context                String
)
ENGINE = ReplacingMergeTree(received_at)
PARTITION BY toYYYYMM(occurred_at)
ORDER BY (account_id, user_id, event_name, occurred_at, event_id);
```

Append a recipe to the repository `justfile`. To be precise about who owns what: no
`justfile` exists in the repository today — EP-1 creates it (with the Postgres
`create-database` recipe that `process-compose.yaml` runs), and EP-3 only *appends* the
`ch-migrate` recipe below. If the `justfile` is missing when you get here, EP-1 has not
landed; stop, per the precondition gate at the top of the Plan of Work. This is the
canonical `ch-migrate` recipe shared with EP-5: it applies every `db/clickhouse/migrations/*.sql`
file in filename order with the multi-statement flag, and is idempotent because every file uses
`IF NOT EXISTS`. The Postgres `create-database` recipe (from EP-1) is separate and unchanged:

```text
ch-migrate:
    for f in db/clickhouse/migrations/*.sql; do echo "applying $f"; clickhouse-client --port $CLICKHOUSE_TCP_PORT --multiquery < "$f"; done
```

Verify (Concrete Steps has the exact transcript): start ClickHouse, run
`just ch-migrate`, then `clickhouse-client --port 9000 --query 'DESCRIBE
analytics.events_raw'` and `... --query 'SELECT count() FROM analytics.events_raw'`.

Commit at the end of this milestone.

### Milestone 2 — The Haskell round-trip: `insertEvents` and select-back

Scope: add the ClickHaskell row mapping and the writer/reader functions, wire ClickHouse
config into `Kansoku.Config`, and prove with a test that a batch of events inserted via
`insertEvents` can be read back and matches. At the end, `cabal build` compiles the new
modules and `cabal test` runs a test that inserts and reads a batch (or skips cleanly if no
ClickHouse server is reachable).

First, make the dependency available. Know the Hackage reality up front: the latest
*released* version of `ClickHaskell` on Hackage is 1.0.0; version 1.1.0 exists only as a
Hackage *candidate* (uploaded but unpublished, invisible to cabal's dependency solver), so a
plain `ClickHaskell ^>=1.1` bound will not resolve from Hackage today. The git pin is
therefore the primary mechanism, not a fallback. Add the `source-repository-package` stanza
to `cabal.project` first (Concrete Steps shows the exact stanza; upstream is the monorepo
`https://github.com/KovalevDima/ClickHaskell` and the library's cabal file lives in the
`ClickHaskell/library` subdirectory — verified against the local corpus checkout of
v1.1.0), then add `ClickHaskell` to the `build-depends` of the library stanza in
`kansoku.cabal`, then `cabal build`. While editing `build-depends`, confirm `bytestring` is
already listed in the library stanza (EP-1 normally includes it; the modules below import
`Data.ByteString`) and add it if not — `Data.Word` comes from `base` and needs no entry.
After a green `cabal build`, also run `nix build` once; if it fails on `ClickHaskell`, record
the failure per the `nix build` note in Context and Orientation (known limitation, flake
overlay follow-up) rather than blocking here.

Create `src/Kansoku/ClickHouse/EventRow.hs`. It declares the type-level column schema
`EventColumns` (mirroring the SQL exactly, in the same column order), the Haskell record
`EventRow` whose field names equal the column names, and the total mapping
`eventRowFromEvent`. Field types follow the verified ClickHaskell conversions:
`ByteString` for `String`/`LowCardinality(String)` columns, `Maybe ByteString` for
`Nullable(String)`, `UTCTime` for `DateTime64(3,'UTC')`, `Maybe Word64` for
`Nullable(UInt64)`.

```haskell
module Kansoku.ClickHouse.EventRow
  ( EventColumns
  , EventRow (..)
  , eventRowFromEvent
    -- * Placeholder event type (remove once EP-2's Kansoku.Event lands)
  , PlaceholderEvent (..)
  ) where

-- The shared prelude (from the kansoku:kansoku-api sub-library EP-1 established)
-- provides Generic, UTCTime, fromMaybe, and the lens operators. The common cabal
-- stanza turns on DeriveAnyClass/OverloadedStrings and GHC2024 already provides
-- DataKinds/DerivingStrategies, so no per-file LANGUAGE pragmas are needed here.
import Kansoku.Prelude

import ClickHaskell (ChString, ClickHaskell, Column, DateTime64, LowCardinality, Nullable, UInt64)
import Data.ByteString (ByteString)
import Data.Generics.Labels ()  -- enables #label access in eventRowFromEvent
import Data.Word (Word64)

-- | The type-level schema for @analytics.events_raw@. It must mirror
-- @db/clickhouse/migrations/0001_events_raw.sql@ exactly, column-for-column and in order.
type EventColumns =
  '[ Column "event_id"               ChString
   , Column "event_name"             (LowCardinality ChString)
   , Column "source"                 (LowCardinality ChString)
   , Column "source_service"         (Nullable ChString)
   , Column "occurred_at"            (DateTime64 3 "UTC")
   , Column "received_at"            (DateTime64 3 "UTC")
   , Column "anonymous_id"           (Nullable ChString)
   , Column "user_id"                ChString
   , Column "organization_id"        (Nullable ChString)
   , Column "account_id"             ChString
   , Column "session_id"             (Nullable ChString)
   , Column "url"                    (Nullable ChString)
   , Column "referrer"               (Nullable ChString)
   , Column "utm_source"             (Nullable ChString)
   , Column "utm_medium"             (Nullable ChString)
   , Column "utm_campaign"           (Nullable ChString)
   , Column "utm_content"            (Nullable ChString)
   , Column "utm_term"               (Nullable ChString)
   , Column "correlation_id"         (Nullable ChString)
   , Column "causation_id"           (Nullable ChString)
   , Column "source_event_id"        (Nullable ChString)
   , Column "source_global_position" (Nullable UInt64)
   , Column "properties"             ChString
   , Column "context"                ChString
   ]

-- | A single row of @analytics.events_raw@. Field names must equal the column
-- names above; the derived 'ClickHaskell' instance connects the two.
data EventRow = EventRow
  { event_id               :: !ByteString
  , event_name             :: !ByteString
  , source                 :: !ByteString
  , source_service         :: !(Maybe ByteString)
  , occurred_at            :: !UTCTime
  , received_at            :: !UTCTime
  , anonymous_id           :: !(Maybe ByteString)
  , user_id                :: !ByteString
  , organization_id        :: !(Maybe ByteString)
  , account_id             :: !ByteString
  , session_id             :: !(Maybe ByteString)
  , url                    :: !(Maybe ByteString)
  , referrer               :: !(Maybe ByteString)
  , utm_source             :: !(Maybe ByteString)
  , utm_medium             :: !(Maybe ByteString)
  , utm_campaign           :: !(Maybe ByteString)
  , utm_content            :: !(Maybe ByteString)
  , utm_term               :: !(Maybe ByteString)
  , correlation_id         :: !(Maybe ByteString)
  , causation_id           :: !(Maybe ByteString)
  , source_event_id        :: !(Maybe ByteString)
  , source_global_position :: !(Maybe Word64)
  , properties             :: !ByteString
  , context                :: !ByteString
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ClickHaskell EventColumns)

-- | TEMPORARY placeholder mirroring EP-2's canonical event. Delete this and
-- import 'Kansoku.Event.AnalyticsEvent' once EP-2 lands; then change
-- 'eventRowFromEvent' to take that type. All fields use 'ByteString'/'Maybe'
-- to keep the mapping trivial; EP-2's type will use 'Text' and a 'Data.Aeson'
-- value for properties/context — adjust the conversions (encodeUtf8, encode)
-- accordingly at that point. Per the record-patterns standard, fields carry no
-- name prefixes; the few names shared with 'EventRow' in this module ('source',
-- 'url', 'referrer', 'properties', 'context') are fine because the common cabal
-- stanza enables DuplicateRecordFields and all access goes through
-- type-directed generic-lens '#label' optics.
data PlaceholderEvent = PlaceholderEvent
  { eventId              :: !ByteString
  , eventName            :: !ByteString
  , source               :: !ByteString
  , sourceService        :: !(Maybe ByteString)
  , occurredAt           :: !UTCTime
  , receivedAt           :: !UTCTime
  , anonymousId          :: !(Maybe ByteString)
  , userId               :: !(Maybe ByteString)
  , organizationId       :: !(Maybe ByteString)
  , accountId            :: !(Maybe ByteString)
  , sessionId            :: !(Maybe ByteString)
  , url                  :: !(Maybe ByteString)
  , referrer             :: !(Maybe ByteString)
  , utmSource            :: !(Maybe ByteString)
  , utmMedium            :: !(Maybe ByteString)
  , utmCampaign          :: !(Maybe ByteString)
  , utmContent           :: !(Maybe ByteString)
  , utmTerm              :: !(Maybe ByteString)
  , correlationId        :: !(Maybe ByteString)
  , causationId          :: !(Maybe ByteString)
  , sourceEventId        :: !(Maybe ByteString)
  , sourceGlobalPosition :: !(Maybe Word64)
  , properties           :: !ByteString  -- JSON text
  , context              :: !ByteString  -- JSON text
  }
  deriving stock (Generic, Eq, Show)

-- | Total mapping from a canonical event to a storage row. Field reads use
-- generic-lens '#label' access (enabled by the @Data.Generics.Labels ()@ import
-- above), per the record-patterns standard. Note the two sorting-key ids
-- collapse 'Nothing' to the empty string (see Decision Log).
eventRowFromEvent :: PlaceholderEvent -> EventRow
eventRowFromEvent e = EventRow
  { event_id               = e ^. #eventId
  , event_name             = e ^. #eventName
  , source                 = e ^. #source
  , source_service         = e ^. #sourceService
  , occurred_at            = e ^. #occurredAt
  , received_at            = e ^. #receivedAt
  , anonymous_id           = e ^. #anonymousId
  , user_id                = fromMaybe "" (e ^. #userId)
  , organization_id        = e ^. #organizationId
  , account_id             = fromMaybe "" (e ^. #accountId)
  , session_id             = e ^. #sessionId
  , url                    = e ^. #url
  , referrer               = e ^. #referrer
  , utm_source             = e ^. #utmSource
  , utm_medium             = e ^. #utmMedium
  , utm_campaign           = e ^. #utmCampaign
  , utm_content            = e ^. #utmContent
  , utm_term               = e ^. #utmTerm
  , correlation_id         = e ^. #correlationId
  , causation_id           = e ^. #causationId
  , source_event_id        = e ^. #sourceEventId
  , source_global_position = e ^. #sourceGlobalPosition
  , properties             = e ^. #properties
  , context                = e ^. #context
  }
```

Create `src/Kansoku/ClickHouse.hs` with the connection wiring and the writer/reader helpers.
It reads connection settings from a small `ClickHouseConfig` (populated from
`Kansoku.Config`, extended below). `ensureSchema` creates the database and table via
`command` (idempotently), matching the SQL file; it runs against a bootstrap connection to
the `default` database because you cannot connect to `analytics` before it exists, and it
creates the table by its fully-qualified name.

```haskell
module Kansoku.ClickHouse
  ( ClickHouseConfig (..)
  , openClickHouse
  , openBootstrapConnection
  , ensureSchema
  , insertEvents
  , selectAllEvents
  , countEvents
  ) where

-- The shared prelude supplies Generic and the lens operators; the common cabal
-- stanza enables OverloadedStrings + MultilineStrings and GHC2024 provides
-- DataKinds/TypeApplications, so no per-file LANGUAGE pragmas are needed.
import Kansoku.Prelude

import ClickHaskell
  ( Connection
  , command
  , defaultConnectionArgs
  , fromTable
  , insert
  , intoTable
  , openConnection
  , select
  , setDatabase
  , setHost
  , setPort
  , setUser
  )
import Data.Generics.Labels ()  -- enables #label access below
import Kansoku.ClickHouse.EventRow (EventColumns, EventRow, PlaceholderEvent, eventRowFromEvent)

-- | Connection settings for ClickHouse, derived from 'Kansoku.Config'.
data ClickHouseConfig = ClickHouseConfig
  { chHost     :: !String  -- e.g. "127.0.0.1"
  , chTcpPort  :: !String  -- native TCP port as a string, e.g. "9000"
  , chUser     :: !String  -- e.g. "default"
  , chDatabase :: !String  -- e.g. "analytics"
  }
  deriving stock (Generic, Eq, Show)

-- | Open a working connection to the analytics database (used by insert/select
-- after the schema exists).
openClickHouse :: ClickHouseConfig -> IO Connection
openClickHouse cfg =
  openConnection
    $ setHost (cfg ^. #chHost)
    . setPort (cfg ^. #chTcpPort)
    . setUser (cfg ^. #chUser)
    . setDatabase (cfg ^. #chDatabase)
    $ defaultConnectionArgs

-- | Open a connection to the "default" database, used only to create the
-- analytics database/table (you cannot connect to a database that does not
-- exist yet).
openBootstrapConnection :: ClickHouseConfig -> IO Connection
openBootstrapConnection cfg =
  openConnection
    $ setHost (cfg ^. #chHost)
    . setPort (cfg ^. #chTcpPort)
    . setUser (cfg ^. #chUser)
    . setDatabase "default"
    $ defaultConnectionArgs

-- | Create the analytics database and events_raw table idempotently. Mirrors
-- db/clickhouse/migrations/0001_events_raw.sql. Run with a bootstrap connection.
-- The DDL is written as a @MultilineStrings@ literal (@"""..."""@); the common
-- cabal stanza enables both @MultilineStrings@ and @OverloadedStrings@, so the
-- literal is accepted directly as ClickHaskell's @Command@ (an @IsString@) with
-- no escaping or @unlines@ noise. Keep it column-for-column identical (same
-- columns, types, engine, keys) to db/clickhouse/migrations/0001_events_raw.sql;
-- whitespace/comma layout may differ.
ensureSchema :: Connection -> IO ()
ensureSchema conn = do
  command conn "CREATE DATABASE IF NOT EXISTS analytics"
  command conn
    """
    CREATE TABLE IF NOT EXISTS analytics.events_raw
    ( event_id               String
    , event_name             LowCardinality(String)
    , source                 LowCardinality(String)
    , source_service         Nullable(String)
    , occurred_at            DateTime64(3, 'UTC')
    , received_at            DateTime64(3, 'UTC')
    , anonymous_id           Nullable(String)
    , user_id                String
    , organization_id        Nullable(String)
    , account_id             String
    , session_id             Nullable(String)
    , url                    Nullable(String)
    , referrer               Nullable(String)
    , utm_source             Nullable(String)
    , utm_medium             Nullable(String)
    , utm_campaign           Nullable(String)
    , utm_content            Nullable(String)
    , utm_term               Nullable(String)
    , correlation_id         Nullable(String)
    , causation_id           Nullable(String)
    , source_event_id        Nullable(String)
    , source_global_position Nullable(UInt64)
    , properties             String
    , context                String
    )
    ENGINE = ReplacingMergeTree(received_at)
    PARTITION BY toYYYYMM(occurred_at)
    ORDER BY (account_id, user_id, event_name, occurred_at, event_id)
    """

-- | Batch insert: map every event to a row and write them all in one INSERT.
-- Replace 'PlaceholderEvent' with 'Kansoku.Event.AnalyticsEvent' once EP-2 lands.
insertEvents :: Connection -> [PlaceholderEvent] -> IO ()
insertEvents conn evs =
  insert (intoTable @"events_raw" @EventColumns @EventRow) conn (map eventRowFromEvent evs)

-- | Read every row back (verification helper). Flattens the per-block results.
selectAllEvents :: Connection -> IO [EventRow]
selectAllEvents conn =
  concat <$> select (fromTable @"events_raw" @EventColumns @EventRow) conn pure

-- | Count rows by reading them back and taking the length. (A dedicated
-- SELECT count() would need an unsafe select builder; for verification the
-- length of selectAllEvents is sufficient and avoids extra machinery.)
countEvents :: Connection -> IO Int
countEvents = fmap length . selectAllEvents
```

Extend `Kansoku.Config` (in `src/Kansoku/Config.hs`) following EP-1's documented pattern:
add fields `clickHouseHost`, `clickHouseTcpPort`, and `clickHouseDatabase` to the `Config`
record, populate them in the env-parsing function (`clickHouseHost = "127.0.0.1"` as a
constant since the dev server binds localhost; `clickHouseTcpPort` from the environment
variable `CLICKHOUSE_TCP_PORT`, defaulting to `"9000"`; `clickHouseDatabase = "analytics"`
as a constant). Provide a helper to project a `ClickHouseConfig` from `Config`, e.g. in
`Kansoku.ClickHouse` or `Kansoku.Config`:

```haskell
-- Add `import Data.Generics.Labels ()` to whichever module hosts this helper so
-- the #label reads over 'Config' resolve (per the record-patterns standard).
clickHouseConfigFromConfig :: Config -> ClickHouseConfig
clickHouseConfigFromConfig c = ClickHouseConfig
  { chHost     = c ^. #clickHouseHost
  , chTcpPort  = c ^. #clickHouseTcpPort
  , chUser     = "default"
  , chDatabase = c ^. #clickHouseDatabase
  }
```

This satisfies the MasterPlan's "configuration module and effectful runtime stack"
integration point: EP-3 extends `Config` rather than inventing a parallel one. A dedicated
dynamic `ClickHouse` effect is deliberately *not* added — keeping the helpers as plain `IO`
that the effectful runtime calls via `liftIO`/`withRunInIO` is simpler and sufficient for
this storage layer. If a later plan wants a first-class effect it can wrap these.

Add both new modules to the library `exposed-modules` in `kansoku.cabal`:
`Kansoku.ClickHouse` and `Kansoku.ClickHouse.EventRow`.

Write the test `test/Kansoku/ClickHouseSpec.hs`, registered in the test-suite EP-1 created.
It is **guarded**: it first tries to open a bootstrap connection and `ping`; if that throws
(no server running), it prints a skip notice and passes trivially, so `cabal test` never
fails merely because ClickHouse is not up. When the server is reachable, it: calls
`ensureSchema`; truncates the table for a clean slate (`command conn "TRUNCATE TABLE
analytics.events_raw"`); builds a small list of `PlaceholderEvent`s (at least two distinct
events); calls `insertEvents`; then `selectAllEvents`/`countEvents` and asserts the count
equals the number of distinct events inserted and that a known field (e.g. `event_name`)
round-tripped. The test-suite framework is whatever EP-1 chose; if EP-1 used `tasty`/`hspec`
follow it, otherwise a plain `main :: IO ()` with `error` on failure is acceptable. The
Concrete Steps section gives the guard pattern.

Verify: `cabal build`, then start ClickHouse and `cabal test`. Commit.

### Milestone 3 — Deduplication demonstrated

Scope: prove the at-least-once safety net. Insert the *same* `event_id` twice (as would
happen when a redelivered queue batch is re-inserted), force ClickHouse to merge parts, and
observe a single surviving row.

`ReplacingMergeTree` collapses rows that share the full `ORDER BY` sorting key only during
background merges, which happen asynchronously and unpredictably. Two ways to observe the
collapsed state deterministically: run `OPTIMIZE TABLE analytics.events_raw FINAL` to force a
merge now, or read with `SELECT ... FINAL` which applies the collapse at query time. This
plan demonstrates both — `OPTIMIZE ... FINAL` for the physical merge and `SELECT count()
FROM analytics.events_raw FINAL` for the query-time view.

Add a second test case (or a `clickhouse-client` transcript in Concrete Steps, or both):
truncate; insert a batch of one event; insert the *same* event again (same `event_id` and
identical sorting-key fields); observe `count()` returns `2` before the merge; run
`OPTIMIZE TABLE analytics.events_raw FINAL`; observe `count()` returns `1`. Because
`selectAllEvents`/`fromTable` do not emit `FINAL`, the Haskell count-after-optimize path is
the reliable one; the `FINAL`-at-query-time demonstration is done via `clickhouse-client`
(shown in Concrete Steps).

Document the semantics here and in the Decision Log for EP-5 (materialized views) and EP-6
(queries): duplicates may transiently exist between insert and merge, so any query that must
not double-count must either read with `FINAL` or use deduplication-aware aggregation (for
example `count(DISTINCT event_id)` or `argMax`-based rollups keyed on `event_id`). This is
the MasterPlan's "ClickHouse `analytics.events_raw` schema" integration-point contract.

Two further boundary facts matter for downstream plans. First, the dedup key is the *full*
`ORDER BY` tuple, not `event_id` alone: rows that share an `event_id` but differ in any
other sort-key field (for example a replay that carries a corrected `occurred_at`) do NOT
collapse — both rows remain. Second, `ReplacingMergeTree` deduplication is partition-local
(merges never combine rows across partitions), which is harmless here because identical
sort keys imply the same `occurred_at` and therefore the same `toYYYYMM(occurred_at)`
partition.

A performance note on insert cadence, for the same batching context: every `insertEvents`
call produces one new ClickHouse *part* (the on-disk unit that background merges operate
on), and sustained small, frequent inserts create merge pressure that ClickHouse eventually
rejects with a "too many parts" error. That is exactly why the EP-4 writer accumulates
events and flushes large batches on a multi-second window instead of inserting per event.
`insertEvents` itself makes no promises about batching cadence — callers own that
responsibility.

Verify with the transcript in Concrete Steps. Commit.


## Concrete Steps

All commands run from the repository root
`/Users/shinzui/Keikaku/bokuno/kansoku-project/kansoku`, inside `nix develop`.

**Start ClickHouse.** Either start all dev services:

```bash
process-compose up
```

or start ClickHouse alone in the background:

```bash
clickhouse-server --path=$CLICKHOUSE_HOME/ --tcp_port=$CLICKHOUSE_TCP_PORT \
  --http_port=$CLICKHOUSE_HTTP_PORT --listen_host=127.0.0.1 \
  --logger.log=$CLICKHOUSE_HOME/clickhouse-server.log \
  --logger.errorlog=$CLICKHOUSE_HOME/clickhouse-server.err.log &
```

Confirm it is up (this is the same readiness check `process-compose.yaml` uses, verbatim):

```bash
clickhouse-client --port $CLICKHOUSE_TCP_PORT --query 'SELECT 1'
```

Expected:

```text
1
```

**Milestone 1 — apply and verify the schema.**

```bash
just ch-migrate
```

Running it a second time must succeed with no error (idempotent). Then describe the table:

```bash
clickhouse-client --port 9000 --query 'DESCRIBE analytics.events_raw' | head -6
```

Expected (first rows; columns are name, type, …):

```text
event_id	String
event_name	LowCardinality(String)
source	LowCardinality(String)
source_service	Nullable(String)
occurred_at	DateTime64(3, 'UTC')
received_at	DateTime64(3, 'UTC')
```

Confirm it is empty:

```bash
clickhouse-client --port 9000 --query 'SELECT count() FROM analytics.events_raw'
```

Expected:

```text
0
```

Confirm the engine, sorting key, and partitioning were applied:

```bash
clickhouse-client --port 9000 --query \
  "SELECT engine, sorting_key, partition_key FROM system.tables WHERE database='analytics' AND name='events_raw'"
```

Expected:

```text
ReplacingMergeTree	account_id, user_id, event_name, occurred_at, event_id	toYYYYMM(occurred_at)
```

**Milestone 2 — build and test the Haskell round-trip.**

Add the pinned source to `cabal.project` first — this is the primary mechanism, because
Hackage's newest *release* of `ClickHaskell` is 1.0.0 and 1.1.0 exists only as a Hackage
candidate, which cabal's solver never considers. The upstream is a monorepo; the library's
cabal file lives in the `ClickHaskell/library` subdirectory (verified against the local
corpus checkout of v1.1.0, where `ClickHaskell/library/ClickHaskell.cabal` declares
`Name: ClickHaskell`, `Version: 1.1.0`). If the `v1.1.0` tag is absent upstream, pin a
known-good commit hash instead:

```text
source-repository-package
    type: git
    location: https://github.com/KovalevDima/ClickHaskell.git
    tag: v1.1.0
    subdir: ClickHaskell/library
```

Then add `ClickHaskell` to the library `build-depends` in `kansoku.cabal` (confirming
`bytestring` is present there, adding it if not) and build:

```bash
cabal build
```

After a green `cabal build`, run `nix build` once as a check; a ClickHaskell-related failure
there is a recorded known limitation (see the `nix build` note in Context and Orientation),
not a blocker. The guarded test pattern (framework-neutral core) looks like:

```haskell
import Kansoku.Prelude

import ClickHaskell (Connection, ping)
import Control.Exception (SomeException, try)
import Kansoku.ClickHouse

-- Attempt a connection; skip the ClickHouse tests if the server is down.
-- (The test module also imports the prelude; the common stanza provides
-- OverloadedStrings/GHC2024's TypeApplications, so no per-file pragmas.)
withClickHouseOrSkip :: ClickHouseConfig -> (Connection -> IO ()) -> IO ()
withClickHouseOrSkip cfg body = do
  r <- try @SomeException (do c <- openBootstrapConnection cfg; ping c; pure c)
  case r of
    Left err -> putStrLn ("SKIP ClickHouse tests (no server): " <> show err)
    Right c  -> body c
```

Run the suite with ClickHouse up:

```bash
cabal test
```

Expected (an approximate transcript; exact wording depends on EP-1's test framework):

```text
Kansoku.ClickHouse: insert/select round-trip: OK
Kansoku.ClickHouse: deduplication collapses replay: OK
All N tests passed
```

With ClickHouse down, the same command still passes, printing the skip notice:

```text
SKIP ClickHouse tests (no server): ...
All N tests passed
```

**Milestone 3 — deduplication transcript.** Reset the table and insert one event twice with
`clickhouse-client` (identical sorting-key fields, including `event_id`):

```bash
clickhouse-client --port 9000 --query 'TRUNCATE TABLE analytics.events_raw'
clickhouse-client --port 9000 --query \
  "INSERT INTO analytics.events_raw (event_id, event_name, source, occurred_at, received_at, account_id, user_id, properties, context) \
   VALUES ('evt-1','page_viewed','web','2026-07-01 00:00:00.000','2026-07-01 00:00:01.000','acct-1','user-1','{}','{}')"
clickhouse-client --port 9000 --query \
  "INSERT INTO analytics.events_raw (event_id, event_name, source, occurred_at, received_at, account_id, user_id, properties, context) \
   VALUES ('evt-1','page_viewed','web','2026-07-01 00:00:00.000','2026-07-01 00:00:02.000','acct-1','user-1','{}','{}')"
```

Before the merge, both rows are present:

```bash
clickhouse-client --port 9000 --query 'SELECT count() FROM analytics.events_raw'
```

Expected:

```text
2
```

Query-time collapse without merging, and forced physical merge:

```bash
clickhouse-client --port 9000 --query 'SELECT count() FROM analytics.events_raw FINAL'
clickhouse-client --port 9000 --query 'OPTIMIZE TABLE analytics.events_raw FINAL'
clickhouse-client --port 9000 --query 'SELECT count() FROM analytics.events_raw'
```

Expected (the `FINAL` count is 1; after `OPTIMIZE` the physical count is 1; the surviving
row is the one with the larger `received_at`, i.e. `00:00:02.000`):

```text
1
1
```

**Commit trailers.** Every commit in this plan uses Conventional Commits and appends the
coordination trailers below (they tie the commit to the MasterPlan, this ExecPlan, and the
intention). Do not create a branch; commit to the current branch. Example:

```text
feat(clickhouse): add analytics.events_raw schema and batched insertEvents

Create the ReplacingMergeTree events_raw table (dedup on event_id via the
sorting key), the ClickHaskell EventRow mapping, and insertEvents/selectAllEvents
with a guarded round-trip test.

MasterPlan: docs/masterplans/1-kansoku-analytics-service-mvp.md
ExecPlan: docs/plans/3-clickhouse-storage-schema-and-batch-writer.md
Intention: intention_01kwf425fxenc904ear54cr2n7
```


## Validation and Acceptance

The plan is accepted when all of the following are observable from inside `nix develop` at
the repository root, with ClickHouse running:

1. `git check-ignore -v db/clickhouse/migrations/0001_events_raw.sql` exits nonzero (the
   migration file is committable), while `git check-ignore db/db` still exits `0` (Postgres
   state stays ignored); `just ch-migrate` applies the schema and is safe to run repeatedly;
   `clickhouse-client --port 9000 --query 'SELECT count() FROM analytics.events_raw'`
   returns a number (`0` on a fresh table).
2. `system.tables` reports engine `ReplacingMergeTree`, sorting key
   `account_id, user_id, event_name, occurred_at, event_id`, and partition key
   `toYYYYMM(occurred_at)` for `analytics.events_raw` (transcript above).
3. `cabal build` compiles `Kansoku.ClickHouse` and `Kansoku.ClickHouse.EventRow`.
4. `cabal test` passes: the round-trip test inserts a batch via `insertEvents` and reads it
   back with matching count and content; with ClickHouse down the suite still passes by
   skipping the ClickHouse test with a printed notice.
5. The deduplication demonstration shows `count()` of `2` after inserting a duplicate
   `event_id`, and `1` after `OPTIMIZE TABLE analytics.events_raw FINAL` (and via
   `SELECT count() ... FINAL`).

Acceptance is behavioral: a batch of events written in a single `insertEvents` call is
durably queryable, and replayed duplicates collapse to one row. This proves the storage
foundation that EP-4 (the batched writer) inserts into, and that EP-5/EP-6 read from.


## Idempotence and Recovery

Every schema step is idempotent. The SQL file and `ensureSchema` use
`CREATE DATABASE IF NOT EXISTS` and `CREATE TABLE IF NOT EXISTS`, so applying them any number
of times leaves the same result and never errors on an existing table. `just
ch-migrate` can be re-run freely.

The data path is idempotent by design: because the table is `ReplacingMergeTree` with the
sorting key made unique per `event_id`, re-inserting an already-stored event does not create
a permanent duplicate — the replay collapses on the next merge (or immediately with
`OPTIMIZE ... FINAL`). This is exactly the recovery property EP-4's at-least-once writer
relies on: if a crash replays a batch after a successful insert, no double-counting results
once merged, and dedup-aware queries (`FINAL` / `count(DISTINCT event_id)`) never see the
transient duplicate.

If a test leaves rows behind, reset with
`clickhouse-client --port 9000 --query 'TRUNCATE TABLE analytics.events_raw'`. To rebuild the
table from scratch (for example after changing a column type during development), drop and
re-apply: `clickhouse-client --port 9000 --query 'DROP TABLE IF EXISTS
analytics.events_raw'` then `just ch-migrate`. To wipe all ClickHouse state
entirely, stop the server and delete `$CLICKHOUSE_HOME` (it is recreated on next entry to
`nix develop`).

If `cabal build` fails to resolve `ClickHaskell`, check that the `source-repository-package`
stanza in `cabal.project` (the primary mechanism — Hackage cannot supply 1.1.0; see Concrete
Steps) is present and that its `tag` and `subdir` are correct. If a schema mismatch surfaces
at runtime as a ClickHaskell `ClientError` of the form `UnmatchedResult (UnmatchedColumn …)`
or `UnmatchedResult (UnmatchedType …)` (constructor names verified in the 1.1.0 source;
`UnmatchedResult` wraps a `UserError`), the
`EventColumns` type-level list has drifted from the actual table DDL — reconcile
`db/clickhouse/migrations/0001_events_raw.sql`, the `ensureSchema` string, and `EventColumns` so all
three agree (they must always be identical, column-for-column).


## Interfaces and Dependencies

**Libraries.** `ClickHaskell` (version 1.1.0; module `ClickHaskell`, plus
`ClickHaskell.Connection` for setters) is the ClickHouse client, chosen for GHC 9.12.*
support and type-safe `Generic`-derived batch inserts/selects (MasterPlan Decision Log). It
is supplied by the `cabal.project` git pin, not Hackage: the Hackage release lags at 1.0.0
and 1.1.0 is only a Hackage candidate (see the Decision Log and Concrete Steps). No
other new runtime dependency. `clickhouse-client` and `clickhouse-server` come from Nix
(`pkgs.clickhouse`), already in the dev shell.

**Hard dependency: EP-1.** This plan adds modules to the `kansoku` library and depends on
`Kansoku.Config` and the effectful runtime EP-1 created. It cannot compile without
`kansoku.cabal`, `cabal.project`, and `src/Kansoku/Config.hs`. The new `Kansoku.ClickHouse.*`
modules `import Kansoku.Prelude` (EP-1's `kansoku:kansoku-api` sub-library) and use generic-lens
`#label` access, which relies on the `generic-lens`/`lens` packages the prelude already re-exports
(each such module adds `import Data.Generics.Labels ()`); `ClickHaskell` is the only new
`build-depends` entry this plan itself introduces, provided `bytestring` is already in the
library stanza (EP-1 normally lists it — the sketches import `Data.ByteString`); confirm it
is there and add it if not. `Data.Word` is part of `base` and needs no entry. This plan also
depends on EP-1's `justfile` existing, since it appends the `ch-migrate` recipe to it.

**Soft dependency: EP-2.** `eventRowFromEvent` must ultimately consume
`Kansoku.Event.AnalyticsEvent` (the record in `src/Kansoku/Event.hs`, field names/optionality
matching `docs/initial-spec.md`). Until EP-2 lands, this plan uses the local
`PlaceholderEvent` in `Kansoku.ClickHouse.EventRow`; the completion step is to delete
`PlaceholderEvent`, import `Kansoku.Event.AnalyticsEvent`, and adjust conversions (EP-2's
type will use `Text` — convert with `Data.Text.Encoding.encodeUtf8` — and `Data.Aeson.Value`
for `properties`/`context` — convert with `Data.Aeson.encode` to JSON bytes).

**Modules and signatures that must exist at the end of this plan** (full paths):

- `src/Kansoku/ClickHouse/EventRow.hs`, module `Kansoku.ClickHouse.EventRow`, exporting:
  - `type EventColumns` — the type-level ClickHouse column schema (24 columns, listed above),
    mirroring `db/clickhouse/migrations/0001_events_raw.sql` exactly.
  - `data EventRow` with strict `!` fields named identically to the columns,
    `deriving stock (Generic, Eq, Show)` and `deriving anyclass (ClickHaskell EventColumns)`.
  - `eventRowFromEvent :: PlaceholderEvent -> EventRow` (final:
    `Kansoku.Event.AnalyticsEvent -> EventRow`), a total function.
- `src/Kansoku/ClickHouse.hs`, module `Kansoku.ClickHouse`, exporting:
  - `data ClickHouseConfig` (host, tcp port as `String`, user, database).
  - `openClickHouse :: ClickHouseConfig -> IO Connection` (connects to the `analytics` db).
  - `openBootstrapConnection :: ClickHouseConfig -> IO Connection` (connects to `default`,
    for schema creation).
  - `ensureSchema :: Connection -> IO ()` (idempotent `CREATE DATABASE`/`CREATE TABLE`).
  - `insertEvents :: Connection -> [PlaceholderEvent] -> IO ()` (final: `[AnalyticsEvent]`),
    the batched single-INSERT writer.
  - `selectAllEvents :: Connection -> IO [EventRow]` and `countEvents :: Connection -> IO Int`
    (verification helpers).
- `src/Kansoku/Config.hs` (extended): `Config` gains `clickHouseHost :: String`,
  `clickHouseTcpPort :: String`, `clickHouseDatabase :: String`, read from the environment
  (`CLICKHOUSE_TCP_PORT`, defaulting to `"9000"`) per EP-1's pattern, plus a
  `clickHouseConfigFromConfig :: Config -> ClickHouseConfig` projection.
- `db/clickhouse/migrations/0001_events_raw.sql` — the canonical DDL (source of truth for the schema).
- `justfile` recipe `ch-migrate` (the canonical migration recipe shared with EP-5; applies
  every `db/clickhouse/migrations/*.sql` in filename order).
- `test/Kansoku/ClickHouseSpec.hs` — the guarded round-trip and deduplication test.
- `kansoku.cabal` — `ClickHaskell` added to library `build-depends` (and `bytestring` if it
  was not already listed); `Kansoku.ClickHouse` and `Kansoku.ClickHouse.EventRow` added to
  `exposed-modules`.
- `cabal.project` — the `source-repository-package` pin for `ClickHaskell` v1.1.0 (subdir
  `ClickHaskell/library`), the primary way the dependency is supplied.
- `.gitignore` — the `db/` line narrowed to `db/*` plus `!db/clickhouse/` so the migrations
  are tracked while Postgres state stays ignored.

**Downstream consumers** (do not build here, but must not be broken): EP-4 calls
`insertEvents` from its shibuya batch writer; EP-5 builds materialized views whose `SELECT`
reads these exact column names; EP-6 queries the table and rollups. Any column addition must
change `db/clickhouse/migrations/0001_events_raw.sql`, the `ensureSchema` string, and `EventColumns`
together, then cascade to those plans (MasterPlan "Integration Points → The ClickHouse
`analytics.events_raw` schema and `EventRow` type").


## Revision Note

- Revision (2026-07-01): Brought every Haskell code sketch into compliance with the shared
  standards in `/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/core/` without changing any
  design decision. Concretely: replaced per-file `{-# LANGUAGE #-}` pragmas and scattered
  base/text/time/aeson imports with a single `import Kansoku.Prelude` (EP-1's
  `kansoku:kansoku-api` prelude); made all imports postpositive-`qualified` where qualified;
  gave `EventRow`, `PlaceholderEvent`, and `ClickHouseConfig` strict `!` fields with explicit
  `deriving stock`/`deriving anyclass` clauses; switched `eventRowFromEvent`,
  `clickHouseConfigFromConfig`, and the connection helpers to generic-lens `#label` access
  (adding `import Data.Generics.Labels ()` where `#label` is used); and rewrote the
  `ensureSchema` DDL from an escaped `\...\` one-liner into a `"""..."""` MultilineString
  literal. Also added a "Coding standards" paragraph to Context and Orientation pointing at the
  core docs and EP-1's prelude/`common` stanza. The `.sql` migration file under
  `db/clickhouse/migrations/` was left as a plain `sql` fenced block (it is a file, not
  Haskell-embedded SQL). Reason: the plan's Haskell must match the project's house style so a
  novice following it produces code that compiles cleanly under the `common` stanza and passes
  review; none of the schema, dedup strategy, migration layout, or module boundaries changed.

- Revision (2026-07-01, pre-implementation validation pass): Fixed eleven issues found by
  validating the plan against the actual repository and the ClickHaskell 1.1.0 source, before
  any implementation began. (1) BLOCKER: the repo's `.gitignore` ignores `db/` wholesale (it
  is the Postgres state directory), so the planned migration file was uncommittable; added an
  explicit early step to Milestone 1 (narrow the ignore to `db/*` + `!db/clickhouse/`, with
  `git check-ignore` verification), a Progress item, a dated Decision Log entry, and an
  acceptance check — the migration path itself is unchanged, per the MasterPlan-level
  decision. (2) Made the `cabal.project` `source-repository-package` git pin the *primary*
  mechanism for `ClickHaskell` (Hackage's latest release is 1.0.0; 1.1.0 exists only as a
  Hackage candidate, so plain Hackage resolution cannot work); verified the `ClickHaskell/library`
  subdir against the corpus checkout; added a Decision Log entry and updated Progress,
  Milestone 2, Concrete Steps, Recovery, and Interfaces to match. (3) Replaced the "you do
  not need to edit `nix/haskell.nix`" claim with an honest note: acceptance stays cabal-only,
  but `nix build` resolves deps via `callCabal2nix` from nixpkgs and may fail on ClickHaskell;
  check it once and record a failure as a known limitation for a flake-overlay follow-up.
  (4) Corrected the false claim that the `justfile` "already contains a create-database
  recipe" — no `justfile` exists today; EP-1 creates it and EP-3 appends `ch-migrate`; the
  `justfile` was added to the EP-1 precondition gate everywhere it appears. (5) Added
  `--port $CLICKHOUSE_TCP_PORT` to the `ch-migrate` recipe and corrected the quoted
  process-compose readiness probe to its actual form (`--port $CLICKHOUSE_TCP_PORT`, not
  `--port 9000`). (6) Softened "byte-for-byte identical" between `ensureSchema` and the
  `.sql` file to "column-for-column identical (same columns, types, engine, keys)" — the two
  texts legitimately differ in layout. (7) Reconciled the error-name inconsistency using the
  verified 1.1.0 source: `ClientError`'s constructors are `UnmatchedResult UserError`,
  `DatabaseException`, and `InternalError`; `UserError`'s are `UnmatchedType`,
  `UnmatchedColumn`, and `UnmatchedColumnsCount`; connection failures are the separate
  `ConnectionError` type (`NoAdressResolved`, `EstablishTimeout`, `ServerClosedConnection`) —
  both the Context bullet and the Recovery section now use these names consistently.
  (8) Documented two dedup gaps in Milestone 3: the dedup key is the full `ORDER BY` tuple
  (rows sharing `event_id` but differing in any other sort-key field do not collapse), and
  ReplacingMergeTree dedup is partition-local (harmless here — identical sort keys imply the
  same `toYYYYMM` partition). (9) Dropped the `pe` field prefixes from `PlaceholderEvent`,
  which violated the plan's own no-prefix standard; the few names shared with `EventRow` are
  handled by `DuplicateRecordFields` and type-directed `#label` optics. (10) Qualified the
  "`ClickHaskell` is the only new build-depends entry" claim: confirm `bytestring` is already
  in the library stanza (the sketches import `Data.ByteString`) and add it if not.
  (11) Added a performance paragraph (from an architecture review) to Milestone 3: each
  `insertEvents` call creates one ClickHouse part, so sustained small inserts create merge
  pressure ("too many parts"); EP-4's writer flushes large batches on a multi-second window,
  and `insertEvents` makes no batching-cadence promises — callers own cadence.
