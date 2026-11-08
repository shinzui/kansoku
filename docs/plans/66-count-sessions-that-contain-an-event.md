---
id: 66
slug: count-sessions-that-contain-an-event
title: "Count sessions that contain an event"
kind: exec-plan
created_at: 2026-11-08T04:40:34Z
intention: "intention_01m6wq8v97e43aferbp9tka9tq"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-11-08T04:40:34Z
---

# Count sessions that contain an event


This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current during implementation. Follow `agents/skills/exec-plan/FRICTION.md` for implementation friction and distill durable decisions into `docs/adr/` before completion.

## Purpose / Big Picture


Let a dashboard report how many visits contained an error, or any other named event. Add optional `containsEvent=client_error` to `/metrics/sessions`; a comma-separated list selects sessions containing at least one of those names. Three retained web sessions, one containing an error, must return count 1 with the option and count 3 without it. Consumers can divide those two counts to show the share of affected visits.

This implements all four acceptance criteria in [IR-14](docs/improvement-requests/count-sessions-that-contain-an-event.md). Matching selects complete sessions; it does not turn session duration, bounce, attribution, or grouping into calculations over only the matching events. Event-property selection, a new percentage measure, and changes to other metric routes are outside this plan.

## Progress


- [ ] Milestone 1: Core queries select whole sessions by a bounded any-of event-name list; native tests prove count, bounce, duration, retained-history matching, and isolation.
- [ ] Milestone 2: The authenticated HTTP route and typed client expose the selection, reject invalid input before storage, and preserve existing requests and response shapes.
- [ ] Milestone 3: A packaged public ingestion/query fixture proves IR-14, and generated OpenAPI, query guidance, and durable ADR context describe the accepted behavior.

## Surprises & Discoveries


## Decision Log


2026-11-08: Use one optional `containsEvent` query parameter, accepting 1..20 comma-separated names with any-of semantics. This distinguishes contained events from the existing session `event_name` attribution dimension and avoids introducing a synthetic dimension with ambiguous grouping or negative-filter semantics. Bound the raw list before deduplication, following the established acquisition conversion-list convention.

2026-11-08: Select complete session keys through a membership subquery over `analytics.events_canonical`. Keep the existing materialized and identity-aware session projections. This needs no new aggregate state, migration, backfill, or modification of immutable migration history. Omitted selection must not introduce the extra event scan.

2026-11-08: Preserve current engagement classification. [Plan 65](docs/plans/65-stop-counting-client-errors-and-web-vitals-as-session-engagement.md) owns excluding diagnostics from engagement and correcting retained state. The selection is independent of that correction; acceptance uses a two-page error session so its bounce expectation is stable before and after Plan 65.

## Outcomes & Retrospective


## Context and Orientation


A session here is all retained web events sharing `(account_id, source_service, session_id)` with a nonempty session ID. Retained means still represented in canonical event history after the repository's retention and erasure procedures. There is no server-side inactivity splitting. The session starts at its earliest retained event, ends at its latest, takes attribution from its first page view (or earliest event if it has no page views), and has the maximum bot flag of its events. A bucket is the UTC time group selected by `timeGrain`; `none` produces a single null bucket over the range. The request date range includes `from` and excludes `to`, applied to session start.

`kansoku-api/src/Kansoku/Metrics/Api.hs` declares `SessionQuery`, `MetricsRoutes.sessions`, and `SessionMeasure`. Its current arguments are shared dates, grouping, grain and filters followed by measure and includeBots. `kansoku-core/src/Kansoku/Metrics/RequestValidation.hs` explicitly allows query parameters per route and rejects unknown or repeated scalar parameters. Adding a route argument alone is insufficient.

`kansoku-core/src/Kansoku/Metrics/Handler.hs` assembles a `QueryRequest`, loads cohort membership through `withCohorts`, and calls `runSessionMetric`. `kansoku-core/src/Kansoku/Metrics/Query.hs` owns that request, `compileSessions`, the execution boundary, native parameter helpers `eventNamePredicate` and `namedParameters`, and compile-error-to-problem mappings. `compileSessions` already selects complete sessions before aggregation and fills empty ungrouped calendars with zeros. It rejects arbitrary `prop:` selection.

`kansoku-core/src/Kansoku/Metrics/Query/Session.hs` owns `materializedSessionProjection`, which finalizes stored states in `analytics.sessions`, and `sessionProjection`, which derives equivalent whole sessions from canonical events. Queries needing current traits or cohorts use the identity-aware canonical path through `hasUserTraits`, `rawResolvedSource`, and `retainedScope`. Both paths must receive the same new key-membership predicate after assembly. Do not filter their input events by the requested name. The existing `event_name` column in their output describes the attribution event, not every event in a session.

`kansoku-api/src/Kansoku/Metrics/Limits.hs` holds public input bounds. `kansoku-core/src/Kansoku/Metrics/Query/Validate.hs` holds `SqlName`, `mkSqlName`, `QueryLimitError`, and the analogous `validateAcquisitionConversions`. Its grammar is 1..128 lowercase ASCII letters, digits, underscore, dot, colon, or hyphen. Reuse that grammar and native string parameters; do not check whether a name is currently declared in the ingest registry. A valid name without retained matches produces an empty selection.

The relevant ADRs were discovered by scanning `docs/adr/` filenames and headings. [ADR-13](docs/adr/0013-whole-retained-replay-safe-web-sessions.md) requires whole retained assembly, replay-safe state, start-date selection, any-bot exclusion, and direct calculation of all three measures. [ADR-12](docs/adr/0012-server-enrichment-and-first-touch-web-acquisition.md) fixes first-touch attribution and accepted enrichment. [ADR-3](docs/adr/0003-api-key-authentication-and-account-scoped-analytics.md) requires account scope from the authenticated principal and native query binding. [ADR-9](docs/adr/0009-bounded-complete-aggregate-responses.md) requires bounded input, complete results up to 10,000 points, resource limits, and errors before connection acquisition. [ADR-10](docs/adr/0010-owned-executable-acceptance-environments.md) requires owned disposable acceptance stores and treats skipped native proofs as failure. [ADR-18](docs/adr/0018-stable-reader-sql-and-real-consumer-conformance.md) keeps direct SQL reader contracts distinct; this plan adds an HTTP option without changing those views.

Native coverage lives in `kansoku-core/test/Kansoku/Metrics/SessionIntegrationSpec.hs`, alongside acquisition and trait tests. `scripts/acquisition-acceptance.py` runs all three families against private ClickHouse stores at ordinary and tiny block sizes. `scripts/acceptance.py` runs the packaged server with owned PostgreSQL and ClickHouse, issued credentials, and repeated telemetry-mode workflows. `scripts/enrichment_acceptance.py` demonstrates public ingestion, eventual query assertions and unique fixture populations. `kansoku-client/src/Kansoku/Client/Metrics.hs` derives `metricsClient` from the route record; `kansoku-client/test/Spec.hs` tests serialization. `kansoku-core/test/Kansoku/OpenApiSpec.hs` verifies the generated contract. `docs/api/openapi.json` is generated from route types, never edited by hand.

This is a standalone plan. IR-8, represented locally by [Plan 57](docs/plans/57-declare-client-error-and-web-vital-events.md), supplies the motivating diagnostic schema but is not a dependency of generic name selection. The requesting consumer is `mori://shinzui/kansoku-ui/masterplans/4-build-the-health-tab-of-the-reports-page`; implementing that UI is outside scope. At authoring, the working tree already contains changes to session integration tests, replicated runtime fixtures, and friction records. Preserve that work and reconcile overlapping test edits before implementation.

## Plan of Work


### Milestone 1: Select whole sessions in the core query path


Add `maxSessionContainsEvents = 20` to `kansoku-api/src/Kansoku/Metrics/Limits.hs`. In `kansoku-core/src/Kansoku/Metrics/Query/Validate.hs`, add `validateSessionContainsEvents :: Maybe [Text] -> Either QueryLimitError [SqlName]`. `Nothing` means no selection. A supplied list must contain 1..20 raw entries; trim each entry, validate with `mkSqlName`, then deduplicate. Empty lists or entries, invalid characters, and overlong names fail with `invalid_contains_event`. Twenty-one copies of one valid name must fail before deduplication. Do not change the acquisition validator's public behavior.

Keep `QueryRequest` unchanged, avoiding a global option that other metrics could silently ignore. Add `buildSessionMetricSQLWithContains` and `runSessionMetricWithContains`, each taking `Maybe [Text]` after the measure. Preserve the old public functions as wrappers passing `Nothing`, including `runSessions` and `buildSessionsSQL`. Introduce an internal `compileSessionsWithContains` and keep `compileSessions` as its no-selection wrapper for built-in dispatch. Add `QueryCompileContainsEvent QueryLimitError` and its mappings in `queryCompileErrorCode` and `queryCompileErrorMessage` so builders, runners and HTTP agree on error identity. Validate before any connection checkout.

For a nonempty validated selection, add a tuple-membership predicate to the outer selected-session query. Membership means keep the session once if its complete key appears in the subquery, regardless of the number of matching events. The following SQL shape illustrates the intended boundary; the actual compiler composes it with existing session predicates and native placeholders:

```sql
(account_id, source_service, session_id) IN (
  SELECT account_id, source_service, session_id
  FROM analytics.events_canonical
  WHERE account_id = {account_id:String}
    AND source = 'web'
    AND session_id != ''
    AND event_name IN ({session_contains_event_1:String})
)
```

Use `eventNamePredicate "session_contains_event" names` for the names and append `namedParameters "session_contains_event" names` to `CompiledMetric.filterParameters`. Do not interpolate user text. Do not use an ordinary many-row join, which could multiply the session contribution. Membership has no event date, attribute, identity, or per-event bot filter: all retained web events are eligible witnesses. The assembled session continues to own date selection, attribution filters, current traits/cohorts, and any-bot exclusion. Repeated event IDs, multiple matching events, and names matching the same session must never multiply counts or weight averages.

Exercise the native builder/driver path early with one last-event match and an unchanged session duration. Then extend `kansoku-core/test/Kansoku/Metrics/SessionIntegrationSpec.hs` with the full behavior cases below and the existing trait fixture in `kansoku-core/test/Kansoku/Metrics/TraitsSpec.hs` to force the canonical identity-aware path. Keep the existing replay, point-cap and projection-equality coverage. Add validator cases in `kansoku-core/test/Kansoku/Query/ValidateSpec.hs` and compiler cases in `kansoku-core/test/Kansoku/QuerySpec.hs`, including absent selection retaining the old query shape. Verify native result equality across ordinary and tiny blocks using `scripts/acquisition-acceptance.py`. Acceptance is correct values, not merely SQL substring assertions.

### Milestone 2: Expose a validated HTTP and typed-client option


In `kansoku-api/src/Kansoku/Metrics/Api.hs`, insert `QueryParam "containsEvent" Text` between the session measure and includeBots arguments. In `kansoku-core/src/Kansoku/Metrics/Handler.hs`, accept the corresponding `Maybe Text`, split on commas without dropping empty entries, and invoke the shared validator before `withCohorts`. Call `runSessionMetricWithContains` with the supplied list and the unchanged request. Permit `containsEvent` only for sessions in `kansoku-core/src/Kansoku/Metrics/RequestValidation.hs`; keep it a nonrepeatable scalar. Other routes must continue rejecting it.

Add deterministic HTTP cases in `kansoku-core/test/Kansoku/Metrics/HandlerSpec.hs` and request-perimeter cases in `kansoku-core/test/Kansoku/Metrics/RoutingSpec.hs`. Follow the acquisition sentinel-pool tests: invalid selection combined with `filter=cohort:eq:missing` must produce HTTP 400 `invalid_contains_event` without attempting cohort loading or query checkout. A repeated parameter or bare parameter uses the existing `invalid_query_parameter` code. Preserve authentication precedence and `application/problem+json` responses.

The derived `Metrics.sessions metricsClient` acquires a `Maybe Text` argument; callers compiling from source must supply `Nothing` to retain old behavior. Find all local calls and update them. Add a transport-capture test in `kansoku-client/test/Spec.hs` proving `Nothing` omits the option and `Just "client_error,page_leave"` sends one correctly encoded parameter with the existing service credential and filters. Add `kansoku-core/test/Kansoku/OpenApiSpec.hs` assertions that the session operation exposes the optional string and its bounds/semantics while unrelated routes do not expose it. Regenerate OpenAPI for these tests. Acceptance is passing deterministic handler, route, client and contract tests, with unchanged results for omitted selection in the native suite.

### Milestone 3: Prove the public report and publish the contract


Create `scripts/session_contains_acceptance.py` with `verify_session_contains(base, write_key, service_token, other_token)` using public `/v1/batch` ingestion and authenticated `/metrics/sessions` queries. Import and call it from `scripts/acceptance.py` alongside the existing enrichment workflow in each telemetry mode. Reuse the existing owned process lifecycle and credentials. Use fresh event IDs and a fresh source-service population per invocation, and filter reports to that population so data from previous workflows cannot alter counts. Send batches within the existing acceptance body cap, assert ingestion acknowledgements, and poll for expected projections with a finite deadline.

Publish the three-session fixture and comparison requests described below. Use `client_error` schema version 1 with required properties such as `{"message":"fixture failure","type":"TypeError","handled":false}`, as declared in `kansoku-api/src/Kansoku/Event/Registry.hs`. Supply the declared required properties for page views and page leaves as well; do not bypass ingestion validation. Add native-only stored-row cases for non-web events with reused keys if the public event schema cannot represent those rows. The public fixture must prove the server-side no-session error does not count, the last-event match does count, and all three measures are computed on the selected whole sessions. Read the live OpenAPI response as well as the generated artifact to confirm the new option is served.

Update `docs/guides/query-metrics.md` in the route matrix and sessions section with the exact option, any-of behavior, name grammar, raw-list limit, error codes, retained-history/start-date rule, interaction with every session measure, and the two-request percentage example. Explain that separate requests are not an atomic snapshot and late arrivals can change results; a zero denominator means no observed sessions, so the example displays no percentage. Keep the guide's existing metadata and refresh its timestamp/log as required by `docs/guides/profile.dhall`.

At implementation completion, amend ADR-13 to distinguish contained-name selection of whole sessions from forbidden arbitrary event-property filtering, and ADR-9 to record the new public bound. Preserve their stable IDs and update the bundle log through `okf log add`. Run strict profile validation. Regenerate `docs/api/openapi.json` from the route description. Run the packaged acceptance gate and retain concise sanitized evidence in this plan. Do not mark IR-14 delivered based only on compilation or native SQL tests.

## Concrete Steps


Run all commands from the repository root (the directory containing `cabal.project` and `flake.nix`). First inspect `git status --short`, preserve pre-existing edits, and implement the milestones above. The existing Nix development environment supplies the build tools; do not search or read `/nix/store` or traverse the filesystem root.

After core and API changes, build with the repository's migration-embedding wrapper, then run deterministic and owned-native checks:

```bash
nix develop --no-write-lock-file -c just build-with-tests
nix develop --no-write-lock-file -c just openapi
nix develop --no-write-lock-file -c just deterministic-test
nix develop --no-write-lock-file -c python3 scripts/acquisition-acceptance.py
```

The build must succeed, deterministic families must have zero failures and pending cases, and each native family must execute positive test counts with zero failures/pending at both block sizes. The native command creates its own stores; an absent native prerequisite is a failure, not successful skipped coverage. Run the first focused native proof during Milestone 1, before expanding the fixture matrix. Repeat checks after relevant changes, not merely because another milestone began.

After the documentation and public fixture are complete, run:

```bash
nix develop --no-write-lock-file -c just openapi-check
nix develop --no-write-lock-file -c just openapi-lint
nix develop --no-write-lock-file -c just guides-check
nix develop --no-write-lock-file -c okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
nix develop --no-write-lock-file -c just format-check
nix develop --no-write-lock-file -c just acceptance
git diff --check
```

Use `okf log add --help` for the installed log-update interface before updating ADR/guide bundle logs. Formatting validation must not rewrite unrelated work. The packaged acceptance command must execute the new public fixture in all existing telemetry modes and retain its normal sanitized evidence. Record the actual commands, fixture counts, and final results when implemented; this plan's creation does not claim those checks have already run.

For a manual comparison against an already running test instance containing the fixture, set `BASE_URL` and `SERVICE_TOKEN` to its URL and issued metrics service token. `FIXTURE_SERVICE` is the fresh source service used for the three-session population. Execute:

```bash
curl --fail-with-body --get "$BASE_URL/metrics/sessions" \
  -H "Authorization: Bearer $SERVICE_TOKEN" \
  --data-urlencode 'from=2026-07-01' --data-urlencode 'to=2026-07-02' \
  --data-urlencode 'measure=count' --data-urlencode 'timeGrain=none' \
  --data-urlencode "filter=source_service:eq:$FIXTURE_SERVICE"
curl --fail-with-body --get "$BASE_URL/metrics/sessions" \
  -H "Authorization: Bearer $SERVICE_TOKEN" \
  --data-urlencode 'from=2026-07-01' --data-urlencode 'to=2026-07-02' \
  --data-urlencode 'measure=count' --data-urlencode 'timeGrain=none' \
  --data-urlencode "filter=source_service:eq:$FIXTURE_SERVICE" \
  --data-urlencode 'containsEvent=client_error'
```

Expected successful results retain metric `sessions`, one point with `bucket: null` and `group: {}`, and values 3 then 1. The consumer computes `100 * 1 / 3`, approximately 33.33%, for that fixture.

## Validation and Acceptance


The baseline fixture has three nonbot sessions in one account/source service on 2026-07-01. Session A has page views at 12:00:00 and 12:00:20 and a final `client_error` at 12:01:00, entry `/error`, first-page channel `email`, duration 60 seconds and no bounce because it has two page views. Give its last error a different route/channel to demonstrate that attribution stays with its first page. Session B has one page at 13:00:00 and `page_leave` at 13:00:30, entry `/quiet`, channel `email`, duration 30 seconds and bounce true. Session C has one page at 14:00:00, entry `/quiet`, channel `direct`, duration zero and bounce true. Add a server-side `client_error` without a session ID and a web error without a session ID; neither creates a session or a match.

For IR-14 AC-1 and AC-3, omitted selection returns count 3 and `containsEvent=client_error` returns count 1 even though the error is last. Repeated matching errors, replayed events, and duplicate list names still count A once. `containsEvent=client_error,page_leave` returns 2, proving any-of rather than all-of semantics. A valid absent name returns zero in ungrouped buckets and no grouped points.

For AC-2, selected A has average duration 60 and bounce rate 0. Selecting A and B returns average duration 45 and bounce rate 0.5; omitting selection returns average duration 30 and bounce rate 2/3. Grouping the A+B selection by `entry_page` returns `/error: 1` and `/quiet: 1`; filtering `channel=email` returns 2, and `channel=direct` returns zero. Grouping the error-only selection returns `/error: 1`; `groupBy=entry_page,channel` retains both keys. Use tolerance for nonintegral floating-point comparisons. All measures must use selected sessions as their denominator/population.

Native tests additionally cover hour/day/week/month/none grains and omission defaults, all three measures, zero-page sessions, empty populations, bot-only matching events, and current user-trait/cohort selection. An any-bot session is excluded by default even if only a clean event matches, and `includeBots=true` restores it. A non-web matching event with the same textual session ID and source service as a web session does not select that session. A matching event in another account or another source service cannot select an otherwise nonmatching key; test both collisions explicitly.

Add a separate cross-midnight case: a page at 2026-07-01 23:59 and an error at 2026-07-02 00:01 select the session in `[2026-07-01,2026-07-02)` with duration 120, despite the error lying outside that interval. Querying only the next day does not count the earlier-starting session. Inserting a late earlier event moves the selected session to its new start bucket. Replay in separate blocks preserves all results. Retain existing canonical/materialized equality checks and verify selection through a current trait/cohort request to cover the identity-aware branch. No new event-retention algorithm is introduced.

Validation must accept 20 valid raw names, trim surrounding whitespace, deduplicate valid entries, and reject 21 entries even if identical. Reject explicit empty text, comma-only text, leading/trailing/doubled commas, blank entries, 129-character names, uppercase, disallowed Unicode and SQL punctuation. Validate 128-character names as allowed. Unknown but syntactically valid names must not become registry errors. Repeated `containsEvent` parameters and a parameter without `=` retain existing scalar-query errors, and use on another metrics route retains the unsupported-parameter error. Existing `prop:` session filters/grouping remain rejected. Verify malformed input with unavailable/sentinel storage to prove fail-before-storage behavior.

For AC-4, both checked-in and live generated OpenAPI describe the optional parameter, limit, grammar, any-of rule and whole-session meaning, and the guide contains the two-request percentage example. Existing account, resource, date and complete-point bounds remain active; no scan truncation or partial results are introduced to make the new query pass. The native fixture, derived Haskell client transport test and packaged HTTP fixture together prove the producer-to-reporting path.

## Idempotence and Recovery


The change is additive query/API work with no migration or persisted event-name aggregate. Old HTTP requests omit the option and retain their answers. Reverting the query/API code does not require a data rollback; clients using the new option then receive the existing unsupported-parameter error. The new typed route argument is a source-level client change and must be reflected in local callers and release notes.

Tests must use owned temporary stores and fresh source-service/event identifiers. Never clear or migrate ambient databases to run them. Preserve failed fixture evidence and retry with a fresh owned fixture. Keep replay assertions separate from fixture isolation: replay the same immutable events deliberately inside a case, while giving each new fixture run unique identities. Public two-request ratios are observations over mutable retained history, not an atomic snapshot guarantee.

When implementing, record one provenance revision using `agents/skills/exec-plan/record-provenance.ts` with verified current runtime metadata. Record and triage material tool/process friction with the bundled scripts. Commit only relevant changes on the current branch using Conventional Commits, with trailers `ExecPlan: docs/plans/66-count-sessions-that-contain-an-event.md` and `Intention: intention_01m6wq8v97e43aferbp9tka9tq`.

## Interfaces and Dependencies


The public HTTP addition is optional scalar `containsEvent: string`, comma-separated, only on `/metrics/sessions`. Its Haskell route argument is `Maybe Text`. It applies to count, bounce_rate and average_duration_seconds; `MetricResult`, group keys and bucket representation stay unchanged. Selection is AND-combined with the existing session predicate expression; names within the selection are OR-combined. It has no negative, property, all-of or grouping form.

The intended new core interfaces in `kansoku-core/src/Kansoku/Metrics/Query.hs` are:

```haskell
buildSessionMetricSQLWithContains
  :: SessionMeasure -> Maybe [Text] -> QueryRequest
  -> Either QueryCompileError Text

runSessionMetricWithContains
  :: (IOE :> es)
  => QueryPool -> SessionMeasure -> Maybe [Text] -> QueryRequest
  -> Eff es (Either QueryExecutionError MetricResult)
```

Retain `sessionProjection :: Text -> Bool -> Text` and `materializedSessionProjection :: Text` in `kansoku-core/src/Kansoku/Metrics/Query/Session.hs`, and retain old core session entry points as omission wrappers. `CompiledMetric.filterParameters` carries the new bound names beside existing attribute parameters under a distinct prefix. QueryPool continues to enforce native memory/execution limits and the total request deadline.

Use the repository's current locked dependencies. Mori discovery and source inspection confirmed the optional `QueryParam` and derived client behavior in `mori://haskell-servant/servant/packages/servant` and `mori://haskell-servant/servant/packages/servant-client-core`. No dependency bound, pin, or compatibility workaround is selected by this plan. If implementation requires one, inspect its source through Mori and verify the current release against the authoritative registry and upstream tags before choosing it. No cross-repository edits or UI release are required for this backend plan.
