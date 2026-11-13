---
id: 69
slug: save-named-analyses-for-an-account
title: "Save named analyses for an account"
kind: exec-plan
created_at: 2026-11-13T00:56:28Z
intention: "intention_01m796f2tse68rv4yraze7kkse"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-11-13T00:56:28Z
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-11-13T01:03:04Z
      mode: "update"
      note: "Correct Mori availability after refreshing stale inherited shell environment"
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-13T04:54:31Z
      mode: "implement"
      note: "Implement saved analysis persistence, revision safety, pagination and public contracts"
---

# Save named analyses for an account

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current during implementation. Record implementation friction through `agents/skills/exec-plan/record-friction.ts` and distill durable decisions into the profiled `docs/adr/` bundle before completion.


## Purpose / Big Picture

Implement [IR-19](../improvement-requests/save-named-analyses-for-an-account.md): people sharing a Kansoku account can save, reopen, replace and delete named trend, funnel and retention analyses. A service-token client stores its own versioned JSON document and gets it back as an equal JSON value. Kansoku does not understand or execute that document. Two editors cannot silently overwrite each other: writes require the revision returned by the last read.

The observable result is a `/analyses` library with bounded, bidirectional pages ordered by latest update, an optional kind filter, and a typed Haskell client. This unblocks the consumer initiative `mori://shinzui/kansoku-ui/masterplans/7-build-the-insights-library-of-saved-analyses`; it is not a child of that cross-repository MasterPlan. No UI work, default seeding, name search, document execution, or reference validation is included.


## Progress

- [x] Milestone 1 (2026-11-13): Saved analyses round-trip through authenticated HTTP and private PostgreSQL with opaque document equality, foreign-ID 404 and write-key 403. Focused Kansoku.Analysis suite: 6 examples, 0 failures, no pending cases.
- [x] Milestone 2 (2026-11-13): Real PostgreSQL tests and owned executable HTTP acceptance pass atomic replacement/deletion, independent concurrent update/create connections, quota=2, separate account allowances, and forward/backward filtered keyset traversal. Equal-timestamp fixtures preserve microseconds and deleted cursor rows remain usable.
- [ ] Milestone 3: Published contracts, generated client, and owned packaged HTTP acceptance cover all five request criteria and regressions.


## Surprises & Discoveries

The existing Relay timestamp codec stores integer microseconds and round-trips persisted timestamps exactly, so no custom ordering projection or dependency upgrade was needed. Its established pagination contract accepts first=0/last=0 and returns pagination errors as JSON; field and resource problems retain application/problem+json. Both contracts are exercised independently.


Cancellation while an advisory-lock query is in flight can make the connection reject an explicit rollback. Cleanup now preserves the original exception and closes the dedicated connection as the final rollback boundary. A real lock-wait cancellation test proves propagation and subsequent lock availability; the final focused suite passes 8 examples.


## Decision Log

On 2026-11-13, choose `/analyses`, PostgreSQL persistence, service-token authentication, and an independent analysis envelope. Existing metric definitions are executable and cohorts define populations; neither is an appropriate storage contract for opaque client state. Duplicate names are allowed, and replacement may change kind.

On 2026-11-13, choose a positive numeric `revision`, initially 1, supplied in PUT bodies and as the required DELETE query parameter `revision`. Successful PUT increments it even for identical content. Stale writes return 409, missing/foreign IDs return 404. Use a resource-specific typed result with a conflict alternative rather than adding 409 to every existing endpoint.

On 2026-11-13, choose current-read keyset pagination ordered by `updated_at DESC, id ASC`. A keyset cursor stores the ordering values rather than a row offset or a reference requiring the row to still exist. It remains usable after deletion or replacement of the cursor row. This is not a cross-request snapshot: concurrent edits can move rows across a previously read boundary. Consumers refresh from the first page after edits.

On 2026-11-13, choose serialized JSON text storage for the opaque document, with validation before storage and decoding on reads. PostgreSQL JSONB has representability restrictions unnecessary for an opaque document (notably escaped zero characters and numeric range). Bound the compact Aeson UTF-8 encoding to 32,768 bytes, and store that same encoding as text. This preserves JSON value equality without introducing document semantics or accidental database-driven validation rules.


## Outcomes & Retrospective


## Context and Orientation

The repository has Haskell packages for shared API types (`kansoku-api`), handlers and stores (`kansoku-core`), executables (`kansoku-server`), and clients (`kansoku-client`). `kansoku-api/src/Kansoku/Api.hs` assembles named route records; `kansoku-core/src/Kansoku/Server.hs` wires handlers and classifies protected query routes. `kansoku-client/src/Kansoku/Client/Metrics.hs` exposes generated resource clients such as `metricDefinitionsClient` and `kansokuMetricsCredential`.

Use `kansoku-api/src/Kansoku/Metrics/DefinitionApi.hs`, `kansoku-core/src/Kansoku/Metrics/DefinitionStore.hs`, and `kansoku-core/src/Kansoku/Metrics/DefinitionHandler.hs` as local examples for resource CRUD (create, read, update and delete). Their lists use `RelayPage 20 100`: default 20 and maximum 100 items, with `first`, `after`, `last`, and `before`. Relay connections contain edges with opaque cursors plus page information. Preserve the existing parameter combinations, rejection rules and canonical order in both directions. The existing metric update path does not provide the revision or quota semantics required here; do not copy its read-then-write behavior.

`kansoku-core/src/Kansoku/Migrations.hs` owns the explicit PostgreSQL migration component, currently ending at `0009-replicated-jobs`. Append a migration; startup does not migrate. `kansoku-core/test/Kansoku/MigrationsSpec.hs` shows fresh isolated database creation, strict verification, and repeat application. `kansoku-core/src/Kansoku/Cohort/Handler.hs` and `kansoku-core/src/Kansoku/Postgres/Direct.hs` demonstrate a dedicated connection and transaction-scoped advisory lock: a database lock released automatically at transaction end, usable across server processes.

The following consulted ADRs constrain this work. [ADR-3](../adr/0003-api-key-authentication-and-account-scoped-analytics.md) requires leaf-level authentication, deriving the account only from the principal, and 403 for write keys on service routes. [ADR-8](../adr/0008-rfc9457-problem-details-and-generated-client-media.md) requires typed problem responses with `application/problem+json`, explicit success media types, shared problem codes and generated-client decoding. [ADR-19](../adr/0019-saved-query-time-cohorts-and-static-membership.md) establishes PostgreSQL resource persistence, Relay pagination, current reads without snapshots, and the existing Relay pagination-error exception. [ADR-20](../adr/0020-custom-metric-definitions-and-bounded-or-filters.md) describes the executable saved-metric resource this feature deliberately does not extend. [ADR-10](../adr/0010-owned-executable-acceptance-environments.md) requires owned databases and actual packaged executable evidence, with no pending tests counted as success.

At creation, the working tree already contains substantial staged and unstaged identified-user work, including modifications to API assembly, OpenAPI and acceptance scripts. Preserve it; merge new resource registration into the current files. No implementation was performed while authoring this plan.

Mori is available. Initial discovery failed because this agent inherited an obsolete PostgreSQL connection setting and the Home Manager `__HM_ZSH_SESS_VARS_SOURCED` guard prevented a fresh login shell from refreshing it. Running `env -u __HM_ZSH_SESS_VARS_SOURCED /bin/zsh -lc 'mori registry list; mori registry search relay-pagination'` successfully refreshed the environment and located `mori://shinzui/relay-pagination`. This was a stale agent environment, not a Mori service outage. Before writing any unfamiliar dependency API, use `mori registry search`, `show --full`, and `docs` to locate the relevant source. No dependency version changes are proposed. Never search `/nix/store` or the filesystem root.


## Plan of Work

### Milestone 1: Persist and reopen the envelope


Add `kansoku-api/src/Kansoku/Analysis/Types.hs` and `kansoku-api/src/Kansoku/Analysis/Api.hs`. Define `AnalysisKind` as `trends | funnel | retention`, `AnalysisInput` containing name, optional description, kind, positive integer documentVersion and document, `AnalysisReplace` containing those fields plus revision, and `SavedAnalysis` containing those fields plus UUID id, revision, createdAt and updatedAt. JSON fields are flat camelCase. Omitted or null description means absent; return null when absent. POST/PUT are full replacements, with no PATCH or merge behavior. Use an unbounded Haskell integer for documentVersion so a client version is not silently truncated. Revision uses PostgreSQL bigint with checked increment, never wrapping.

Add `kansoku-core/src/Kansoku/Analysis/Validation.hs`, `Store.hs`, and `Handler.hs`. Trim names and require 1..120 Unicode characters; descriptions retain whitespace and have at most 500 Unicode characters. Count Unicode characters, not UTF-8 bytes. Require a JSON object document, with compact serialized bytes at most 32,768. Validate documentVersion as an integral positive number. Reject unknown kinds, missing fields, wrong types and malformed revisions with 400 problems that name the field. Keep field-aware decoding errors through the framework formatter. Metadata names/descriptions must reject zero characters with a field-specific 400 because PostgreSQL text cannot store them; zero characters inside the encoded opaque document remain escaped and must round-trip.

Append `0010-saved-analyses` (or the next unused migration if the tree advances) in `kansoku-core/src/Kansoku/Migrations.hs`. Create `kansoku.analyses` with UUID primary key, account_id, name, nullable description, kind, numeric document_version constrained positive and integral, document_text, bigint revision initially 1, and timestamptz created_at/updated_at. Add metadata and encoded-size constraints where they match application validation. Do not convert document_text to JSONB in constraints, parameters or read projections. Index `(account_id, updated_at DESC, id ASC)` and `(account_id, kind, updated_at DESC, id ASC)`. No name uniqueness constraint or analytics-store table is needed.

Wire the new resource into the API, server, query-route classification, and package module lists in `kansoku-api/kansoku-api.cabal` and `kansoku-core/kansoku-core.cabal`. Implement POST and GET first as an end-to-end slice. POST returns 200, consistent with metric definitions; GET returns 200 or account-scoped 404. Every SQL read and mutation binds account_id. Test a real HTTP POST/GET with nested Unicode, numeric and null document values before expanding the surface. This proves envelope decoding, storage encoding and response decoding together. Add migration and pure validation tests; milestone acceptance is this roundtrip plus foreign-ID 404 and write-key 403.

### Milestone 2: Safe shared editing and pages


Finish `Store.hs` with explicit outcomes for saved/deleted, missing, stale revision, quota exceeded, and storage failure. Serialize account mutations using a namespaced account advisory transaction lock, on the same connection as all reads and writes. Under READ COMMITTED, acquire the lock in a separate statement before reading the count or current row; a statement snapshot taken before waiting must not admit an extra row. Use the existing dedicated-session pattern, bracket cleanup and rollback on exceptions, including cancellation. All create, replace and delete paths participate in this lock. Bind SQL values; do not interpolate account names or documents. Hash collisions may serialize unrelated accounts but must not change account predicates.

POST checks count and inserts atomically under the lock. Add positive configuration `KANSOKU_ANALYSES_MAX_PER_ACCOUNT` defaulting to 1000 in `kansoku-core/src/Kansoku/Config.hs`, its parsing tests, and server wiring. Lowering the configured limit does not delete data: reads, replacement and deletion continue; creates fail until count is below the limit. All replicas must use the same limit. The small-limit test uses 2. Return a non-retryable 409 `analysis_limit_reached` when full.

For PUT and DELETE, look up only `(account_id,id)` under the lock, return 404 `analysis_not_found` if absent, then compare the required revision. A mismatch returns 409 `analysis_revision_conflict` and changes nothing. PUT writes the entire envelope, increments revision and preserves createdAt; set updatedAt strictly later than its previous value using the greater of database current time and previous value plus one microsecond. DELETE returns JSON true at 200; a repeat returns 404. Preserve conditional revision predicates on mutation statements as a further invariant. Missing or malformed revision is a 400, never an unconditional write. Generic backend failure returns retryable 503 `analysis_store_unavailable` without payload contents.

Add a resource-specific `AnalysisResult a` and response list supporting 200/400/404/409/503, with success JSON and problem JSON correctly admitted. Register codes in `kansoku-api/src/Kansoku/Api/Response.hs`; keep existing resource response alternatives unchanged.

Implement GET `/analyses` using the released Relay engine already integrated by the metric store, with `RelayPage 20 100`, optional closed kind, and `(updated_at DESC,id ASC)` ordering. Apply account and kind predicates before pagination and page-info calculation. Cursors encode the exact persisted timestamp precision and UUID; verify the timestamp key codec in dependency source through Mori before selecting it. If no timestamp codec exists, use an exact sortable UTC representation with explicit SQL projection and precision tests. Do not truncate to milliseconds. Invalid page arguments/cursors retain the existing Relay error shape; an invalid kind is a field-naming 400 problem. Follow native account scoping even when supplied a cursor from another account. A cursor never grants access to its originating row. Document that it must be reused with the same filter; no snapshot or filter-change continuity is promised.

Add `kansoku-core/test/Kansoku/Analysis/StoreSpec.hs` and `HandlerSpec.hs`, register them in `kansoku-core/test/Spec.hs` and the cabal file, and use private migrated databases. Test two independent connections racing PUT with one revision, concurrent creates at limit minus one, stale DELETE, failed validation leaving the row untouched, and account isolation on every route. Deterministic equal-timestamp fixtures and forward/backward walks must produce identical canonical ordering without duplicates when data is unchanged. Verify moving an old item to the first page and continuing from a cursor whose original row was deleted. Milestone acceptance requires these tests to pass with nonzero examples and no pending cases.

### Milestone 3: Deliver the public contract and executable proof


Expose `analysesClient :: Analyses (AsClientT ClientM)` from `kansoku-client/src/Kansoku/Client/Metrics.hs`. Add client HTTP tests to the existing client suite that invoke create/read/list/replace/delete and decode a real typed 409, alongside authentication failures. Update `kansoku-api/src/Kansoku/Api/OpenApi.hs`, `kansoku-core/test/Kansoku/OpenApiSpec.hs`, and regenerate `docs/api/openapi.json`. Schemas and operation descriptions must describe object documents, byte versus character limits, required mutation revisions, status codes, quota configuration, sort order, current-read cursors, and no execution or interpretation. Verify both served `/openapi.json` and generated artifact.

Extend `docs/guides/query-metrics.md` with complete create/list/reopen/replace/delete examples, cursor caveats and conflict recovery. Update its timestamp and `docs/guides/log.md` through the existing OKF workflow. Create a saved-analysis ADR using the local profile and allocated `ADR-N`, summarizing persistence, concurrency and opaque-document decisions; do not assign an ADR number by hand.

Add `scripts/analyses_acceptance.py` following `scripts/custom_metrics_acceptance.py` and the owned harness in `scripts/cohorts_acceptance.py`. Add `just analyses-acceptance`, with a build prerequisite. The script must create fresh stores, issue two account service tokens and a write key, run the matrix below, and clean only recorded resource IDs. Track the latest revision for cleanup; never delete untracked list results. Parameterize the owned server environment for a separate quota=2 run. Register the same verifier in `scripts/acceptance.py` so the actual Nix-packaged server is covered. Ensure no hard-coded global count assertions conflict with other resource scenarios. Missing prerequisites must fail required runs. Use Apple Container if local container execution is needed; never Colima.


## Concrete Steps


Run commands from the repository root. These are implementation instructions, not evidence already collected. Inspect current working changes before editing. Resolve any unfamiliar Hasql, Relay or migration API through Mori before use; this plan requires no library upgrades. If an upgrade becomes necessary, verify authoritative registry releases and upstream tags before choosing bounds.

```bash
cd /Users/shinzui/Keikaku/bokuno/kansoku-project/kansoku
git status --short
mori registry list
mori registry search relay-pagination
mori registry search hasql
mori registry search pg-migrate
```

Use the discovered qualified project names with `mori registry show <project> --full` and `mori registry docs <project>`, then read the returned source paths. Do not substitute guessed API signatures when the registry is down.

After registering the new tests, build and run focused validation. `just build-with-tests` also prepares the repository's embedded migration inputs.

```bash
nix develop --no-write-lock-file -c just build-with-tests
nix develop --no-write-lock-file -c cabal test kansoku-core:kansoku-core-test --test-show-details=direct --test-options='--match Kansoku.Analysis'
nix develop --no-write-lock-file -c cabal test kansoku-core:kansoku-core-test --test-show-details=direct --test-options='--match Kansoku.Migrations'
nix develop --no-write-lock-file -c just analyses-acceptance
```

The new test descriptions must start with `Kansoku.Analysis`. Expect nonzero passing examples and zero pending cases, a repeat migration result of AlreadyApplied, and an acceptance summary covering roundtrip, concurrency, quota and pagination. Reuse the private PostgreSQL harness rather than ambient credentials. Final validation, after documenting the API:

```bash
nix develop --no-write-lock-file -c just openapi
nix develop --no-write-lock-file -c just check
nix develop --no-write-lock-file -c just acceptance
git diff --check
```

`just check` includes schema drift, OpenAPI lint, client tests and strict documentation checks. `just acceptance` supplies the packaged-server boundary; the focused script alone does not prove packaging. Record failures and actual platform coverage honestly, and rerun affected gates after corrections.


## Validation and Acceptance


AC-1: With service tokens A and B, create an analysis as A; read/list/replace/delete succeed for A. B cannot see it in lists and receives 404 for GET/PUT/DELETE of its ID, just as for an unknown UUID. B can create its own analysis. A write key gets 403 for every resource operation; missing credentials get 401. Check problem media and account privacy, not only status codes.

AC-2: Test trimmed names at 1 and 120 characters, rejection at 0 and 121, descriptions at 500 and 501, all three kinds and an unknown kind. Reject missing, zero, negative and fractional documentVersion, and array/string/null documents. Compact UTF-8 encodings exactly 32,768 bytes pass; 32,769 fail with document named in a 400. Include multibyte Unicode so byte and character bounds cannot be confused. Nested arrays, objects, escaped zero characters, numbers, booleans and null inside the object return equal JSON values. No metric registry lookup or analytics query executes during save. Invalid PUT preserves the previous document, revision and timestamps.

AC-3: Two readers observe revision 1. The first PUT returns revision 2 and a later updatedAt; the second PUT and DELETE with revision 1 return 409 without changes. A fresh revision can delete. Simultaneous updates through different database connections admit exactly one winner. Validate missing revision errors and identical-content updates as well. A row that disappears before a later write returns 404.

AC-4: Create mixed kinds with controlled equal timestamps. Walk forward and backward at page size 1, verify canonical `(updatedAt descending,id ascending)` order and pageInfo at boundaries; repeat with kind=funnel. Update an older row and verify it heads a fresh first page. Continue an old cursor after deleting its source row without offset shifts or invalid row lookup. Invalid cursors and page sizes fail consistently with metric definitions. Make no claim of snapshot consistency during concurrent edits.

AC-5: With limit 2, two creates succeed and the third returns 409. In two concurrent creates starting from count 1, exactly one succeeds; count remains 2. Another account retains its separate allowance. Deleting frees a slot and failed creates leave no row. Verify the default 1000 and invalid environment configuration through config tests. Client roundtrips, served and checked-in OpenAPI, and guide examples must match the final wire contract.


## Idempotence and Recovery


Append migrations without changing applied SQL checksums. Apply and verify them twice on a private database. Roll back the application to a version that ignores the additive table if necessary; do not drop saved analyses as routine recovery. Transactions roll back all count checks, mutations and revision changes on failure, and release locks on connection cleanup. A lost HTTP response after commit is ambiguous: GET the ID after a PUT before retrying with a revision; after a DELETE, 404 confirms absence. POST is not idempotent and may create duplicates if blindly retried after a lost response; no idempotency-key mechanism is included.

Each acceptance run owns its databases and processes and can be repeated. Preserve private evidence and report only sanitized summaries. Do not reset shared stores or disturb existing user changes. During implementation, commits use Conventional Commits and both `ExecPlan: docs/plans/69-save-named-analyses-for-an-account.md` and `Intention: intention_01m796f2tse68rv4yraze7kkse` trailers.


## Interfaces and Dependencies


The public surface is POST/GET `/analyses` and GET/PUT/DELETE `/analyses/{id}`. GET collection accepts the existing Relay page parameters and optional kind; PUT requires revision in its full body; DELETE requires `?revision=<positive integer>`. Each route uses `MetricsAuth` and derives account exclusively from `MetricsPrincipal`. `AnalysisResult` distinguishes successful values and field validation, missing, conflict and unavailable problems; list results preserve the Relay pagination contract. Keep OpenAPI and generated-client media alternatives aligned with these types.

`Kansoku.Analysis.Validation` returns a validated envelope plus its exact encoded document bytes. `Kansoku.Analysis.Store` accepts an explicit AccountId for every operation, a configured limit for create, and an expected revision for replace/delete. It returns distinct domain outcomes rather than forcing handlers to guess conflict versus missing from a zero-row mutation. `Kansoku.Analysis.Handler` maps these to the public wire types. Database connection cleanup, locking and cancellation are store responsibilities.

Reuse existing Aeson, UUID, time, Hasql, PostgreSQL and Relay dependencies. No ClickHouse document storage, new service, background worker, schema interpretation, or consumer-specific dependency is introduced. The request file is the complete upstream acceptance source; no external consumer repository is needed to implement or validate this plan.

Revision note (2026-11-13): Corrected Mori availability after successful discovery with refreshed shell environment; the implementation scope is unchanged.
