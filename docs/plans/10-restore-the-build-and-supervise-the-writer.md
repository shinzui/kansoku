---
id: 10
slug: restore-the-build-and-supervise-the-writer
title: "Restore the build and supervise the writer"
kind: exec-plan
created_at: 2026-07-15T21:30:34Z
intention: intention_01kxr5jt2heyvt0n768ym9dwqd
master_plan: "docs/masterplans/2-kansoku-production-hardening-review-fixes-and-portfolio-service-readiness.md"
---

# Restore the build and supervise the writer

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.

This is EP-10 of the MasterPlan at
`docs/masterplans/2-kansoku-production-hardening-review-fixes-and-portfolio-service-readiness.md`
(Phase 1 — Stabilize). It hard-depends on EP-21,
`docs/plans/21-migrate-kansoku-to-the-coherent-pg-migrate-pgmq-and-shibuya-cohort.md`,
and every later child plan hard- or soft-depends on EP-10. EP-21 owns the cohort and
migration cutover; this plan remains small enough to land in one sitting.


## Purpose / Big Picture

EP-21 must first leave Kansoku compiling against one portable pg-migrate/PGMQ/Shibuya cohort,
with current runtime APIs and an explicit PGMQ-only migration executable. Milestone 1 verifies
that checked-in result rather than owning or rerunning the migration. Even before the dependency
breaks,
the service had a silent-failure mode: the batch writer (the background thread that moves
events from the pgmq queue in Postgres into ClickHouse) runs under `withAsync`, which does
not propagate the writer's death to the main thread. If the writer dies, Warp keeps
answering `202 Accepted` on the ingest endpoints while events pile up in pgmq forever and
nothing ever reaches ClickHouse. There is also no way for an orchestrator to ask "is this
instance actually able to do its job?" — only `GET /health`, which is a static 200. Finally,
two HTTP handlers leak internal exception text (which can include hostnames and connection
strings) into 503 response bodies, and the ClickHouse host, database, user, and password are
hardcoded.

After this plan: `cabal build all` and `cabal test` succeed again; killing Postgres while the
server runs makes the whole process exit non-zero (so a process supervisor restarts it)
instead of serving lies; Ctrl-C / SIGTERM drains the writer gracefully before exit;
`GET /ready` returns 200 only when the writer thread is alive and Postgres/pgmq is reachable,
and 503 with a JSON body naming the failing dependency otherwise; 503 error bodies are
generic while the detail goes to the stderr log; and the ClickHouse connection is fully
configurable via `KANSOKU_CLICKHOUSE_HOST/DATABASE/USER/PASSWORD` with defaults that keep the
current `nix develop` + `process-compose up` dev flow working unchanged.


## Progress

Use this checklist to track granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").

- [ ] M1: EP-21 is Complete in the MasterPlan; its coherent cohort, current runtime APIs, and explicit PGMQ migration path are present
- [ ] M1: `cabal build all` succeeds inside `nix develop`
- [ ] M1: `cabal test` succeeds inside `nix develop`
- [ ] M1: EP-21's ephemeral PostgreSQL test proves schema application and queue provisioning; ordinary server startup does not migrate
- [ ] M1: migrated cohort and any `runWriter` signature constraints recorded in Surprises & Discoveries
- [ ] M2: shutdown `MVar` + SIGTERM/SIGINT handlers in `kansoku-server/app/Main.hs`
- [ ] M2: `runWriter`'s `waitForShutdown` is `readMVar shutdownVar`, not `forever threadDelay`
- [ ] M2: writer and server linked via `withAsync` + `race_ (wait writerAsync) …`
- [ ] M2: `unix` added to `kansoku-server.cabal` build-depends
- [ ] M2: demonstrated — stop postgres, writer errors, process exits non-zero
- [ ] M2: demonstrated — Ctrl-C drains writer (`stopAppGracefully`, 30 s) and exits 0
- [ ] M2: commit `fix(server): link writer and server lifetimes, wire graceful shutdown`
- [ ] M3: `ReadyProbe` type and `pgmqReady` helper in `kansoku-core`
- [ ] M3: `GET /ready` route in `kansokuApp` (200 ready / 503 naming failing deps)
- [ ] M3: `Main.hs` wires `poll writerAsync` liveness + `pgmqReady` into the probe
- [ ] M3: demonstrated with `curl` in both healthy and degraded states
- [ ] M3: commit `feat(server): add /ready endpoint reporting writer and pgmq readiness`
- [ ] M4a: `Ingest/Handler.hs` 503 body generic; pgmq detail logged to stderr
- [ ] M4a: `Metrics/Handler.hs` 503 body generic; ClickHouse detail logged to stderr
- [ ] M4b: `Config.hs` gains `clickHouseUser`/`clickHousePassword`; four `KANSOKU_CLICKHOUSE_*` env vars read with dev-compatible defaults
- [ ] M4b: `ClickHouse.hs` `connectionArgs` uses configured user and `setPassword`
- [ ] M4b: `ConfigSpec.hs` updated (clearEnv list, default + parse assertions)
- [ ] M4: `cabal build all` and `cabal test` still green; commit `fix(server): generic error bodies and configurable ClickHouse credentials`
- [ ] MasterPlan registry row for EP-10 set to Complete; its Progress boxes ticked
- [ ] Outcomes & Retrospective written


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

- Decision: Replace `withAsync … (const …)` lifetime-decoupling with explicit lifetime
  linking — keep `withAsync` for the writer's `Async` handle (needed by `/ready`), but run
  `race_ (wait writerAsync) (server)` so either side's termination (normal return or
  exception) terminates the whole process, instead of adding in-process restart logic for
  the writer.
  Rationale: supervisor-owned restarts are simpler and crash-only; the process supervisor
  (process-compose in dev, whatever runs the service in production) restarts a dead process,
  whereas in-process restart logic would have to reason about partially-drained batches and
  poisoned connections. `race_` also gives graceful shutdown for free: when the writer
  returns normally after draining, the server side is torn down and `main` exits 0.
  Date: 2026-07-15

- Decision: Keep the `/ready` endpoint minimal — writer liveness plus a single cheap pgmq
  reachability call (`queueMetrics`), no thresholds, no ClickHouse check.
  Rationale: EP-16 (`docs/plans/16-pipeline-observability-queue-depth-writer-lag-and-exported-telemetry.md`)
  extends exactly this handler with queue-depth and lag thresholds; the MasterPlan's
  Integration Points section requires EP-16 to extend, not replace, EP-10's handler.
  Gold-plating here would be redone there.
  Date: 2026-07-15

- Decision: ClickHouse configuration additions (`KANSOKU_CLICKHOUSE_HOST`,
  `KANSOKU_CLICKHOUSE_DATABASE`, `KANSOKU_CLICKHOUSE_USER`, `KANSOKU_CLICKHOUSE_PASSWORD`)
  are additive `Config` record fields with defaults identical to today's hardcoded values
  (`127.0.0.1`, `analytics`, `default`, empty password).
  Rationale: the `nix develop` + `process-compose up` dev flow must keep working with zero
  new environment setup, and the MasterPlan's Integration Points section requires
  `Kansoku.Config` changes to be additive-with-defaults because EP-15 and EP-16 add their
  own fields to the same record later.
  Date: 2026-07-15

- Decision: SUPERSEDED by EP-21 — fold the pgmq-migration cutover (`Pgmq.Migration.migrate` removed in favor of
  pg-migrate's `pgmqMigrations` component) into Milestone 1 alongside the shibuya `Message`
  migration.
  Rationale: it is a second build break of the same class (a pinned local dependency moved
  under kansoku), discovered during EP-15's plan authoring; EP-10 is the designated
  build-restoration plan and every other plan's validation is blocked until both breaks are
  fixed. The canonical consumption pattern was verified against pgmq-hs's own test harnesses
  (`pgmq-effectful/test/EphemeralDb.hs`).
  Date: 2026-07-15

- Note for Milestone 1's implementer: EP-16
  (`docs/plans/16-pipeline-observability-queue-depth-writer-lag-and-exported-telemetry.md`)
  later changes `writerBatchHandler`'s signature (threading metrics and a heartbeat cell).
  No action needed here — just do not treat the handler's shape as frozen when extending it.

- Decision: SUPERSEDED — the unexecuted external `migrate-keiro-stack` blueprint is no longer
  EP-10's prerequisite. Checked-in EP-21 owns the cohort, current runtime APIs, and explicit
  PGMQ migration cutover; EP-10 starts only after EP-21 is Complete.
  Rationale: user direction on 2026-07-17. The applicable migration is small and repository-local,
  and the generic blueprint's absent Kiroku/Keiro/Kioku components must not be introduced.
  Consequence for Milestone 2: `Kansoku.Writer.Run` already uses the migrated Shibuya `AppConfig`
  API when EP-10 begins; this plan changes only lifetime supervision around it.
  Date: 2026-07-17


## Outcomes & Retrospective

Compare the result against the original purpose at completion.

(To be filled during and after implementation.)


## Context and Orientation

Kansoku is a Haskell analytics service. Browsers and backend services `POST` analytics
events to it; the events are validated and enqueued into pgmq (a message-queue extension
that lives inside PostgreSQL — durable, transactional, table-backed); a background "writer"
consumes the queue in batches and performs one batched `INSERT` per flush into ClickHouse (a
column-oriented analytics database); metrics endpoints query ClickHouse. The repository is a
cabal multi-package project (`cabal.project` at the root) with four packages: `kansoku-api`
(servant route types and DTOs, plus the project prelude), `kansoku-core` (all server logic),
`kansoku-server` (the executable), and `kansoku-client` (a generated-style Haskell SDK).
Toolchain: GHC 9.12.4 via a nix flake. All commands in this plan run from the repository
root inside the dev shell (`nix develop`, or prefix commands with `nix develop -c`). `just
build` runs `cabal build all`, `just test` runs `cabal test`, and `just up` runs
`process-compose up`, which starts local PostgreSQL and ClickHouse instances plus schema
creation (see `process-compose.yaml`; the shell exports `PG*` and `CLICKHOUSE_*` variables).

The batch consumer framework is Shibuya. EP-21 replaces workstation-local dependency paths with
a portable released cohort and migrates application handlers to the read-only
`Message es msg` projection. The handler type in `Shibuya.Core.Batch` is:

```haskell
type BatchHandler es msg = BatchInfo -> NonEmpty (Message es msg) -> Eff es BatchAck
```

EP-21 also introduces `Kansoku.Migrations` as the PGMQ-only pg-migrate composition point and a
dedicated `kansoku-migrate` executable. `Kansoku.Ingest.Queue` only provisions the configured
queue after schema migration, and normal server startup no longer calls `runMigrationPlan`.
EP-10 must preserve that boundary while adding supervision; future PostgreSQL components extend
the checked-in plan rather than adding startup side effects.

The writer is wired in `kansoku-core/src/Kansoku/Writer/Run.hs` (`runWriter`): it builds a
shibuya pgmq adapter, a batch processor around `writerBatchHandler`, starts the shibuya app,
then blocks on its `waitForShutdown :: IO ()` argument before calling `stopAppGracefully
ShutdownConfig {drainTimeout = 30}`. If startup fails it calls `error` (around line 72), and
if the pgmq effect interpreter surfaces a `PgmqRuntimeError` it calls `error` (around line
80) — in both cases the writer's IO action throws. The executable `kansoku-server/app/Main.hs`
currently runs:

```haskell
let keepRunning = forever (threadDelay 1000000000)
withAsync (runWriter … keepRunning) (const (runApp cfg (startServer app)))
```

Two defects live in those three lines. First, `withAsync child (const parent)` never observes
the child: if `runWriter` throws, the exception is stored in the `Async` and nobody calls
`wait`, so Warp serves `202 Accepted` forever while the pipeline is dead. Second,
`keepRunning` never returns, so `stopAppGracefully` is unreachable — there is no graceful
shutdown path at all; SIGTERM just kills the process mid-batch.

The HTTP layer: `kansoku-core/src/Kansoku/Server.hs` hand-dispatches on `pathInfo` in
`kansokuApp` (routes: `/health`, `/openapi.json`, `/metrics/*`, and everything else to the
ingest servant app). Plan 9 (`docs/plans/9-convert-kansoku-to-namedroutes-vertical-slices-and-multiverb.md`)
will later fold this hand router into servant NamedRoutes; adding `/ready` to the hand
router here is fine and expected — plan 9 carries it forward. `startServer` reads the port
from `Config` and blocks in `Warp.run`.

Error-body leaks: `kansoku-core/src/Kansoku/Ingest/Handler.hs` `effToHandler` returns
`jsonError err503 "queue unavailable" [Text.pack (show pgErr)]` — the shown
`PgmqRuntimeError` can embed connection strings and hostnames. Likewise
`kansoku-core/src/Kansoku/Metrics/Handler.hs` `effToHandler` puts `show err` of a caught
`SomeException` into its 503 `details`. The repo already has a minimal structured-logging
effect in `kansoku-core/src/Kansoku/Logging.hs` (`Log` effect, `logError`, and
`runLogStderr` which prints one JSON object per line to stderr) — the detail belongs there.

Configuration: `kansoku-core/src/Kansoku/Config.hs` `loadConfig` reads env vars but
hardcodes `clickHouseHost = "127.0.0.1"` and `clickHouseDatabase = "analytics"`, and
`kansoku-core/src/Kansoku/ClickHouse.hs` `connectionArgs` hardcodes `setUser "default"` with
no password. The ClickHaskell client library (source at
`/Users/shinzui/Keikaku/hub/haskell/clickhaskell-project/ClickHaskell/library/`) exports
`setPassword :: String -> ConnectionArgs -> ConnectionArgs` from `ClickHaskell` (defined in
`ClickHaskell/Connection.hs`, line 207), verified against the checked-out source — so no
workaround is needed.

For the pgmq reachability check, the effect library `pgmq-effectful` (source at
`/Users/shinzui/Keikaku/bokuno/libraries/pgmq-hs-project/pgmq-hs/pgmq-effectful/src/Pgmq/Effectful/Effect.hs`)
exposes `queueMetrics :: (Pgmq :> es) => QueueName -> Eff es QueueMetrics`. `QueueMetrics`
(defined in `pgmq-hasql/src/Pgmq/Hasql/Statements/Types.hs`) carries `queueName`,
`queueLength :: Int64`, `totalMessages :: Int64`, message-age fields, and `scrapeTime`. This
plan only uses the call as a cheap "is Postgres/pgmq answering" probe and discards the
values; EP-16 later reads `queueLength` for thresholds.

Code standards (mandatory — these are the house rules from the haskell-jitsurei core
standards, restated here so this plan is self-contained): every package uses the `GHC2024`
language edition with `DeriveAnyClass`, `DuplicateRecordFields`, `OverloadedLabels`,
`OverloadedStrings` (this repo also enables `MultilineStrings`) in a `common` cabal stanza —
already set up, do not change it. Every module imports `Kansoku.Prelude` (lives in
`kansoku-api/src/Kansoku/Prelude.hs`; re-exports `Text`, `Generic`, `NonEmpty`, lens
operators, aeson classes, `liftIO`, `isNothing`, etc.). Qualified imports use postpositive
syntax (`import Data.Text qualified as Text`, never `import qualified Data.Text`). Record
access and update go through generic-lens `OverloadedLabels`: read with `cfg ^. #serverPort`,
update with `record & #field .~ value` — never native record-update syntax. All record
fields are strict (`!`). All deriving uses explicit strategies (`deriving stock`,
`deriving newtype`, `deriving anyclass`). Multiline SQL/text uses `MultilineStrings`
triple-quote literals. Match the surrounding style of each file you touch; run
`fourmolu` formatting if the file was formatted (the repo has `fourmolu.yaml`).

Commit style: Conventional Commits, one commit per milestone, and every commit message for
this plan carries these two trailers (exact text):

```text
MasterPlan: docs/masterplans/2-kansoku-production-hardening-review-fixes-and-portfolio-service-readiness.md
ExecPlan: docs/plans/10-restore-the-build-and-supervise-the-writer.md
```


## Plan of Work

The work is four milestones, strictly in order: nothing can be validated until the build is
restored (Milestone 1); the readiness probe (Milestone 3) reuses the `Async` handle that the
supervision rework (Milestone 2) introduces; hygiene (Milestone 4) is independent of 2 and 3
but is committed last so every intermediate commit is a compiling, tested state.


### Milestone 1 — Verify the completed EP-21 migration baseline

Confirm EP-21 is marked Complete in the MasterPlan and read its Outcomes & Retrospective before
editing runtime supervision. Verify that `cabal.project` has no workstation-absolute dependency
paths, Cabal and Nix use the recorded pg-migrate/PGMQ/Shibuya cohort, the writer uses the current
`Message`, adapter-environment, and `AppConfig` APIs, and `kansoku-migrate` owns the PGMQ-only
schema plan. Ordinary `kansoku-server` startup must only provision its configured queue.

Run `nix develop -c cabal build all` and `nix develop -c cabal test all`. Reuse EP-21's automated
ephemeral PostgreSQL test as the fresh-database proof; do not drop or recreate the repository-local
database. Record the landed cohort and any constraints on `runWriter` in Surprises & Discoveries.
No source edit or migration commit belongs to this milestone: if these checks fail, EP-21 is not
complete and must be corrected before EP-10 proceeds.

Acceptance: both commands exit zero, the EP-21 migration integration test passes, and a source
search shows `runMigrationPlan` is reachable from the administrative migration executable but not
from the ordinary server bootstrap path.


### Milestone 2 — Link writer and server lifetimes, wire real shutdown

Scope: rework `kansoku-server/app/Main.hs` so that (a) if the writer dies, the whole process
exits non-zero and the supervisor restarts it — no more zombie mode where Warp accepts
events into a queue nothing drains — and (b) SIGTERM/SIGINT trigger the graceful path that
already exists inside `runWriter` (`stopAppGracefully ShutdownConfig {drainTimeout = 30}`)
instead of being unreachable behind `forever (threadDelay …)`.

The design: create `shutdownVar :: MVar ()` at startup. Install signal handlers for SIGTERM
and SIGINT (via `System.Posix.Signals.installHandler` with `Catch (void (tryPutMVar
shutdownVar ()))`; installing our own SIGINT handler deliberately replaces the GHC RTS
default that would throw `UserInterrupt` and kill the writer mid-batch). Pass `readMVar
shutdownVar` as `runWriter`'s `waitForShutdown` argument, replacing `keepRunning`. Start the
writer with `withAsync` — we keep `withAsync` because Milestone 3 needs the `Async` handle
for liveness — but instead of ignoring the handle, run:

```haskell
withAsync (runWriter …stuff… (readMVar shutdownVar)) $ \writerAsync ->
  race_
    (wait writerAsync)
    (runApp cfg (startServer app))
```

`race_` (from `Control.Concurrent.Async`) runs both actions and returns when either
finishes, cancelling the other; exceptions from either side re-throw in `main`. Walk the
three lifecycles to see it is correct. Writer crash (e.g. Postgres dies, the pgmq adapter's
read fails, `runWriter` hits its `error` call): `wait writerAsync` rethrows, `race_` cancels
Warp and rethrows, `main` dies with a non-zero exit status and the exception text on stderr
— the supervisor restarts the process. Server crash (e.g. port already bound): `race_`
cancels the writer and rethrows — same outcome. Graceful shutdown (SIGTERM or Ctrl-C): the
handler fills `shutdownVar`; `readMVar` returns inside `runWriter`, which calls
`stopAppGracefully` and drains up to 30 seconds, then `runWriter` returns `()`; `wait
writerAsync` returns; `race_` cancels the Warp thread and returns; `main` exits 0. (Warp's
in-flight requests are cut at that point; ingest requests are milliseconds long, and adding
Warp's own graceful-drain settings is out of scope here — note it in the Decision Log if you
decide otherwise.)

Concretely in `kansoku-server/app/Main.hs`: remove the `Control.Concurrent (threadDelay)`,
`Control.Monad (forever)` imports and the `keepRunning` binding; add imports
`Control.Concurrent.MVar (MVar, newEmptyMVar, readMVar, tryPutMVar)`,
`Control.Concurrent.Async (race_, wait, withAsync)` (extend the existing async import), and
`System.Posix.Signals (Handler (Catch), installHandler, sigINT, sigTERM)`. Add `unix` to the
`build-depends` of the `kansoku-server` executable stanza in
`kansoku-server/kansoku-server.cabal` (it is not currently a dependency; `async` already
is). Keep everything else — config loading, pool `bracket`, `bootstrapQueue`,
`openClickHouse`, `makeTracer` — as is.

One risk to verify by demonstration, not assumption: `runWriter` starts the shibuya app with
`runApp IgnoreFailures 100 …` (see `kansoku-core/src/Kansoku/Writer/Run.hs`). If shibuya's
`IgnoreFailures` supervision swallows the pgmq error inside its own processor thread instead
of letting the `Error PgmqRuntimeError` surface out of `runWriter`'s `runErrorNoCallStack`,
then killing Postgres would leave the writer "running but dead" and the process would not
exit. The acceptance transcript below is therefore mandatory. If the process does not exit
when Postgres stops, read shibuya's supervision semantics
(`/Users/shinzui/Keikaku/bokuno/shibuya-project/shibuya/`), switch the strategy or propagate
the failure so that a dead pipeline is fatal, and record what you found in Surprises &
Discoveries.

Acceptance is demonstrated behavior. With `process-compose up` running in one terminal and
the server started in another, stopping Postgres must kill the whole process:

```text
# terminal 1 (repo root, inside nix develop)
$ just up                       # postgres, clickhouse, create_schema become healthy

# terminal 2 (repo root, inside nix develop)
$ cabal run kansoku-server
{"level":"info","message":"kansoku-server listening on port 8080 (GET /health, ...)"}

# terminal 3: stop postgres out from under the writer
$ process-compose process stop postgres

# terminal 2, within a few seconds (one poll interval), the writer's pgmq error
# escapes and the process dies:
kansoku-server: kansoku writer pgmq error: ...connection...
$ echo $?
1
```

And Ctrl-C (or `kill -TERM <pid>`) with all services healthy must exit cleanly:

```text
# terminal 2: press Ctrl-C
^C
$ echo $?
0
```

(The writer drains via `stopAppGracefully` first; if there is a backlog you will see up to
30 seconds of delay before exit. If not all messages drained, `runWriter` prints
"kansoku writer stopped before all messages drained" — still exit 0.)


### Milestone 3 — Readiness endpoint (`GET /ready`)

Scope: give orchestrators and load balancers a truthful signal. `GET /health` stays as the
static liveness ping. New `GET /ready` returns `200` with `{"status":"ready"}` only when
both (a) the writer thread is alive and (b) Postgres/pgmq answers a cheap query; otherwise
`503` with a JSON body naming every failing dependency, e.g.
`{"status":"unavailable","failing":["postgres"]}`. Keep it exactly this minimal: EP-16
extends this same handler with queue-depth and lag thresholds later (MasterPlan Integration
Points), and plan 9 later folds the route into NamedRoutes — adding it to the existing hand
router in `Kansoku.Server` is the intended move here.

In `kansoku-core/src/Kansoku/Server.hs`: define a probe record the executable fills in —

```haskell
-- | How the server answers GET /ready. The executable wires these to the
-- writer's Async and the pgmq pool; tests can stub them.
data ReadyProbe = ReadyProbe
  { writerAlive :: !(IO Bool),
    pgmqReachable :: !(IO (Either Text ()))
  }
  deriving stock (Generic)
```

Export `ReadyProbe (..)`. Change `kansokuApp` to take it: `kansokuApp :: ReadyProbe ->
Pool.Pool -> QueueName -> Connection -> Application`, and add a `["ready"]` case to the
`pathInfo` dispatch before the catch-all. The handler runs both checks, collects the names
of failures (`"writer"` when `writerAlive` returns `False`, `"postgres"` when
`pgmqReachable` returns `Left _`), and responds `status200` with
`Aeson.encode (Aeson.object ["status" .= ("ready" :: Text)])` when the failure list is
empty, else `status503` with `["status" .= ("unavailable" :: Text), "failing" .= names]`.
Content type `application/json` in both cases. Do not put the `Left` detail text into the
body — the dependency name is enough for a probe, and internals stay out of responses (the
`Left` payload exists so EP-16 can log/measure; ignore its contents here beyond "it failed").

Also in `kansoku-core` (put it in `Kansoku/Server.hs` next to the probe, or in the ingest
queue module if you prefer — name the choice in the Decision Log), add the pgmq check
helper so the executable does not need `effectful`/`pgmq-effectful` dependencies:

```haskell
-- | Cheap "is Postgres/pgmq answering" probe: one pgmq.metrics() call, values discarded.
pgmqReady :: Pool.Pool -> QueueName -> IO (Either Text ())
pgmqReady pool queueName = do
  result <-
    runEff $
      Error.runErrorNoCallStack @PgmqRuntimeError $
        runPgmq pool $
          queueMetrics queueName
  pure $ case result of
    Left err -> Left (Text.pack (show err))
    Right _metrics -> Right ()
```

`queueMetrics` comes from `Pgmq.Effectful` (it calls `pgmq.metrics(queue)` in Postgres; the
queue exists because `Main.hs` runs `bootstrapQueue` before serving). This mirrors the
interpreter stack already used in `Kansoku/Ingest/Handler.hs`, so the imports are all
already available to `kansoku-core`.

In `kansoku-server/app/Main.hs` (inside the `withAsync` scope from Milestone 2): build the
probe and pass it to `kansokuApp`. Writer liveness comes from `poll writerAsync`
(`Control.Concurrent.Async.poll` returns `Nothing` while the thread is still running, `Just`
once it has finished or died), so:

```haskell
let probe =
      ReadyProbe
        { writerAlive = isNothing <$> poll writerAsync,
          pgmqReachable = pgmqReady pool queueName
        }
    app = kansokuApp probe pool queueName clickHouse
```

(`isNothing` is re-exported by `Kansoku.Prelude`.) Note the `app` binding must move inside
the `withAsync` continuation since it now needs `writerAsync`. In practice the
writer-dead-but-process-alive window is tiny — Milestone 2 makes writer death kill the
process — but the check is what makes `/ready` truthful during startup, drain, and any
future decoupling, and EP-16 builds on it.

Acceptance, demonstrated with `curl` (services healthy, server running):

```text
$ curl -si http://localhost:8080/ready
HTTP/1.1 200 OK
content-type: application/json

{"status":"ready"}
```

Degraded: `process-compose process stop postgres`, then immediately (within the few seconds
before the writer notices and the process exits per Milestone 2):

```text
$ curl -si http://localhost:8080/ready
HTTP/1.1 503 Service Unavailable
content-type: application/json

{"failing":["postgres"],"status":"unavailable"}
```

(The 503 window is short precisely because Milestone 2 makes the process die; observing
either the 503 or the process exit demonstrates the endpoint and the supervision agree.
For a slower-paced check of the writer-liveness branch, you can temporarily start the server
with Postgres already stopped after `bootstrapQueue` — or simply rely on the pgmq branch
plus the process-exit behavior.) `GET /health` must still return `200 OK` and `cabal test`
must stay green.


### Milestone 4 — Error-body and configuration hygiene

Scope: stop leaking internals in 503 bodies, and make ClickHouse host/database/user/password
configurable. Two independent halves, one commit.

Half (a), error bodies. In `kansoku-core/src/Kansoku/Ingest/Handler.hs`, `effToHandler`'s
`Left pgErr` branch currently does `throwError (jsonError err503 "queue unavailable"
[Text.pack (show pgErr)])`. A shown `PgmqRuntimeError` can contain the Postgres connection
string and host. Change the branch to log the detail to stderr and return a generic body:

```haskell
Left pgErr -> do
  liftIO . runEff . runLogStderr $
    logError ("ingest enqueue failed: " <> Text.pack (show pgErr))
  throwError (jsonError err503 "queue unavailable" [])
```

`runLogStderr` and `logError` come from `Kansoku.Logging` (already in `kansoku-core`; it
prints one JSON object per line to stderr). Wrapping a one-shot `runEff … runLogStderr` here
is deliberate — `effToHandler` already left the `Eff` stack by this point, and threading a
`Log` effect through the servant handlers is plan-9 territory. Apply the same treatment to
`kansoku-core/src/Kansoku/Metrics/Handler.hs` `effToHandler`: log
`"clickhouse query failed: " <> Text.pack (show err)` at `Error` level, and change the
response to `jsonError err503 "clickhouse query failed" (Aeson.object [])` (that file's
`jsonError` takes an `Aeson.Value` for details — pass an empty object rather than the shown
exception). The user-visible contract: a 503 still names which subsystem is unavailable
("queue unavailable" / "clickhouse query failed") but carries no exception text; the
operator finds the detail as a JSON log line on stderr.

Half (b), configuration. In `kansoku-core/src/Kansoku/Config.hs`: add two strict fields to
`Config` — `clickHouseUser :: !String` and `clickHousePassword :: !String` — keeping every
existing field (additive only; EP-15/EP-16 add more fields later). In `loadConfig`, read
four new variables with `lookupEnv` and defaults equal to today's hardcoded behavior:
`KANSOKU_CLICKHOUSE_HOST` (default `"127.0.0.1"`, replaces the hardcoded `clickHouseHost`),
`KANSOKU_CLICKHOUSE_DATABASE` (default `"analytics"`, replaces the hardcoded
`clickHouseDatabase`), `KANSOKU_CLICKHOUSE_USER` (default `"default"`),
`KANSOKU_CLICKHOUSE_PASSWORD` (default `""`). These are plain strings — `fromMaybe def <$>
lookupEnv name`, no parsing, so `loadConfig` stays total. (Yes, the pre-existing port
variables are unprefixed `CLICKHOUSE_TCP_PORT`/`CLICKHOUSE_HTTP_PORT` because the nix shell
exports them for the ClickHouse server process itself; the new kansoku-owned settings take
the `KANSOKU_` prefix. Do not rename the old ones in this plan.)

In `kansoku-core/src/Kansoku/ClickHouse.hs`: add `clickHouseUser :: !String` and
`clickHousePassword :: !String` to `ClickHouseConfig`, map them from `Config` in
`clickHouseConfigFromConfig`, and in `connectionArgs` replace `setUser "default"` with
`setUser` of the configured user composed with `setPassword` of the configured password
(both `String -> ConnectionArgs -> ConnectionArgs`, exported by the `ClickHaskell` module —
verified present in the checked-out ClickHaskell source, `library/ClickHaskell/Connection.hs`
line 207). `openBootstrapConnection` keeps overriding only the database to `"default"`; it
now inherits user and password from the config, which matches dev defaults.

Tests: `kansoku-core/test/Kansoku/ConfigSpec.hs` — add the four new variable names to
`clearEnv`'s `unsetEnv` list (otherwise ambient shell values would break the defaults test),
assert the new defaults in the "uses defaults when nothing is set" case
(`(cfg ^. #clickHouseUser) `shouldBe` "default"`, password `""`, and now-explicit host and
database assertions already exist), and extend the "parses values from the environment" case
with `setEnv` for at least `KANSOKU_CLICKHOUSE_HOST` and `KANSOKU_CLICKHOUSE_USER` plus
matching assertions. Note `ClickHouseSpec.hs` and `Writer/BatchSpec.hs` build
`ClickHouseConfig` only via `clickHouseConfigFromConfig`, so they need no edits.

Acceptance: `cabal build all` and `cabal test` green; with everything running and Postgres
stopped, `curl -si -X POST http://localhost:8080/v1/events -H 'content-type: application/json'
-d '{…valid event…}'` returns a 503 whose body is exactly
`{"details":[],"error":"queue unavailable"}` while a `{"level":"error","message":"ingest
enqueue failed: …"}` line appears on the server's stderr; and
`KANSOKU_CLICKHOUSE_USER=nosuchuser cabal run kansoku-server` fails to reach ClickHouse
(proving the setting is live) while the plain `cabal run kansoku-server` dev flow behaves
exactly as before.


## Concrete Steps

All commands run from the repository root
(`/Users/shinzui/Keikaku/bokuno/kansoku-project/kansoku`) inside the dev shell. Enter it
once per terminal with `nix develop` (or prefix single commands with `nix develop -c`).
Keep this section updated with reality as you go.

1. Start services (leave running in its own terminal): `just up`. Wait until the
   `postgres`, `clickhouse`, and `create_schema` processes report healthy/done in the
   process-compose TUI.

2. Verify EP-21 is Complete, read its recorded cohort and outcomes, and run:

   ```bash
   cabal build all
   cabal test
   ```

   Expected tail of output:

   ```text
   All … examples, 0 failures
   Test suite kansoku-core-test: PASS
   ```

   There is no EP-10 source commit for this verification-only milestone. If it fails, return to
   EP-21 instead of adding migration fallback code here.

3. Milestone 2 edits: `kansoku-server/app/Main.hs`, `kansoku-server/kansoku-server.cabal`
   (add `unix`). Rebuild, then run the two acceptance transcripts from the milestone
   (postgres-stop → exit 1; Ctrl-C → exit 0). Commit as
   `fix(server): link writer and server lifetimes, wire graceful shutdown` with the same
   two trailers.

4. Milestone 3 edits: `kansoku-core/src/Kansoku/Server.hs` (`ReadyProbe`, `pgmqReady`,
   `/ready` route, `kansokuApp` signature), `kansoku-server/app/Main.hs` (build the probe,
   move `app` inside the `withAsync` scope). Rebuild, rerun `cabal test`, run the `curl`
   transcripts. Commit as
   `feat(server): add /ready endpoint reporting writer and pgmq readiness` with trailers.

5. Milestone 4 edits: `kansoku-core/src/Kansoku/Ingest/Handler.hs`,
   `kansoku-core/src/Kansoku/Metrics/Handler.hs`, `kansoku-core/src/Kansoku/Config.hs`,
   `kansoku-core/src/Kansoku/ClickHouse.hs`, `kansoku-core/test/Kansoku/ConfigSpec.hs`.
   Rebuild, `cabal test`, run the 503-body and env-var acceptance checks. Commit as
   `fix(server): generic error bodies and configurable ClickHouse credentials` with
   trailers.

6. Close out: tick this plan's Progress boxes and the four EP-10 boxes in the MasterPlan's
   Progress section, set the EP-10 registry row to Complete, write Outcomes &
   Retrospective here, and commit the doc updates as
   `docs(plans): mark EP-10 complete` with the same trailers.


## Validation and Acceptance

The plan is done when all of the following hold, each observable by a human:

Build and tests: `nix develop -c cabal build all` and `nix develop -c cabal test` both
succeed from a clean checkout of the final commit. Run the test suite at least once with
`process-compose up` active so the BatchSpec ClickHouse case actually executes instead of
being skipped as pending.

Supervision: with services up and the server running, `process-compose process stop
postgres` causes the server process to print the writer's pgmq error to stderr and exit
with a non-zero status within a few seconds (one adapter poll interval). Restarting
postgres (`process-compose process start postgres`) and relaunching the server returns to
normal operation — events POSTed to `/v1/events` land in ClickHouse (verify with
`clickhouse-client --port $CLICKHOUSE_TCP_PORT --query 'SELECT count() FROM
analytics.events_raw'` before and after).

Graceful shutdown: Ctrl-C (SIGINT) or `kill -TERM` on the healthy server exits with status
0, after the writer drains (up to 30 seconds if there is a backlog).

Readiness: `curl -si http://localhost:8080/ready` returns `200` and
`{"status":"ready"}` when healthy; with Postgres stopped it returns
`{"failing":["postgres"],"status":"unavailable"}` with status 503 in the window before the
process exits. `curl -si http://localhost:8080/health` still returns `200` `OK`.

Hygiene: with Postgres stopped, `POST /v1/events` returns a 503 whose JSON body contains no
hostname/connection-string text — only `{"details":[],"error":"queue unavailable"}` — and
the detail appears as an error-level JSON line on stderr. The analogous check for a metrics
route with ClickHouse stopped (`process-compose process stop clickhouse`, then `curl
'http://localhost:8080/metrics/events?from=2026-07-01&to=2026-07-15'`) shows a generic
`clickhouse query failed` body and a stderr log line. Config: `cabal test` covers the new
defaults and env parsing; `KANSOKU_CLICKHOUSE_USER=nosuchuser cabal run kansoku-server`
demonstrably fails ClickHouse authentication while the unmodified dev flow is unchanged.


## Idempotence and Recovery

Every step is safe to repeat. The edits are ordinary source changes on the current branch
committed per milestone, so `git status` / `git diff` always shows where you are, and a
half-finished milestone can be resumed by re-reading its section — none of the edits are
order-sensitive within a milestone. `cabal build all` and `cabal test` are idempotent.
`process-compose up` reuses the existing local data directories; stopping and starting the
`postgres`/`clickhouse` processes for the failure demonstrations is non-destructive (pgmq
tables and ClickHouse data persist). The BatchSpec test truncates `analytics.events_raw` in
the local dev ClickHouse — that is pre-existing behavior and only touches disposable dev
data. EP-21's schema tests use an ephemeral PostgreSQL instance; EP-10 does not apply migrations
to the repository-local database. No destructive operations or production systems are involved. If a
demonstration leaves services stopped, `process-compose process start postgres` (or
restarting `just up`) restores them. If a rebuild behaves strangely after the cabal edit,
`cabal build all` again; as a last resort `rm -rf dist-newstyle` and rebuild (slow but
safe).


## Interfaces and Dependencies

Libraries used, all already available except one cabal edit: `async`
(`Control.Concurrent.Async`: `withAsync`, `wait`, `race_`, `poll`) — already a
`kansoku-server` dependency; `unix` (`System.Posix.Signals`: `installHandler`, `Handler
(Catch)`, `sigTERM`, `sigINT`) — must be added to `kansoku-server/kansoku-server.cabal`
`build-depends` in Milestone 2; the portable Shibuya cohort established by EP-21
(`Shibuya.Core.Ingested` `Message (..)`, `Shibuya.Batch` `BatchHandler`); `pgmq-effectful`
(`Pgmq.Effectful`: `queueMetrics`, `runPgmq`, `QueueName`; `Pgmq.Effectful.Interpreter`:
`PgmqRuntimeError`) — already a `kansoku-core` dependency; ClickHaskell (`ClickHaskell`:
`setUser`, `setPassword`, both `String -> ConnectionArgs -> ConnectionArgs`) — already a
dependency, `setPassword` verified exported; `effectful` and `aeson` — already dependencies.

Signatures that must exist at the end of each milestone (full module paths):

Milestone 1 — no new interface. Verify the EP-21 surfaces: the `Message`-based
`Kansoku.Writer.Batch.writerBatchHandler`; the current adapter/AppConfig-based
`Kansoku.Writer.Run.runWriter`; `Kansoku.Migrations`' PGMQ-only plan; an idempotent
queue-provisioning operation in `Kansoku.Ingest.Queue`; and the `kansoku-migrate`
administrative executable. Ordinary `kansoku-server` startup must not call
`runMigrationPlan`.

Milestone 2 — `Kansoku.Writer.Run.runWriter` keeps its existing signature (its last
argument `IO ()` is now `readMVar shutdownVar` from `Main`); `kansoku-server/app/Main.hs`
`main :: IO ()` uses `withAsync` + `race_ (wait writerAsync) …` and installs SIGTERM/SIGINT
handlers.

Milestone 3 — `Kansoku.Server.ReadyProbe` with fields `writerAlive :: IO Bool` and
`pgmqReachable :: IO (Either Text ())`; `Kansoku.Server.pgmqReady :: Pool.Pool -> QueueName
-> IO (Either Text ())`; `Kansoku.Server.kansokuApp :: ReadyProbe -> Pool.Pool -> QueueName
-> Connection -> Application`. EP-16 extends the `/ready` handler and may widen
`ReadyProbe`; keep the record additive.

Milestone 4 — `Kansoku.Config.Config` gains `clickHouseUser :: !String` and
`clickHousePassword :: !String` (all existing fields intact; additive only per the
MasterPlan's `Kansoku.Config` integration point); `Kansoku.ClickHouse.ClickHouseConfig`
gains the same two fields and `connectionArgs` consumes them; `Kansoku.Config.loadConfig ::
IO (Either ConfigError Config)` unchanged in type, reads `KANSOKU_CLICKHOUSE_HOST`,
`KANSOKU_CLICKHOUSE_DATABASE`, `KANSOKU_CLICKHOUSE_USER`, `KANSOKU_CLICKHOUSE_PASSWORD`
with defaults `"127.0.0.1"`, `"analytics"`, `"default"`, `""`.


---

Revision note (2026-07-15): Milestone 1 expanded to cover a second build break discovered
during EP-15's plan authoring — the pinned local `pgmq-migration` cut over from a
hasql-`Session` `migrate` to the pg-migrate component framework, breaking
`Kansoku.Ingest.Queue.bootstrapQueue`. Purpose, Context and Orientation, Milestone 1,
Progress, Interfaces and Dependencies, and the Decision Log were all updated to describe
both breaks and the pg-migrate consumption pattern (verified against
`pgmq-effectful/test/EphemeralDb.hs`). A forward-compatibility note about EP-16's later
`writerBatchHandler` signature change was added to the Decision Log.

Revision note (2026-07-15, second revision): Milestone 1 reframed from hand-implementing the
build fixes to verifying the outcome of the operator-run `migrate-keiro-stack` seihou
blueprint, which performs the cohort upgrade (shibuya `Message`, pgmq-migration→pg-migrate,
Cabal/Nix alignment, ordered migration plan) with database-safety gates. The manual fix
instructions are retained as an explicitly-labeled fallback path. Progress and the Decision
Log were updated to match; Milestone 2 gained a heads-up that the target cohort's shibuya
`runApp` takes an `AppConfig` record.

Revision note (2026-07-17): superseded the unexecuted external-blueprint prerequisite with the
checked-in EP-21 hard dependency. Purpose, progress, context, Milestone 1, concrete steps,
recovery, interfaces, and decisions now treat the coherent cohort and explicit PGMQ migration as
an already-completed gate. EP-10 no longer contains a hand-fix or implicit-startup-migration
fallback.
