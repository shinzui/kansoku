---
id: 1
slug: project-skeleton-and-application-runtime
title: "Project skeleton and application runtime"
kind: exec-plan
created_at: 2026-07-01T16:04:44Z
intention: "intention_01kwf425fxenc904ear54cr2n7"
master_plan: "docs/masterplans/1-kansoku-analytics-service-mvp.md"
---

# Project skeleton and application runtime

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

Kansoku (観測, "observation") is a self-hostable product-and-web analytics service written in
Haskell. This plan, EP-1, is the very first piece: it turns an empty repository that only has
Nix wiring into a real, buildable, runnable Haskell program. It is the foundation every other
plan in the initiative builds on, and it has no dependencies of its own.

Concretely, before this plan there is no Haskell package at all. The Nix build file
`nix/haskell.nix` already contains the line

```nix
packages.default = haskellPackages.callCabal2nix "kansoku" inputs.self { };
```

which means Nix expects a Cabal package description named `kansoku` at the repository root —
a file called `kansoku.cabal` — but that file does not exist yet, so `nix build` cannot
produce anything. ("Cabal" is Haskell's standard build description format; a `.cabal` file
lists the modules to compile, the libraries to depend on, and the executables and test suites
to produce. "callCabal2nix" is a Nix helper that reads a `.cabal` file and turns it into a Nix
build automatically.) Creating that `kansoku.cabal` file, and the source code it points at, is
the heart of this plan.

After this plan is complete, a newcomer who has cloned the repository can do all of the
following and observe each working:

- Enter the development environment with `nix develop` (this provides GHC 9.12.4, Cabal, and
  supporting tools).
- Run `cabal build` and see the library, an executable named `kansoku-server`, and a test
  suite all compile successfully.
- Run `cabal test` and see the unit tests pass.
- Run `nix build` and get a built `kansoku-server` binary under `./result/bin/`.
- Run `cabal run kansoku-server`, then in another terminal run
  `curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/health` and see `200`
  printed — proof that the server starts, loads its configuration, logs, and answers an HTTP
  health check.

The user-visible behavior this plan enables is therefore: **a running HTTP server that reports
it is alive.** Everything else in the Kansoku MVP (event ingestion, the ClickHouse write path,
the metrics query API, the SDK) plugs into the package layout, the configuration record, the
effect-system runtime, and the logging that this plan establishes.

Why an "effect system"? Kansoku and the author's related libraries are built on `effectful`, a
Haskell library that lets application code run in a single monad called `Eff` while tracking,
in the type, which capabilities (called "effects") that code is allowed to use — for example
"can do arbitrary IO", "can read the configuration", or "can write log lines". Later plans add
more capabilities to this same runtime (a `Pgmq` effect for the message queue in EP-4, a
`Tracing` effect for observability). Establishing the `effectful` runtime now, in the smallest
possible form, means every later plan extends one consistent pattern instead of inventing its
own. This plan defines that pattern and documents exactly how to extend it.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Milestone 1 — Create `kansoku.cabal` with a `common common` stanza (`default-language:
      GHC2024` plus the shared `default-extensions`), the shared `kansoku:kansoku-api`
      internal sub-library, the main library, the `kansoku-server` executable, and the test
      suite — every stanza doing `import: common` — plus `cabal.project` (`packages: .`) at the
      repository root.
- [ ] Milestone 1 — Create `api/Kansoku/Prelude.hs`, the project prelude every Kansoku module
      imports (re-exports Text/Generic/aeson/lens; home for shared aeson `Options`), exposed
      from the `kansoku-api` sub-library.
- [ ] Milestone 1 — Create a trivial `src/Kansoku.hs` umbrella module so the main library has
      something to compile.
- [ ] Milestone 1 — Create `app/Main.hs` and `test/Spec.hs` placeholders so all stanzas build.
- [ ] Milestone 1 — Create a `justfile` at the repository root with a `create-database`
      recipe (so `process-compose.yaml`'s `create_schema` step works) plus `build`, `test`,
      `run`, and `up` recipes.
- [ ] Milestone 1 — Verify `cabal build` succeeds inside `nix develop` (this compiles the
      `common` GHC2024 stanza, the `kansoku-api` sub-library, and `Kansoku.Prelude`).
- [ ] Milestone 1 — Verify `nix build` succeeds and produces `./result/bin/kansoku-server`.
- [ ] Milestone 2 — Add `src/Kansoku/Config.hs` defining the `Config` record and `loadConfig`
      reading environment variables with sensible defaults.
- [ ] Milestone 2 — Add `src/Kansoku/Logging.hs` defining the custom `Log` effect and its
      stderr JSON interpreter.
- [ ] Milestone 2 — Add `src/Kansoku/Runtime.hs` defining the `AppEffects` stack and `runApp`.
- [ ] Milestone 2 — Add `test/Kansoku/ConfigSpec.hs` with hspec unit tests for `loadConfig`,
      wire it into `test/Spec.hs`, and verify `cabal test` passes.
- [ ] Milestone 3 — Add `src/Kansoku/Server.hs` with a WAI health application and
      `startServer`.
- [ ] Milestone 3 — Wire `app/Main.hs` to `loadConfig`, `runApp`, and `startServer`.
- [ ] Milestone 3 — Run `cabal run kansoku-server` and capture a `curl` transcript showing
      `/health` returns `200`.
- [ ] Final — Update Surprises & Discoveries and Outcomes & Retrospective, update the parent
      MasterPlan's Progress checkboxes for EP-1, and commit with the required git trailers.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Use `hspec` for the test suite rather than `tasty`.
  Rationale: EP-1 needs only a couple of small unit tests (configuration parsing). `hspec`
  has the lightest ceremony for `describe`/`it` specs, needs no discovery build-tool when a
  single hand-written `test/Spec.hs` `main` calls `hspec`, and is already present in the
  nixpkgs GHC 9.12 package set. `tasty` is excellent for large, heterogeneous suites but adds
  provider packages we do not need yet. Later plans may add `tasty` alongside if they want
  property or golden testing; the two coexist.
  Date: 2026-07-01

- Decision: For the health endpoint, use `warp` + `wai` directly rather than introducing
  `servant`.
  Rationale: The MasterPlan (see its Decomposition Strategy and the "HTTP ingestion API
  contract" integration point) introduces the full `servant` HTTP stack in EP-4. For EP-1 we
  only need a single `/health` route returning 200, and `warp` (`Network.Wai.Handler.Warp.run`)
  plus a hand-written `wai` `Application` is the lightest thing that demonstrably serves HTTP.
  EP-4 will replace this minimal server with the servant application and mount `/health`
  alongside `POST /v1/events` and `POST /v1/batch`; this plan documents that hand-off so EP-4
  extends rather than duplicates it.
  Date: 2026-07-01

- Decision: Implement structured logging as a small in-repo `effectful` effect
  (`Kansoku.Logging.Log`) that writes one JSON object per line to stderr, rather than adding
  an external logging library such as `co-log` or `fast-logger`.
  Rationale: A survey of the author's dependency registry (via `mori`) shows neither `co-log`
  nor `fast-logger` is a registered/vendored dependency, and the author's "kiroku" package is
  an event store, not a logger. Pulling in an unvetted external logging library would violate
  the "keep it dependency-light" constraint and risk an API I cannot verify from source. A
  ~40-line dynamic-dispatch `effectful` effect gives structured JSON logs, is fully
  self-contained, and — crucially — establishes the exact "define an effect, interpret it in
  `runApp`" pattern that EP-3/EP-4/EP-6 follow when they add `Pgmq` and `Tracing`. If a
  richer logger is wanted later, only the interpreter (`runLogStderr`) changes; call sites
  (`logInfo`, `logError`) stay the same.
  Date: 2026-07-01

- Decision: Model the application runtime as `type AppEffects = '[Log, Reader Config, IOE]`
  with `runApp cfg = runEff . runReader cfg . runLogStderr`.
  Rationale: This is the minimal stack that carries configuration (the `Reader Config` effect
  from `Effectful.Reader.Static`), structured logging (the `Log` effect), and raw IO (`IOE`).
  The MasterPlan's "configuration module and effectful runtime stack" integration point
  requires EP-1 to own this base stack and document the extension pattern; later plans insert
  their effects into both the type-level list and the interpreter chain (for example
  `runEff . runReader cfg . runLogStderr . runPgmq . runTracing`). Recording the shape here
  prevents each plan from inventing a parallel runtime.
  Date: 2026-07-01

- Decision: Create a `justfile` at the repository root now, with a `create-database` recipe
  (plus `build`, `test`, `run`, `up`), rather than deferring it.
  Rationale: `process-compose.yaml` already references a `create_schema` process that runs
  `just create-database`, but no `justfile` exists, so `process-compose up` currently fails at
  that step. `just` is already provided by the dev shell (`nix/haskell.nix` lists `pkgs.just`
  in `baseDevPackages`). Creating the `justfile` now unblocks the local run story and gives a
  single obvious place for the developer commands this and later plans rely on. The
  `create-database` recipe is idempotent (it only creates the `kansoku` database if it does
  not already exist).
  Date: 2026-07-01

- Decision: Adopt the shared Kansoku Haskell coding standards
  (`/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/core/`) in EP-1, and make EP-1 the plan
  that establishes them for the whole initiative: a `common common` cabal stanza on
  `default-language: GHC2024` with the mandated `default-extensions` (`DeriveAnyClass`,
  `DuplicateRecordFields`, `OverloadedLabels`, `OverloadedStrings`, `MultilineStrings`), a
  `Kansoku.Prelude` module every module imports, postpositive qualified imports, strict
  record fields with explicit deriving strategies, and generic-lens `#label` access over
  record-update syntax.
  Rationale: These standards are authoritative for every Haskell project in this codebase, and
  EP-1 is the foundation every later plan extends. Establishing the `common` stanza and the
  prelude now means EP-2 through EP-8 inherit GHC2024, the shared extensions, and the common
  imports for free rather than each reinventing them (or drifting from them). GHC2024 already
  supplies `DataKinds`, `DerivingStrategies`, `LambdaCase`, and `ImportQualifiedPost`, so those
  are not listed; `PackageImports` is deliberately kept out of the global extensions and used
  only as a per-file pragma inside `Kansoku.Prelude`.
  Date: 2026-07-01

- Decision: Create the shared `kansoku:kansoku-api` internal sub-library in EP-1 (not later),
  holding `Kansoku.Prelude` from the start.
  Rationale: The prelude belongs in the shared base that every component depends on, and the
  MasterPlan's "cabal package structure" integration point designates `kansoku-api` as the
  dependency-light home for the event model and the servant API *type* declarations (it depends
  on `servant`, aeson, text, time, containers, uuid, `generic-lens`, `lens`, and
  `base` — never `servant-server`, `warp`, ClickHaskell, or pgmq). This refines the earlier
  note that EP-1 "need not create it": because the prelude must live in the shared base, EP-1
  now creates the sub-library skeleton (with `Kansoku.Prelude`), EP-2 adds the event modules
  (`Kansoku.Event*`) to it, and EP-4/EP-6 add the `Kansoku.Api.*` type modules — all to this
  same sub-library.
  Date: 2026-07-01

- Decision: Create `cabal.project` whose only directive is `packages: .` (plus an explanatory
  comment) and document it as the extension point for the author's non-Hackage libraries.
  Rationale: The MasterPlan's "cabal package structure" integration point states that EP-4
  will add `source-repository-package` / local `packages:` entries for `shibuya`,
  `shibuya-pgmq-adapter`, and `pgmq-hs` (which are not on Hackage). EP-1 owns the initial
  `cabal.project` so that later plans have a file to extend; keeping it minimal now avoids
  referencing sources that this plan does not need.
  Date: 2026-07-01

- Decision: Drop the `aeson-casing` dependency entirely; re-export `camelTo2` from `aeson`
  itself.
  Rationale: A pre-implementation validation pass found that the prelude sketch imported
  `camelTo2` from `Data.Aeson.Casing` (package `aeson-casing`), but `aeson-casing` does not
  export `camelTo2` — the function lives in aeson (exported from `Data.Aeson` and
  `Data.Aeson.Types`), so the sketch would not have compiled. `Kansoku.Prelude` now re-exports
  `camelTo2` from its existing `Data.Aeson` import list, and `aeson-casing` is removed from the
  `kansoku-api` build-depends everywhere: it served no other purpose in this plan, and carrying
  an unused package in the deliberately dependency-light shared base would contradict the
  plan's own constraint.
  Date: 2026-07-01


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose.

(To be filled during and after implementation.)


## Context and Orientation

This section describes the repository as it stands before this plan, assuming you know nothing
about it. All paths are relative to the repository root
`/Users/shinzui/Keikaku/bokuno/kansoku-project/kansoku`.

The repository is a "greenfield" (brand-new, no application code yet) Haskell project managed
with Nix flakes. The important existing files are:

- `flake.nix` — the Nix entry point. It imports three modules under `nix/`: `nix/haskell.nix`,
  `nix/treefmt.nix`, and `nix/pre-commit.nix`. You do not edit `flake.nix` for this plan.
- `nix/haskell.nix` — wires up the development shell and the package build. Two facts matter
  for this plan. First, it defines `packages.default = haskellPackages.callCabal2nix "kansoku"
  inputs.self { };`, which reads a `kansoku.cabal` file at the repository root — that file
  does not exist yet and this plan creates it. Second, its `shellHook` (the shell script that
  runs when you enter `nix develop`) exports the environment variables the application will
  read. Those exact exports are:

  ```bash
  export PGHOST="$PWD/db"
  export PGDATA="$PGHOST/db"
  export PGLOG=$PGHOST/postgres.log
  export PGDATABASE=kansoku
  export PG_CONNECTION_STRING=postgresql://$(jq -rn --arg x $PGHOST '$x|@uri')/$PGDATABASE
  export CLICKHOUSE_HOME="$PWD/clickhouse"
  export CLICKHOUSE_TCP_PORT=9000
  export CLICKHOUSE_HTTP_PORT=8123
  ```

  In plain terms: PostgreSQL is configured to listen on a Unix-domain socket in a directory
  under the project (`$PWD/db`) rather than on a TCP port — that is why `PG_CONNECTION_STRING`
  is `postgresql://<uri-encoded socket dir>/kansoku` with no host/port. ClickHouse (a columnar
  database used later for analytics storage) runs locally on TCP port 9000 and HTTP port 8123.
  This plan's `Kansoku.Config` reads `PG_CONNECTION_STRING`, `CLICKHOUSE_TCP_PORT`, and
  `CLICKHOUSE_HTTP_PORT`, plus an optional `KANSOKU_SERVER_PORT` for the HTTP server.

- `process-compose.yaml` — a description, for the `process-compose` tool, of the background
  services used during local development: a `postgres` process, a `clickhouse` process, and a
  `create_schema` process that runs `just create-database` after Postgres is healthy.
  "process-compose" is a small tool (like docker-compose but for plain processes) that starts
  several long-running commands together. Note: `create_schema` runs `just create-database`,
  but there is no `justfile` yet, so that step currently fails; this plan creates the
  `justfile`.

- `fourmolu.yaml` — configuration for `fourmolu`, the Haskell source-code formatter used in
  this repo. `nix/treefmt.nix` wires `fourmolu` (and other formatters) into a single command
  called `treefmt`, and `nix/pre-commit.nix` runs formatting checks as a git pre-commit hook.
  You should run `treefmt` before committing so the formatter and the pre-commit hook are
  satisfied.

- `.envrc` — contains `use flake` and `eval "$shellHook"`. If you use `direnv`, entering the
  directory automatically loads the same environment as `nix develop`. If you do not use
  `direnv`, run `nix develop` manually.

There is currently **no** `kansoku.cabal`, **no** `cabal.project`, **no** `api/` directory,
**no** `src/` directory, **no** `app/` directory, **no** `test/` directory, and **no**
`justfile`. This plan creates all of them. (The `api/` directory holds the shared
`kansoku-api` sub-library described under Coding Standards below.)

**Coding standards (established by this plan).** Kansoku follows the shared Haskell coding
standards documented under `/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/core/` —
specifically `standards.md`, `custom-prelude.md`, `record-patterns.md`, and
`multiline-strings.md`. EP-1 is the plan that *establishes* these standards for the whole
initiative, so every later plan (EP-2 through EP-8) simply follows what EP-1 sets up. In
concrete terms this plan introduces, and all Kansoku code obeys:

- A `common common` cabal stanza with `default-language: GHC2024` and the mandated
  `default-extensions`: `DeriveAnyClass`, `DuplicateRecordFields`, `OverloadedLabels`,
  `OverloadedStrings`, and `MultilineStrings`. Every `library`, `executable`, and `test-suite`
  stanza does `import: common` so the settings apply uniformly. GHC2024 already provides
  `DataKinds`, `DerivingStrategies`, `LambdaCase`, and `ImportQualifiedPost`, so those are
  never listed. `PackageImports` is **not** a global extension — it is a per-file pragma used
  only inside `Kansoku.Prelude`.
- A project prelude, `Kansoku.Prelude`, that re-exports the imports nearly every module needs
  (`Text`, `Generic`, the aeson class/`Options` machinery including `camelTo2`, time,
  `NonEmpty`, common `Control.Monad`/`Data.Maybe` helpers, and a blanket `Control.Lens`
  re-export) and provides a home for shared aeson `Options`. Every Kansoku module imports
  `Kansoku.Prelude` instead of re-importing these. The prelude deliberately does **not**
  re-export `Data.Generics.Labels`; each module that uses `#label` adds
  `import Data.Generics.Labels ()` itself (its orphan `IsLabel` instance must not be forced on
  every module). `Kansoku.Prelude` lives in a shared internal sub-library, `kansoku:kansoku-api`
  (source under `api/`), which this plan creates.
- Postpositive qualified imports (`import Data.Text qualified as Text`, never
  `import qualified …`); operators always imported unqualified.
- Records with strict fields (`!`), no field prefixes (rely on `DuplicateRecordFields`), and
  explicit deriving strategies (`deriving stock (Generic, Eq, Show)`,
  `deriving anyclass (FromJSON, ToJSON)`, `deriving newtype (…)`). Read and update records
  with generic-lens `#label` (`^.`, `.~`, `?~`, `%~`, `at`, `ix`) in preference to
  record-update syntax.
- `generic-lens ^>=2.2` and `lens ^>=5.3` are dependencies of the package that holds the
  prelude (`kansoku-api`); embedded SQL/JSON is written with `MultilineStrings` `"""…"""`
  literals.

Terms of art used below, defined once:

- **Cabal package / `.cabal` file**: the build description. It has "stanzas": a `library`
  stanza (reusable modules), an `executable` stanza (a runnable program), and a `test-suite`
  stanza (tests). Each stanza lists `build-depends` (libraries it needs) and where its source
  lives (`hs-source-dirs`).
- **`cabal.project`**: a file that tells Cabal which packages make up the build. Here it will
  contain just `packages: .` meaning "the one package described by the `.cabal` file in this
  directory".
- **`effectful`**: the effect-system library. Application code has type `Eff es a`, where `es`
  is a type-level list of the capabilities ("effects") the code may use and `a` is the result.
  You "discharge" (remove) effects one at a time with interpreter functions until only `IOE`
  (raw IO) is left, then `runEff` turns `Eff '[IOE] a` into `IO a`. The relevant modules and
  the exact functions they export (confirmed by reading the library source) are:
  - `Effectful` — exports the `Eff` monad, the `IOE` effect (permission to do IO), the
    `(:>)` constraint (`e :> es` means "effect `e` is available in stack `es`"), and
    `runEff :: Eff '[IOE] a -> IO a`.
  - `Effectful.Reader.Static` — exports the `Reader r` effect (a read-only value of type `r`),
    `runReader :: r -> Eff (Reader r : es) a -> Eff es a`,
    `ask :: (Reader r :> es) => Eff es r`, and `asks :: (Reader r :> es) => (r -> a) -> Eff es a`.
  - `Effectful.Dispatch.Dynamic` — exports `send`, `interpret`, and `EffectHandler`, used to
    define and interpret a custom effect (here, our `Log` effect).
- **WAI / Warp**: `wai` ("Web Application Interface") is the standard Haskell type for an HTTP
  application: `type Application = Request -> (Response -> IO ResponseReceived) -> IO
  ResponseReceived`. `warp` is the standard high-performance server that runs a WAI
  `Application` with `Network.Wai.Handler.Warp.run :: Int -> Application -> IO ()` (the `Int`
  is the TCP port). `http-types` provides status codes such as `Network.HTTP.Types.status200`.
  These are stable, widely-used Hackage packages available in the nixpkgs GHC 9.12 package set.


## Plan of Work

The work is organized into three milestones, each independently verifiable. Milestone 1 makes
the repository build at all. Milestone 2 adds real configuration, the effectful runtime, and
logging, proven by a unit test. Milestone 3 makes the server actually serve `/health`, proven
by a `curl` transcript. Do the milestones in order; each leaves the tree green.

### Milestone 1 — A buildable package

Scope: introduce the Cabal package so `cabal build` and `nix build` succeed, and establish the
coding-standards scaffolding (the `common` GHC2024 stanza and `Kansoku.Prelude`) that every
later plan builds on. At the end of this milestone there is a `kansoku.cabal` with a
`common common` stanza plus four stanzas — the shared `kansoku:kansoku-api` internal
sub-library (exposing `Kansoku.Prelude`), the main library, the `kansoku-server` executable,
and a test suite, each doing `import: common` — a `cabal.project`, the `Kansoku.Prelude`
module, a trivial main-library module, a placeholder executable `Main`, a placeholder test
`main`, and a `justfile`. Nothing does anything useful yet, but everything compiles and the Nix
build produces a binary.

Create `cabal.project` at the repository root whose only directive is:

```cabal
packages: .
```

preceded by a comment noting that EP-4 will add `source-repository-package` or additional
`packages:` entries for the author's non-Hackage libraries (`shibuya`, `shibuya-pgmq-adapter`,
`pgmq-hs`); this plan intentionally keeps it minimal. The exact file contents (comment plus
directive) are shown in Step 1 of Concrete Steps.

Create `kansoku.cabal` at the repository root with a `common common` stanza (holding
`default-language: GHC2024`, the shared `default-extensions`, and the warning flags), a
`library kansoku-api` internal sub-library (source under `api/`, exposing `Kansoku.Prelude`), a
main `library` stanza (source under `src/`, initially exposing just `Kansoku`, depending on
`kansoku:kansoku-api`), an `executable kansoku-server` stanza (source under `app/`,
`main-is: Main.hs`, depending on the `kansoku` library), and a `test-suite kansoku-test` stanza
(`type: exitcode-stdio-1.0`, source under `test/`, `main-is: Spec.hs`, depending on the
`kansoku` library and `hspec`). Every stanza does `import: common`. The exact contents are in
Concrete Steps. The `kansoku-api` sub-library depends on `base`, `aeson`, `text`, `time`,
`containers`, `uuid`, `servant`, `generic-lens ^>=2.2`, and `lens ^>=5.3` (it
must **not** depend on `servant-server`, `warp`, ClickHaskell, or pgmq — those belong to the
components that consume the API types, not to the shared base). Base dependencies for the main
`library` stanza are `base`, `kansoku:kansoku-api`, `text`, `bytestring`, `aeson`,
`containers`, `time`, `effectful`, `effectful-core`, and `generic-lens ^>=2.2` (for the
per-module `Data.Generics.Labels ()` import that enables `#label`); Milestone 3 adds `warp`,
`wai`, and `http-types`.

Create `api/Kansoku/Prelude.hs`, the project prelude, following `custom-prelude.md`: a
`{-# LANGUAGE PackageImports #-}` module using the `module Kansoku.Prelude (module X, module
Control.Lens) where` pattern, re-exporting the common types/functions and providing a home for
shared aeson `Options` (`eventAesonOptions`). Every other Kansoku module imports it.

Create `src/Kansoku.hs` as a trivial umbrella module exporting a version string, so the main
library has something to compile before later modules exist.

Create `app/Main.hs` and `test/Spec.hs` as placeholders (the real bodies land in later
milestones).

Create the `justfile` (see Concrete Steps) with `create-database`, `build`, `test`, `run`, and
`up` recipes.

Commands to run (from the repository root, inside `nix develop`): `cabal build` and then
`nix build`. Acceptance: `cabal build` compiles the `common` GHC2024 stanza, the `kansoku-api`
sub-library (including `Kansoku.Prelude`), the main library, the executable, and the test
suite; `nix build` finishes and `./result/bin/kansoku-server` exists.

### Milestone 2 — Configuration, effectful runtime, and logging

Scope: add the real `Kansoku.Config` record parsed from environment variables, the `Log`
effect and its stderr interpreter, and the `AppEffects` stack with `runApp`. Prove it with an
hspec unit test for `loadConfig`. At the end of this milestone the library exposes
`Kansoku.Config`, `Kansoku.Logging`, and `Kansoku.Runtime`, and `cabal test` passes.

Add `src/Kansoku/Config.hs` defining the `Config` record and `loadConfig :: IO (Either
ConfigError Config)`, reading `PG_CONNECTION_STRING`, `CLICKHOUSE_TCP_PORT`,
`CLICKHOUSE_HTTP_PORT`, and `KANSOKU_SERVER_PORT` via `System.Environment.lookupEnv`, applying
sensible defaults, and returning a clear error for a malformed integer port.

Add `src/Kansoku/Logging.hs` defining a dynamic `Log` effect with operations for the usual
levels and an interpreter `runLogStderr` that prints one JSON object per line to stderr.

Add `src/Kansoku/Runtime.hs` defining `type AppEffects = '[Log, Reader Config, IOE]` and
`runApp :: Config -> Eff AppEffects a -> IO a`.

Add these three modules to the library's `exposed-modules` in `kansoku.cabal`.

Add `test/Kansoku/ConfigSpec.hs` and have `test/Spec.hs` run it. The test sets and unsets the
relevant environment variables and asserts that `loadConfig` produces the expected `Config`
(defaults when unset; parsed values when set; an error for a non-numeric port).

Commands: `cabal test`. Acceptance: the test suite prints passing specs (for example
`3 examples, 0 failures`).

### Milestone 3 — The server serves `/health`

Scope: add the HTTP server and wire the executable so `kansoku-server` starts and answers
`GET /health` with HTTP 200. At the end, the observable end-to-end behavior from Purpose works.

Add `src/Kansoku/Server.hs` defining a WAI `Application` that returns `200 OK` for `/health`
and `404` otherwise, and `startServer` that reads the port from config, logs a startup line,
and runs Warp. Add `warp`, `wai`, and `http-types` to the library `build-depends` and add
`Kansoku.Server` to `exposed-modules`.

Rewrite `app/Main.hs` to call `loadConfig`, print a clear error and exit non-zero on failure,
otherwise `runApp cfg startServer`.

Commands: in one terminal, `cabal run kansoku-server`; in another,
`curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/health`. Acceptance: the second
command prints `200`. A full transcript is in Validation and Acceptance.


## Concrete Steps

Run everything from the repository root
`/Users/shinzui/Keikaku/bokuno/kansoku-project/kansoku`, inside the dev environment. Enter it
with:

```bash
nix develop
```

(If you use `direnv`, `cd` into the directory instead and it loads automatically.) Confirm the
toolchain and the environment variables are present:

```bash
ghc --version   # expect: The Glorious Glasgow Haskell Compilation System, version 9.12.4
cabal --version # expect a cabal-install 3.x line
echo "$PG_CONNECTION_STRING $CLICKHOUSE_TCP_PORT $CLICKHOUSE_HTTP_PORT"
```

### Step 1 — `cabal.project`

Create the file `cabal.project` at the repository root:

```cabal
-- Kansoku Cabal project. EP-1 keeps this minimal: a single local package.
-- EXTENSION POINT: EP-4 will add the author's non-Hackage libraries here, e.g.
--
--   source-repository-package
--     type: git
--     location: https://github.com/shinzui/shibuya
--     ...
--
-- or local `packages:` entries for shibuya, shibuya-pgmq-adapter, and pgmq-hs.
packages: .
```

### Step 2 — `kansoku.cabal` (Milestone 1 form)

Create the file `kansoku.cabal` at the repository root. Start with only the `Kansoku.Prelude`
and `Kansoku` modules exposed and without the web dependencies; Milestones 2 and 3 add modules
and dependencies to this same file. The `common common` stanza carries the coding standards
from `/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/core/standards.md`: `GHC2024` plus the
mandated `default-extensions`. Every other stanza does `import: common`, so those settings
apply uniformly and no stanza repeats `default-language`.

```cabal
cabal-version:      3.0
name:               kansoku
version:            0.1.0.0
synopsis:           Self-hostable product and web analytics service.
description:        Kansoku (観測, "observation") ingests analytics events, stores them in
                    ClickHouse, and serves typed metric queries. This package is the buildable
                    foundation: the shared prelude, the effectful runtime, configuration,
                    logging, and a health endpoint.
license:            BSD-3-Clause
author:             Nadeem Bitar
maintainer:         nadeem@gmail.com
build-type:         Simple

-- Shared settings for every stanza. GHC2024 + the mandated extensions come from
-- /Users/shinzui/Keikaku/bokuno/haskell-jitsurei/core/standards.md. GHC2024 already
-- provides DataKinds, DerivingStrategies, LambdaCase, and ImportQualifiedPost, so
-- they are NOT listed. PackageImports is deliberately absent here: it is a per-file
-- pragma used only in Kansoku.Prelude.
common common
    ghc-options:      -Wall -Wcompat -Wredundant-constraints
    default-language: GHC2024
    default-extensions:
        DeriveAnyClass
        DuplicateRecordFields
        OverloadedLabels
        OverloadedStrings
        MultilineStrings

-- Shared, dependency-light base library. Holds Kansoku.Prelude now; EP-2 adds the
-- event modules (Kansoku.Event*) and EP-4/EP-6 add the API type modules
-- (Kansoku.Api.*) to this same sub-library. It depends on servant (for the API
-- *type* declarations) but NEVER on servant-server, warp, ClickHaskell, or pgmq.
library kansoku-api
    import:           common
    hs-source-dirs:   api
    exposed-modules:  Kansoku.Prelude
    build-depends:
        , base           >=4.21 && <5
        , aeson
        , containers
        , generic-lens   ^>=2.2
        , lens           ^>=5.3
        , servant
        , text
        , time
        , uuid

library
    import:           common
    hs-source-dirs:   src
    exposed-modules:  Kansoku
    build-depends:
        , base           >=4.21 && <5
        , kansoku:kansoku-api
        , aeson
        , bytestring
        , containers
        , effectful
        , effectful-core
        , generic-lens   ^>=2.2
        , text
        , time

executable kansoku-server
    import:           common
    hs-source-dirs:   app
    main-is:          Main.hs
    build-depends:
        , base
        , kansoku

test-suite kansoku-test
    import:           common
    type:             exitcode-stdio-1.0
    hs-source-dirs:   test
    main-is:          Spec.hs
    build-depends:
        , base
        , kansoku
        , kansoku:kansoku-api
        , generic-lens
        , hspec
```

Note on version bounds: `callCabal2nix` selects dependency versions from the nixpkgs GHC 9.12
package set, so the bounds above are documentation, not the resolver's source of truth. They
are kept loose deliberately, except `generic-lens ^>=2.2` and `lens ^>=5.3`, which
`record-patterns.md` pins. `GHC2024` is the standard language edition that ships with GHC 9.12
and is mandated by the coding standards (it supersedes `GHC2021`).

Note on the sub-library: `kansoku:kansoku-api` is an *internal* (private) sub-library — it is
compiled and linked into `kansoku`, the executable, and the test suite, but not published
separately. Any component that imports `Kansoku.Prelude` must list `kansoku:kansoku-api` in its
own `build-depends` (as the main library and the test suite do above). The main library uses
`generic-lens` directly for the per-module `import Data.Generics.Labels ()` that enables
`#label`; the `lens` operators themselves arrive transitively through `Kansoku.Prelude`'s
blanket `Control.Lens` re-export.

### Step 3 — `Kansoku.Prelude` and the trivial library module

First create `api/Kansoku/Prelude.hs`, the project prelude that every other Kansoku module
imports. It follows `custom-prelude.md`: a per-file `{-# LANGUAGE PackageImports #-}` pragma
(package-qualified imports live *only* here, to disambiguate the re-exports), the
`module Kansoku.Prelude (module X, module Control.Lens) where` re-export pattern, and a home for
the shared aeson `Options`. It deliberately does **not** re-export `Data.Generics.Labels`; each
module that uses `#label` imports that orphan instance itself.

```haskell
{-# LANGUAGE PackageImports #-}

-- | The Kansoku project prelude. Every Kansoku module imports this instead of
-- re-importing Text, Generic, the aeson class machinery, lens operators, etc.
-- See /Users/shinzui/Keikaku/bokuno/haskell-jitsurei/core/custom-prelude.md.
--
-- PackageImports is used ONLY in this module, to disambiguate the collected
-- re-exports; it is not a project-wide default extension.
module Kansoku.Prelude
  ( module X
  , module Control.Lens
  , eventAesonOptions
  ) where

import "base" Control.Applicative as X ((<|>))
import "base" Control.Monad as X (guard, unless, void, when)
import "base" Control.Monad.IO.Class as X (MonadIO, liftIO)
import "base" Data.List.NonEmpty as X (NonEmpty (..))
import "base" Data.Maybe as X (fromMaybe, isJust, isNothing)
import "base" Data.Proxy as X (Proxy (..))
import "base" GHC.Generics as X (Generic)

import "text" Data.Text as X (Text)

import "aeson" Data.Aeson as X
  ( FromJSON
  , Options
  , SumEncoding (..)
  , ToJSON
  , camelTo2
  , defaultOptions
  , fromJSON
  , genericParseJSON
  , genericToJSON
  , parseJSON
  , toEncoding
  , toJSON
  )
import "aeson" Data.Aeson qualified as Aeson

import "time" Data.Time as X (UTCTime, getCurrentTime)

-- Blanket re-export of the lens operators used throughout the codebase.
import "lens" Control.Lens

-- NOTE: We deliberately do NOT `import "generic-lens" Data.Generics.Labels ()`
-- here. Its orphan IsLabel instance would then be forced on every module. Each
-- module that uses #label adds `import Data.Generics.Labels ()` itself.

-- | Standard Aeson options for Kansoku event/command sum types. Encodes as
-- {"type": "snake_case_tag", "data": {...}} with snake_cased field names.
-- EP-2 uses this when it adds the event model to kansoku-api.
eventAesonOptions :: Options
eventAesonOptions =
  defaultOptions
    { Aeson.sumEncoding = Aeson.TaggedObject "type" "data"
    , Aeson.constructorTagModifier = camelTo2 '_'
    , Aeson.tagSingleConstructors = True
    }
```

Then create `src/Kansoku.hs`:

```haskell
-- | Kansoku umbrella module. Re-exports the version and, over later milestones,
-- the public surface of the service.
module Kansoku
  ( version
  ) where

import Kansoku.Prelude

-- | The Kansoku package version, handy for a startup log line.
version :: String
version = "0.1.0.0"
```

### Step 4 — Placeholder executable and test

Create `app/Main.hs` (Milestone 3 replaces this body):

```haskell
module Main (main) where

import Kansoku (version)

main :: IO ()
main = putStrLn ("kansoku-server (placeholder) version " <> version)
```

Create `test/Spec.hs` (Milestone 2 replaces this body):

```haskell
module Main (main) where

import Test.Hspec (hspec, describe, it, shouldBe)

main :: IO ()
main = hspec $ do
  describe "placeholder" $ do
    it "compiles and runs" $ do
      True `shouldBe` True
```

### Step 5 — `justfile`

Create the file `justfile` at the repository root. `just` is a command runner already provided
by the dev shell. The `create-database` recipe is what `process-compose.yaml`'s `create_schema`
process invokes; it must be safe to run repeatedly, so it only creates the `kansoku` database
if it is absent. It connects to PostgreSQL over the Unix socket configured by the dev shell
(via `PGHOST`), using the `postgres` maintenance database for the existence check.

```makefile
# Kansoku developer commands. Run inside `nix develop`.

# Create the `kansoku` PostgreSQL database if it does not already exist.
# process-compose.yaml's `create_schema` process runs this after postgres is healthy.
create-database:
    @if psql -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = 'kansoku'" | grep -q 1; then \
        echo "database 'kansoku' already exists"; \
    else \
        createdb kansoku && echo "created database 'kansoku'"; \
    fi

# Build everything (library, server, tests).
build:
    cabal build all

# Run the unit tests.
test:
    cabal test

# Run the HTTP server.
run:
    cabal run kansoku-server

# Start the local services (postgres, clickhouse, create_schema) via process-compose.
up:
    process-compose up
```

Note: unlike `make`, `just` accepts recipe bodies indented with either spaces or tabs, as long
as the indentation is consistent within each recipe (the recipes above use four spaces; the
`makefile` language tag on the fence is only for syntax highlighting). If `just` complains
about indentation, check that you have not mixed tabs and spaces inside a single recipe.

### Step 6 — Build and verify Milestone 1

```bash
cabal build
```

Expected (abbreviated) output:

```text
Resolving dependencies...
Build profile: -w ghc-9.12.4 -O1
...
[1 of 1] Compiling Kansoku          ( src/Kansoku.hs, ... )
Linking .../kansoku-server ...
```

Then verify the Nix build (this is what `callCabal2nix` drives):

```bash
nix build
ls -l ./result/bin/kansoku-server
```

Expected: `nix build` completes without error and `./result/bin/kansoku-server` is listed as
an executable file. Tick the Milestone 1 boxes in Progress.

### Step 7 — `Kansoku.Config` (Milestone 2)

Create `src/Kansoku/Config.hs`:

The `Config` record follows `record-patterns.md`: strict fields (`!`), no field prefixes (rely
on `DuplicateRecordFields`), and explicit deriving strategies. `OverloadedStrings` is a shared
`default-extension` now, so no per-file pragma is needed. Imports are postpositive-qualified,
and `Text` comes from `Kansoku.Prelude`.

```haskell
-- | Runtime configuration for Kansoku, parsed from environment variables that
-- the dev shell (see nix/haskell.nix shellHook) already exports.
module Kansoku.Config
  ( Config (..)
  , ConfigError (..)
  , loadConfig
  , defaultServerPort
  ) where

import Kansoku.Prelude

import Data.Text qualified as Text
import System.Environment (lookupEnv)
import Text.Read (readMaybe)

-- | The port the HTTP server listens on when KANSOKU_SERVER_PORT is unset.
defaultServerPort :: Int
defaultServerPort = 8080

-- | All configuration the service needs at startup. Later plans extend this
-- record (EP-3 adds ClickHouse client settings, EP-4 adds pgmq/queue settings).
-- No field prefixes: fields are read with generic-lens #label (see Kansoku.Server).
data Config = Config
  { pgConnectionString :: !Text
  -- ^ PostgreSQL connection string (PG_CONNECTION_STRING). Unix-socket URI.
  , clickHouseTcpPort :: !Int
  -- ^ ClickHouse native TCP port (CLICKHOUSE_TCP_PORT), default 9000.
  , clickHouseHttpPort :: !Int
  -- ^ ClickHouse HTTP port (CLICKHOUSE_HTTP_PORT), default 8123.
  , serverPort :: !Int
  -- ^ The Kansoku HTTP server port (KANSOKU_SERVER_PORT), default 8080.
  }
  deriving stock (Generic, Eq, Show)

-- | A configuration failure with a human-readable message.
newtype ConfigError = ConfigError Text
  deriving stock (Generic, Eq, Show)

-- | Read configuration from the environment. Missing values fall back to
-- sensible defaults; a non-numeric port yields a Left with a clear message.
loadConfig :: IO (Either ConfigError Config)
loadConfig = do
  pg <- maybe defaultPg Text.pack <$> lookupEnv "PG_CONNECTION_STRING"
  chTcp <- lookupEnv "CLICKHOUSE_TCP_PORT"
  chHttp <- lookupEnv "CLICKHOUSE_HTTP_PORT"
  srv <- lookupEnv "KANSOKU_SERVER_PORT"
  pure $ do
    tcp <- parsePort "CLICKHOUSE_TCP_PORT" 9000 chTcp
    http <- parsePort "CLICKHOUSE_HTTP_PORT" 8123 chHttp
    port <- parsePort "KANSOKU_SERVER_PORT" defaultServerPort srv
    Right
      Config
        { pgConnectionString = pg
        , clickHouseTcpPort = tcp
        , clickHouseHttpPort = http
        , serverPort = port
        }
  where
    defaultPg = "postgresql:///kansoku"
    parsePort :: Text -> Int -> Maybe String -> Either ConfigError Int
    parsePort _ def Nothing = Right def
    parsePort name _ (Just raw) =
      case readMaybe raw of
        Just n -> Right n
        Nothing ->
          Left (ConfigError (name <> ": not a valid integer: " <> Text.pack raw))
```

### Step 8 — `Kansoku.Logging` (the `Log` effect)

Create `src/Kansoku/Logging.hs`. This defines a *dynamic* effect: `Log` is a small
capability with one operation (`LogMsg`), and `runLogStderr` is the interpreter that decides
what actually happens (here: print a JSON line to stderr). The `send` function submits an
operation to whatever interpreter is installed; `interpret` builds an interpreter.

GHC2024 already provides `DataKinds`, `LambdaCase`, and `GADTs` (so the GADT-style `Log`
constructor needs no pragma), and `OverloadedStrings` is a shared `default-extension`, so none
of those need per-file pragmas here. The one per-file pragma the effect definition still needs
is `TypeFamilies` (for the `type instance DispatchOf`), which GHC2024 genuinely does not
include. `Text` and `liftIO` come from `Kansoku.Prelude`; the remaining imports are
postpositive-qualified. Note that aeson is imported *qualified only* (`Aeson.object`,
`Aeson..=`): `Kansoku.Prelude` blanket-re-exports `Control.Lens`, which exports its own `(.=)`
operator, so an unqualified aeson `(.=)` would be rejected by GHC as an ambiguous occurrence.

```haskell
{-# LANGUAGE TypeFamilies #-}

-- | A minimal structured-logging effect. One JSON object per line to stderr.
-- The call sites (logInfo, logWarn, logError) are stable; only the interpreter
-- (runLogStderr) would change if a richer backend is adopted later.
module Kansoku.Logging
  ( Log
  , LogLevel (..)
  , logMsg
  , logInfo
  , logWarn
  , logError
  , runLogStderr
  ) where

import Kansoku.Prelude

-- aeson must be imported qualified only: Kansoku.Prelude blanket-re-exports
-- Control.Lens, which also exports an operator named (.=), so an unqualified
-- aeson import of (.=) would be an ambiguous occurrence.
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy.Char8 qualified as LBS8
import System.IO qualified as IO
import Effectful
  ( Dispatch (Dynamic)
  , DispatchOf
  , Eff
  , Effect
  , IOE
  , type (:>)
  )
import Effectful.Dispatch.Dynamic (interpret, send)

-- | Severity of a log line.
data LogLevel = Info | Warn | Error
  deriving stock (Generic, Eq, Show)

-- | The logging effect. A single first-order operation: emit one message.
data Log :: Effect where
  LogMsg :: LogLevel -> Text -> Log m ()

type instance DispatchOf Log = Dynamic

-- | Emit a message at an explicit level.
logMsg :: (Log :> es) => LogLevel -> Text -> Eff es ()
logMsg lvl msg = send (LogMsg lvl msg)

-- | Convenience wrappers.
logInfo, logWarn, logError :: (Log :> es) => Text -> Eff es ()
logInfo = logMsg Info
logWarn = logMsg Warn
logError = logMsg Error

-- | Interpret the Log effect by writing one JSON object per line to stderr.
runLogStderr :: (IOE :> es) => Eff (Log : es) a -> Eff es a
runLogStderr = interpret $ \_ -> \case
  LogMsg lvl msg ->
    liftIO . LBS8.hPutStrLn IO.stderr $
      Aeson.encode (Aeson.object ["level" Aeson..= levelText lvl, "message" Aeson..= msg])
  where
    levelText :: LogLevel -> Text
    levelText = \case
      Info -> "info"
      Warn -> "warn"
      Error -> "error"
```

Note: `liftIO` is re-exported by `Kansoku.Prelude` (from `Control.Monad.IO.Class`), which is
the same `liftIO` `effectful` uses, so it is not re-imported from `Effectful` here. `System.IO`
is imported postpositive-qualified as `IO` purely for `IO.stderr`; it is provided by `base` and
needs no new dependency.

### Step 9 — `Kansoku.Runtime` (the `AppEffects` stack and `runApp`)

Create `src/Kansoku/Runtime.hs`:

GHC2024 already provides `DataKinds` and `TypeOperators`, so this module needs no per-file
language pragmas. It imports `Kansoku.Prelude` per the project convention that every module
does, then the effectful and Kansoku modules it wires together (postpositive-qualified where
qualification is used).

```haskell
-- | The application's effect stack and its runner. This is the extension point
-- every later plan builds on: to add a capability, insert its effect into
-- AppEffects and its interpreter into the runApp chain, in matching order.
module Kansoku.Runtime
  ( AppEffects
  , runApp
  ) where

import Kansoku.Prelude ()

import Effectful (Eff, IOE, runEff)
import Effectful.Reader.Static (Reader, runReader)
import Kansoku.Config (Config)
import Kansoku.Logging (Log, runLogStderr)

-- | The base effect stack for the service.
--
--   * Log            — structured logging (Kansoku.Logging)
--   * Reader Config  — read-only access to configuration
--   * IOE            — raw IO
--
-- Later plans extend this list. For example EP-4 adds Pgmq and Tracing:
--
--   type AppEffects = '[Log, Tracing, Pgmq, Reader Config, IOE]
type AppEffects = '[Log, Reader Config, IOE]

-- | Run an AppEffects computation in IO by discharging each effect. The
-- interpreter chain mirrors AppEffects: the last interpreter applied
-- (runLogStderr) discharges the first effect in the list (Log), and runEff
-- discharges the final IOE. Later plans add interpreters here in the same
-- order they add effects to AppEffects, e.g.
--
--   runEff . runReader cfg . runTracing . runPgmq cfg . runLogStderr
runApp :: Config -> Eff AppEffects a -> IO a
runApp cfg = runEff . runReader cfg . runLogStderr
```

Add the three new modules to `kansoku.cabal`'s library `exposed-modules`:

```cabal
    exposed-modules:
        Kansoku
        Kansoku.Config
        Kansoku.Logging
        Kansoku.Runtime
```

### Step 10 — Unit test for `loadConfig`

Create `test/Kansoku/ConfigSpec.hs`:

The spec reads config fields with generic-lens `#label`, so it imports `Data.Generics.Labels ()`
(the per-module orphan-instance import the prelude deliberately omits). `OverloadedStrings`
comes from the shared `default-extensions`. Note the parentheses around each `cfg ^. #field`:
`^.` binds more loosely than the backtick-applied `shouldBe`, so the view must be parenthesized.

```haskell
module Kansoku.ConfigSpec (spec) where

import Kansoku.Prelude
import Data.Generics.Labels ()  -- enables #label access below

import Kansoku.Config (Config, loadConfig)
import System.Environment (setEnv, unsetEnv)
import Test.Hspec (Spec, describe, it, shouldBe, shouldSatisfy)

-- Ensure a clean slate for the variables loadConfig reads.
clearEnv :: IO ()
clearEnv =
  mapM_
    unsetEnv
    [ "PG_CONNECTION_STRING"
    , "CLICKHOUSE_TCP_PORT"
    , "CLICKHOUSE_HTTP_PORT"
    , "KANSOKU_SERVER_PORT"
    ]

spec :: Spec
spec = describe "Kansoku.Config.loadConfig" $ do
  it "uses defaults when nothing is set" $ do
    clearEnv
    result <- loadConfig
    case result of
      Left err -> fail ("expected defaults, got error: " <> show err)
      Right cfg -> do
        (cfg ^. #clickHouseTcpPort) `shouldBe` 9000
        (cfg ^. #clickHouseHttpPort) `shouldBe` 8123
        (cfg ^. #serverPort) `shouldBe` 8080

  it "parses values from the environment" $ do
    clearEnv
    setEnv "PG_CONNECTION_STRING" "postgresql:///kansoku"
    setEnv "CLICKHOUSE_TCP_PORT" "9100"
    setEnv "KANSOKU_SERVER_PORT" "9999"
    result <- loadConfig
    clearEnv
    case result of
      Left err -> fail ("expected a config, got error: " <> show err)
      Right cfg -> do
        (cfg ^. #pgConnectionString) `shouldBe` "postgresql:///kansoku"
        (cfg ^. #clickHouseTcpPort) `shouldBe` 9100
        (cfg ^. #serverPort) `shouldBe` 9999

  it "rejects a non-numeric port with a Left" $ do
    clearEnv
    setEnv "KANSOKU_SERVER_PORT" "not-a-number"
    result <- loadConfig
    clearEnv
    result `shouldSatisfy` isLeft
  where
    isLeft (Left _) = True
    isLeft _ = False
```

Replace `test/Spec.hs` so it runs this spec:

```haskell
module Main (main) where

import Kansoku.ConfigSpec qualified
import Test.Hspec (hspec)

main :: IO ()
main = hspec $ do
  Kansoku.ConfigSpec.spec
```

Add the spec module to the test suite so it is compiled. In the `test-suite kansoku-test`
stanza add:

```cabal
    other-modules:    Kansoku.ConfigSpec
```

Run the tests:

```bash
cabal test
```

Expected (abbreviated):

```text
Kansoku.Config.loadConfig
  uses defaults when nothing is set
  parses values from the environment
  rejects a non-numeric port with a Left

Finished in 0.00xx seconds
3 examples, 0 failures
```

Tick the Milestone 2 boxes in Progress.

### Step 11 — `Kansoku.Server` (Milestone 3)

Add `warp`, `wai`, and `http-types` to the library `build-depends` in `kansoku.cabal`:

```cabal
        , http-types
        , wai
        , warp
```

Add `Kansoku.Server` to `exposed-modules`.

Create `src/Kansoku/Server.hs`:

`OverloadedStrings` is a shared `default-extension`, so no per-file pragma is needed. The
module reads the configured port with generic-lens `#serverPort`, so it imports
`Data.Generics.Labels ()`; `Text` and `liftIO` come from `Kansoku.Prelude`, and the remaining
imports are postpositive-qualified.

```haskell
-- | The minimal HTTP server for EP-1: a single /health route returning 200 OK.
-- EP-4 replaces this WAI application with the servant application and mounts
-- /health alongside the ingestion endpoints; the startServer entry point and
-- the /health contract remain.
module Kansoku.Server
  ( healthApp
  , startServer
  ) where

import Kansoku.Prelude
import Data.Generics.Labels ()  -- enables #serverPort access below

import Data.Text qualified as Text
import Effectful (Eff, IOE, type (:>))
import Effectful.Reader.Static (Reader, asks)
import Kansoku.Config (Config)
import Kansoku.Logging (Log, logInfo)
import Network.HTTP.Types (status200, status404)
import Network.HTTP.Types.Header (hContentType)
import Network.Wai (Application, pathInfo, responseLBS)
import Network.Wai.Handler.Warp qualified as Warp

-- | The WAI application. GET /health -> 200 "OK"; everything else -> 404.
healthApp :: Application
healthApp req respond =
  case pathInfo req of
    ["health"] ->
      respond (responseLBS status200 [(hContentType, "text/plain")] "OK")
    _ ->
      respond (responseLBS status404 [(hContentType, "text/plain")] "Not Found")

-- | Read the configured port, log a startup line, and run Warp. This blocks.
startServer :: (IOE :> es, Reader Config :> es, Log :> es) => Eff es ()
startServer = do
  port <- asks (^. #serverPort)
  logInfo ("kansoku-server listening on port " <> Text.pack (show port) <> " (GET /health)")
  liftIO (Warp.run port healthApp)
```

Note: `healthApp` is a pure WAI `Application` running in `IO`, which is sufficient for the
health check. EP-4, when it needs its HTTP handlers to run in `Eff` (to enqueue to pgmq), will
bridge `Eff` into a WAI/servant handler using `Effectful`'s `withEffToIO`; that is out of
scope for EP-1 and noted here only so the extension is clear.

### Step 12 — Wire the executable

Replace `app/Main.hs`:

```haskell
module Main (main) where

import Kansoku.Config (loadConfig)
import Kansoku.Runtime (runApp)
import Kansoku.Server (startServer)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
  result <- loadConfig
  case result of
    Left err -> do
      hPutStrLn stderr ("configuration error: " <> show err)
      exitFailure
    Right cfg ->
      runApp cfg startServer
```

Format, build, and run:

```bash
treefmt
cabal build
cabal run kansoku-server
```

Expected server startup line on stderr (the log is JSON):

```text
{"level":"info","message":"kansoku-server listening on port 8080 (GET /health)"}
```

Tick the Milestone 3 boxes after the `curl` check in Validation and Acceptance passes.


## Validation and Acceptance

Acceptance is behavior a human can observe, not merely code that compiles. Perform all of the
following from the repository root inside `nix develop`.

Build acceptance (Milestone 1):

```bash
cabal build
nix build && test -x ./result/bin/kansoku-server && echo "nix build OK"
```

Expected: `cabal build` compiles the `common` GHC2024 stanza, the `kansoku-api` sub-library
(including `Kansoku.Prelude`), the main library, the executable, and the test suite, and links
without errors; the second line prints `nix build OK`. If `cabal build` complains that
`GHC2024` or `MultilineStrings` is unknown, you are on a compiler older than GHC 9.12 — re-enter
`nix develop` so GHC 9.12.4 is on the path (the coding standards require 9.12+ for exactly these
features).

Test acceptance (Milestone 2):

```bash
cabal test
```

Expected: the run ends with `3 examples, 0 failures`. To prove the test is meaningful (not
vacuous), temporarily break `loadConfig`'s default (for example change `defaultServerPort` to
`1`) and re-run `cabal test`; you should see the "uses defaults when nothing is set" example
fail with an expected-8080-but-got-1 message. Revert the change afterward.

Server acceptance (Milestone 3): start the server in one terminal:

```bash
cabal run kansoku-server
```

In a second terminal, exercise the health endpoint:

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080/health
```

Expected transcript:

```text
200
```

Also confirm the body and a non-health path:

```bash
curl -s http://localhost:8080/health          # expect: OK
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:8080/nope   # expect: 404
```

If you set a custom port, the check follows it:

```bash
KANSOKU_SERVER_PORT=9090 cabal run kansoku-server &
sleep 1
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:9090/health  # expect: 200
```

Stop the server with Ctrl-C (or `kill %1` for the backgrounded form).

Local services sanity check (optional but recommended, since this plan created the `justfile`
that `process-compose.yaml` depends on): from a fresh shell that has the Postgres socket
available, verify the `create-database` recipe is idempotent:

```bash
just create-database   # first run: "created database 'kansoku'" (or already exists)
just create-database   # second run: "database 'kansoku' already exists"
```

Note: this requires the `postgres` process to be running (start everything with `just up`,
which runs `process-compose up`). It is not required for the server acceptance above — the
EP-1 server does not touch Postgres — but it verifies the `create_schema` step is no longer
broken.


## Idempotence and Recovery

Every step in this plan is additive and safe to repeat. Re-running `cabal build`, `cabal test`,
`nix build`, and `cabal run kansoku-server` is always safe; Cabal and Nix cache and rebuild
only what changed. Creating the source files is idempotent in the sense that the plan lists
the final contents; if a file already exists, compare it to the version here and reconcile.

The `just create-database` recipe is explicitly idempotent: it checks `pg_database` first and
only calls `createdb` when the `kansoku` database is absent, so running it any number of times
leaves exactly one database and prints a clear "already exists" message on subsequent runs.

If `cabal build` fails to resolve a dependency (for example `warp` or `hspec`), you are almost
certainly outside `nix develop`; re-enter it so the nixpkgs GHC 9.12 package set is on the
path, and retry. If `nix build` fails with "cannot find kansoku.cabal", confirm the file is at
the repository root (not under `src/`) and is named exactly `kansoku.cabal`. If the server
fails to bind with "address already in use", another process holds the port; choose a
different one with `KANSOKU_SERVER_PORT` or stop the other process.

There are no destructive or migration steps in this plan, so there is nothing to back up or
roll back. To undo the plan entirely, delete the files it created (`kansoku.cabal`,
`cabal.project`, `justfile`, and the `src/`, `app/`, and `test/` directories); nothing else in
the repository is modified.

Commit frequently — ideally once per milestone. Every commit under this initiative must carry
these git trailers so work can be traced back to the plan and its intention:

```text
feat(runtime): scaffold kansoku package with health server

Create kansoku.cabal (library, kansoku-server executable, hspec test
suite), cabal.project, and a justfile. Add Kansoku.Config, the Log
effect, the AppEffects/runApp effectful runtime, and a /health WAI
server returning 200 OK.

MasterPlan: docs/masterplans/1-kansoku-analytics-service-mvp.md
ExecPlan: docs/plans/1-project-skeleton-and-application-runtime.md
Intention: intention_01kwf425fxenc904ear54cr2n7
```

Commit directly to the current branch (`master`); do not create a feature branch. Use
Conventional Commit types (`feat:`, `fix:`, `docs:`, `chore:`, etc.).


## Interfaces and Dependencies

This section names the exact libraries, modules, types, and signatures that must exist at the
end of each milestone. Later plans depend on these being present and stable.

Libraries used and why:

- `effectful` and `effectful-core` — the effect system the whole codebase uses. From
  `Effectful`: `Eff`, `IOE`, `runEff :: Eff '[IOE] a -> IO a`, the `(:>)` constraint,
  `liftIO`, and the effect-definition machinery (`Effect`, `Dispatch (Dynamic)`,
  `DispatchOf`). From `Effectful.Reader.Static`: `Reader`, `runReader`, `ask`, `asks`. From
  `Effectful.Dispatch.Dynamic`: `send`, `interpret`. Chosen because the author's libraries
  (`pgmq-effectful`, `shibuya`, etc.) are all `effectful`-based, so later plans plug directly
  into this runtime.
- `aeson`, `text`, `bytestring` — used by the logging interpreter to encode JSON log lines and
  by `Config` for text handling. `aeson` also supplies `camelTo2` (exported from
  `Data.Aeson`/`Data.Aeson.Types`), which `Kansoku.Prelude` re-exports for the shared
  `eventAesonOptions`.
- `generic-lens ^>=2.2` and `lens ^>=5.3` — the record conventions from `record-patterns.md`.
  `Kansoku.Prelude` blanket-re-exports `Control.Lens`; modules that use `#label` access add
  `import Data.Generics.Labels ()` (from `generic-lens`) themselves. These, plus `uuid` and
  `servant` (the API *type* declarations EP-4/EP-6 add), are dependencies of the shared
  `kansoku-api` sub-library that holds `Kansoku.Prelude`.
- `warp`, `wai`, `http-types` — the minimal HTTP server for `/health` (see Decision Log for
  why not `servant` yet). `Network.Wai.Handler.Warp.run :: Int -> Application -> IO ()`;
  `type Application = Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived`;
  `Network.Wai.responseLBS`, `Network.Wai.pathInfo`; `Network.HTTP.Types.status200`,
  `status404`; `Network.HTTP.Types.Header.hContentType`.
- `hspec` — the test framework (see Decision Log).
- `containers`, `time` — listed in the base library dependencies for the modules later plans
  add (event maps, timestamps); harmless to include now.

Cabal package structure that must exist (MasterPlan integration point "cabal package
structure"): `kansoku.cabal` at the repository root with a `common common` stanza
(`default-language: GHC2024` plus the mandated `default-extensions`) that every other stanza
does `import: common`; a `library kansoku-api` internal sub-library (source under `api/`)
exposing at least `Kansoku.Prelude`; a main `library` stanza whose `exposed-modules` end at
`Kansoku`, `Kansoku.Config`, `Kansoku.Logging`, `Kansoku.Runtime`, and `Kansoku.Server` and
which depends on `kansoku:kansoku-api`; an `executable kansoku-server` with `main-is: Main.hs`
under `app/`; and a `test-suite kansoku-test` (`exitcode-stdio-1.0`, `main-is: Spec.hs`,
`other-modules: Kansoku.ConfigSpec`, depending on `kansoku:kansoku-api`) under `test/`. A
`cabal.project` with `packages: .` and a documented extension point for EP-4's non-Hackage
sources. The shared `kansoku:kansoku-api` internal sub-library is the dependency-light base that
holds `Kansoku.Prelude` now and the event model and servant API *type declarations* later
(depending on `servant`, aeson, text, time, containers, uuid, `generic-lens`,
`lens`, and `base` — never servant-server, warp, ClickHaskell, or pgmq), reused by the server,
the SDK (servant-client), and the OpenAPI generator. **EP-1 creates this sub-library** (with
`Kansoku.Prelude`), because the prelude belongs in the shared base every component depends on;
EP-2 then adds the event modules (`Kansoku.Event*`) to it, and EP-4/EP-6 add the API type
modules (`Kansoku.Api.Ingest`, `Kansoku.Api.Metrics`, `Kansoku.Api`). The module paths stay
stable regardless of which later plan populates them. (This supersedes an earlier draft of this
plan, which said EP-1 "need not create" the sub-library; because the prelude must live in the
shared base, EP-1 now creates the `kansoku-api` skeleton up front.)

Signatures that must exist at the end of each milestone (full module paths):

End of Milestone 1:

- `Kansoku.Prelude` — the project prelude in the `kansoku-api` sub-library, re-exporting the
  common imports (`module X`, `module Control.Lens`) and exporting the shared
  `eventAesonOptions :: Options`. Every later Kansoku module imports it. Its existence and the
  `common` GHC2024 stanza are the coding-standards foundation the rest of the initiative relies
  on.
- `Kansoku.version :: String` — proves the main library compiles and links against the
  `kansoku-api` sub-library.

End of Milestone 2 (MasterPlan integration point "configuration module and effectful runtime
stack"):

- `Kansoku.Config.Config` — a record with strict, unprefixed fields `pgConnectionString ::
  !Text`, `clickHouseTcpPort :: !Int`, `clickHouseHttpPort :: !Int`, `serverPort :: !Int`
  (read via generic-lens `#label`, e.g. `cfg ^. #serverPort`), `deriving stock (Generic, Eq,
  Show)`. Later plans add fields (EP-3 ClickHouse client settings; EP-4 pgmq/queue settings).
- `Kansoku.Config.ConfigError` and
  `Kansoku.Config.loadConfig :: IO (Either ConfigError Config)`.
- `Kansoku.Logging.Log` — the effect; `Kansoku.Logging.LogLevel`;
  `logInfo, logWarn, logError :: (Log :> es) => Data.Text.Text -> Eff es ()`;
  `runLogStderr :: (IOE :> es) => Eff (Log : es) a -> Eff es a`.
- `Kansoku.Runtime.AppEffects` (`= '[Log, Reader Config, IOE]`) and
  `Kansoku.Runtime.runApp :: Config -> Eff AppEffects a -> IO a`. This is the shared runtime
  every later plan extends by adding effects to `AppEffects` and interpreters to the `runApp`
  chain in matching order.

End of Milestone 3 (foundation for the MasterPlan "HTTP ingestion API contract", which EP-4
extends):

- `Kansoku.Server.healthApp :: Network.Wai.Application`.
- `Kansoku.Server.startServer :: (IOE :> es, Reader Config :> es, Log :> es) => Eff es ()`.
- `Main.main :: IO ()` in `app/Main.hs`, wiring `loadConfig`, `runApp`, and `startServer`.

Downstream dependents (for coordination; from the MasterPlan Dependency Graph): every other
plan (EP-2 through EP-8) hard- or soft-depends on EP-1, and every one of them inherits the
`common` GHC2024 stanza and imports `Kansoku.Prelude` that EP-1 establishes. EP-2 adds
`Kansoku.Event*` to the `kansoku-api` sub-library; EP-3 adds `Kansoku.ClickHouse.*` and
ClickHouse config; EP-4 adds servant/warp ingestion, the `Kansoku.Api.*` type modules to
`kansoku-api`, the `Pgmq`/`Tracing` effects to `AppEffects`, and the non-Hackage `packages:`
entries to `cabal.project`; EP-6 adds the metrics query server wiring. Each of those extends
the interfaces named above (and follows the coding standards EP-1 sets up) rather than replacing
them.


## Revision Notes

- 2026-07-01 — **Adopted the shared Kansoku Haskell coding standards.** The initial draft of
  this plan compiled and ran but did not follow the authoritative standards under
  `/Users/shinzui/Keikaku/bokuno/haskell-jitsurei/core/` (`standards.md`, `custom-prelude.md`,
  `record-patterns.md`, `multiline-strings.md`). It used `GHC2021`, a `common warnings` stanza
  with per-stanza `default-language`, per-file `OverloadedStrings`/`DataKinds`/`LambdaCase`
  pragmas, prepositive `import qualified`, `config`-prefixed lazy record fields with record
  accessors, and no project prelude. Because EP-1 is the foundation every later plan (EP-2
  through EP-8) builds on, it *owns* establishing these standards — leaving them out would have
  forced each later plan to either reinvent or retrofit them. This revision therefore reworks
  EP-1 to establish, and comply with, the standards throughout:
  - Cabal: replaced `common warnings` + `GHC2021` with a `common common` stanza on
    `default-language: GHC2024` carrying the mandated `default-extensions` (`DeriveAnyClass`,
    `DuplicateRecordFields`, `OverloadedLabels`, `OverloadedStrings`, `MultilineStrings`); every
    stanza now does `import: common`. GHC2024 already provides `DataKinds`,
    `DerivingStrategies`, `LambdaCase`, and `ImportQualifiedPost`, so those pragmas/extensions
    were removed. Added `generic-lens ^>=2.2`, `lens ^>=5.3`, `aeson-casing`, `uuid`, and
    `servant` to the relevant build-depends. (`aeson-casing` was subsequently dropped again —
    see the validation-pass revision note below.)
  - Created the shared `kansoku:kansoku-api` internal sub-library up front, holding
    `Kansoku.Prelude` (source under `api/`). This refines the earlier Interfaces note that said
    EP-1 "need not create" the sub-library: because the prelude belongs in the shared base, EP-1
    now creates the skeleton; EP-2 adds the event modules and EP-4/EP-6 add `Kansoku.Api.*`
    there. `PackageImports` is confined to a per-file pragma in `Kansoku.Prelude`, not a global
    extension, per `custom-prelude.md`.
  - Reworked every Haskell sketch (`Kansoku.Prelude`, `Kansoku`, `Kansoku.Config`,
    `Kansoku.Logging`, `Kansoku.Runtime`, `Kansoku.Server`, `Kansoku.ConfigSpec`) to import
    `Kansoku.Prelude`, use postpositive qualified imports, and — for `Config` — strict fields,
    no prefixes, explicit deriving, and generic-lens `#label` access (`asks (^. #serverPort)`,
    `cfg ^. #field`) with a per-module `import Data.Generics.Labels ()` where `#label` is used.
  - Reflected the change across Progress, Milestones, Decision Log, Validation, and Interfaces
    (added `Kansoku.Prelude` to the interface list, the sub-library to the package structure,
    and a milestone acceptance that `cabal build` compiles the `common` stanza + prelude).
  - Rationale: these standards are authoritative for every Haskell project in this codebase;
    establishing them here keeps GHC2024, the shared extensions, the prelude, and the record
    conventions consistent across all eight ExecPlans instead of drifting per plan.

- 2026-07-01 — **Corrections from a pre-implementation validation pass.** Before any code was
  written, a validation pass over the plan's sketches and prose found two would-be compile
  errors and several factual inaccuracies. This revision fixes all of them so a novice
  following the plan verbatim succeeds on the first attempt:
  - `camelTo2` was imported from `Data.Aeson.Casing` (package `aeson-casing`), but that
    package does not export `camelTo2`; the function lives in aeson itself (`Data.Aeson` /
    `Data.Aeson.Types`). The prelude sketch now re-exports `camelTo2` from its existing
    `Data.Aeson` import, and `aeson-casing` was removed from the `kansoku-api` build-depends
    and from every prose dependency list (see the new Decision Log entry). The stale
    justification for the dependency in Interfaces and Dependencies was removed with it.
  - `Kansoku.Logging` imported `Data.Aeson (object, (.=))` unqualified while `Kansoku.Prelude`
    blanket-re-exports `Control.Lens`, which exports its own `(.=)` — GHC would reject every
    use as an ambiguous occurrence. The sketch now imports aeson qualified only and uses
    `Aeson.object` / `Aeson..=`, with a note in Step 8 explaining why.
  - The Step 8 prose claimed `GADTs` is needed because "GHC2024 does not include it" — false:
    GHC2024 does include `GADTs`. The redundant `{-# LANGUAGE GADTs #-}` pragma was dropped
    from the sketch; `TypeFamilies` (genuinely absent from GHC2024) remains the module's one
    per-file pragma, and the prose now says so correctly.
  - The Step 5 note claimed `just` "requires tab-indented recipe bodies" — false: unlike
    `make`, `just` accepts spaces or tabs so long as each recipe is indented consistently. The
    note was rewritten accordingly.
  - Milestone 1 said `cabal.project` contains "exactly" `packages: .` while Step 1 shows the
    file with an explanatory comment block. Milestone 1 (and the matching Decision Log entry)
    now say the file's only *directive* is `packages: .` and point to Step 1 for the exact
    contents, so the two sections agree.
  - Enumerations reading "EP-2 through EP-7" (and "all seven ExecPlans") predated the addition
    of EP-8 to the MasterPlan's registry; wherever the meaning is "all later plans", they now
    read EP-2 through EP-8 / all eight ExecPlans.
