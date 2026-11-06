---
id: 60
slug: count-unique-users-over-a-whole-query-range
title: "Count unique users over a whole query range"
kind: exec-plan
created_at: 2026-11-06T04:03:23Z
intention: "intention_01m6qgaprfex19r8kdzhd7eaxs"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-11-06T04:03:23Z
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-06T05:04:10Z
      mode: "implement"
      note: "Implement explicit whole-range grain and route policy with regression coverage"
---

# Count unique users over a whole query range


This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current during implementation. Record implementation friction through `agents/skills/exec-plan/record-friction.ts` following `agents/skills/exec-plan/FRICTION.md`, and promote durable decisions into the existing ADRs at completion.

## Purpose / Big Picture


Implement [IR-4](../improvement-requests/count-unique-users-over-a-whole-range.md): callers can request `timeGrain=none` and receive exact distinct visitors for the entire requested period, with one `bucket: null` point per populated group. A person active on twelve days counts once within a group, rather than twelve times as they would when adding daily counts. Omitting the parameter retains each route's current defaults.

The required routes are `/metrics/users` with `window=calendar`, `/metrics/custom` with simple count, unique_count, sum or average aggregation, and `/metrics/acquisition` with `measure=users`. Include the request's optional additive routes `/metrics/events`, `/metrics/page-views` and `/metrics/sessions`; acquisition's sessions measure and all existing session measures use the same whole-range selection. Session rates and averages must be calculated from selected sessions, never by adding or averaging daily results. Existing filters, current traits, saved cohorts, account isolation, bot rules and resource limits continue to apply.

## Progress


- [x] (2026-11-06) Milestone 1: Exact whole-range users, simple custom metrics and acquisition return null-bucket results; saved overrides, omitted/null definitions and unsupported combinations pass deterministic tests and `nix develop -c just custom-metrics-acceptance` (4 native examples, no failures, plus all public assertions).
- [x] (2026-11-06) Milestone 2: Events, page views and all session measures support none. Owned packaged acceptance passes 592 core examples with no failures or pending cases, the independent thirty-day public identity sets, native replay/bot/trait/limit cases, empty-result checks and shared-store fixture cleanup.
- [x] (2026-11-06) Milestone 3: Generated OpenAPI, guides, capabilities and ADRs document the route matrix and unchanged defaults. `just check`, `just custom-metrics-acceptance` and `just acceptance` pass; all three telemetry modes and seven required administrative families execute successfully.

Completed on 2026-11-06. All three milestones are verified. This plan has no parent MasterPlan or prerequisite implementation in another repository.

## Surprises & Discoveries

The existing acquisition native fixture has one resolved subject active on both selected days. Its daily users sum is 11 (12 including bots), while whole-range exact users are 10 (11 including bots). The first native run correctly exposed the old daily expectation copied into the new grain case; the assertion now distinguishes the ten-subject set from daily sums.

## Decision Log


On 2026-11-05, choose the public spelling `timeGrain=none`, represented by an explicit `NoTimeBucket` constructor. Keep absence as `Nothing`. Absence already means different defaults on different routes and cannot also mean an explicit override of a saved daily grain.

On 2026-11-05, include the additive routes suggested by IR-4 and both acquisition measures. All session measures share selection and calendar generation, so calculate each directly over the selected sessions at the new grain. Limit acceptance of the new value to these six public routes and calendar users; other routes retain their existing supported grains. This makes the public surface deliberate despite the shared `TimeGrain` type.

On 2026-11-05, preserve existing populations and sparse-result conventions. Entry/exit page dimensions remain session/acquisition dimensions. Custom metrics do not gain an `includeBots` parameter; they retain their existing event population, including bot rows unless filtered explicitly. Whole-range mode changes temporal grouping only. This avoids conflating IR-4 with the separate request to expose session attributes on event metrics.

On 2026-11-06, return `Either QueryCompileError Text` from the three exported experiment SQL builders so direct callers can reject explicit none before producing SQL. Runtime experiment guards reject it before acquiring storage. Existing supported formatter tests unwrap successful results; public route and client wire types remain unchanged.

## Outcomes & Retrospective

Completed on 2026-11-06. Callers can select explicit whole-range aggregation on all six supported routes, override saved simple grains in both directions, and receive exact null-bucket results without combining daily distinct counts, rates or averages. Omitted parameters preserve route defaults. Unsupported modes fail before storage execution. The Haskell client serializes none and the generated schema and all fourteen query enums publish the five exact wire values.

Final verification passed `nix develop -c just check` (475 deterministic core examples, 21 client examples, production probes, all telemetry semantic modes, generated contracts, OpenAPI lint and documentation profiles), `nix develop -c just custom-metrics-acceptance` (4 native filter examples and all public assertions), and `nix develop -c just acceptance` (592 core examples, live client examples, 17 migration cases, recovery/resource/replay/identity checks, Hurl, three telemetry modes and seven required administrative families, with no required skips). The final packaged run also exercised the thirty-day fixture repeatedly under its 4096-byte ingest-body limit; small replay batches preserve that stricter environment. `nix fmt`, strict ADR validation and `git diff --check` pass.

The existing native fixture's returning subject demonstrated the essential distinction: eleven daily user counts represent ten whole-range subjects. Independent expected identity sets and unequal daily session counts catch both distinct-count summation and daily-average mistakes. Durable temporal grouping, observation and zero-fill decisions are recorded in [ADR-20](../adr/0020-custom-metric-definitions-and-bounded-or-filters.md), [ADR-14](../adr/0014-closed-day-exact-activity-and-retained-history-cohorts.md) and [ADR-13](../adr/0013-whole-retained-replay-safe-web-sessions.md). The distillation review found no additional project-level decision requiring a new ADR.

FRIC-3 in `docs/friction-log/` is accepted: preserve historical log prose around entries produced by the current OKF log writer. FRIC-4 in `docs/friction-log/` is resolved: the owned acceptance command helper returns captured stdout so its database ownership check succeeds. No implementation work remains within this plan's scope.


## Context and Orientation


A time bucket is an output interval such as a day; a group is the set of events or sessions sharing the requested dimension values. A resolved subject is the existing identity projection's canonical person, which may be a known user or an anonymous subject. Exact counting means counting distinct resolved subjects with the existing exact SQL aggregates, without sketches or summing per-day distinct counts. All ranges are half-open UTC intervals: `from` is included and `to` excluded.

`kansoku-api/src/Kansoku/Metrics/Api.hs` owns `TimeGrain`, its JSON and URL conversions, `MetricPoint` and the typed routes. It currently has Hour, Day, Week and Month. `MetricPoint.bucket` already permits null. `kansoku-api/src/Kansoku/Api/OpenApi.hs` derives both schema and query-parameter enums with generic lowercasing; adding `NoTimeBucket` without changing those instances would publish the wrong spelling. `docs/api/openapi.json` is generated, not an independently edited contract. The Haskell client in `kansoku-client/src/Kansoku/Client/Metrics.hs` uses the shared routes and type.

`kansoku-core/src/Kansoku/Metrics/Query.hs` compiles and executes metrics. `effectiveGrain` currently selects requested grain, definition default, then Day. `simpleAggregateSQL` groups by bucket plus two nullable dimension sort keys. `uniqueUsersSQL` uses `uniqExact(canonical_user)`, with activity-only and bot exclusions on active users. `compileUsers CalendarWindow` reaches this path; `runObserved` also requires closed UTC days. `compileAcquisition` assembles complete retained sessions, selects their starts inside the range, and counts distinct nonempty `primary_subject` for its users measure. Its default group is channel, which must remain the default at `none` too.

`compileSessions` computes count, bounce rate and observed average duration from selected sessions. It uses `sessionCalendar` to supply zeroes for ungrouped empty intervals. A whole-range calendar must have a single empty-string bucket. The native result boundary `boundedSQL` casts bucket to String, and `defaultPoint` converts the empty string to `Nothing`; reuse that existing null-bucket convention instead of returning SQL NULL through a nonnullable native column.

`kansoku-core/src/Kansoku/Metrics/Custom.hs` validates definitions and merges saved defaults into requests in `customRequest`. `customBuiltin` deliberately resets the dispatch name to custom, so saved labels cannot select builtin population rules. Simple definitions in `kansoku-api/src/Kansoku/Metrics/Definition.hs` persist an optional `TimeGrain` in PostgreSQL JSON. Ratio components currently reject any grain, and custom ratio requests require omitted timeGrain. Preserve those rules. `kansoku-core/src/Kansoku/Metrics/Handler.hs` wires parameters into requests; `kansoku-core/src/Kansoku/Metrics/RequestValidation.hs` owns authenticated parameter allowlists. No new URL parameter is required.

`kansoku-core/src/Kansoku/Metrics/Query/Dimension.hs` resolves dimensions, including the session-only entry/exit page names. `kansoku-core/src/Kansoku/Metrics/Query/Session.hs` assembles session attributes. `kansoku-core/src/Kansoku/Metrics/Query/Traits.hs` applies current user traits; cohorts are selected through `kansoku-core/src/Kansoku/Cohort/Query.hs` and the handler's existing cohort loading. Preserve these selection paths and their identity lookup scopes.

Relevant consulted decisions are [ADR-4](../adr/0004-queryable-event-properties-and-identity-resolved-projection.md), which owns canonical event deduplication, resolved subjects and typed nullable dimensions; [ADR-9](../adr/0009-bounded-complete-aggregate-responses.md), which limits ranges to 366 days and returns at most 10,000 complete points or an error; [ADR-12](../adr/0012-server-enrichment-and-first-touch-web-acquisition.md) and [ADR-13](../adr/0013-whole-retained-replay-safe-web-sessions.md), which require complete retained session assembly before selection, first-touch attribution and any-bot session exclusion; [ADR-14](../adr/0014-closed-day-exact-activity-and-retained-history-cohorts.md), which requires closed days for users and daily grain for rolling activity; [ADR-16](../adr/0016-governed-current-user-traits-and-replay-safe-erasure.md), which applies current traits after identity/session attribution; [ADR-20](../adr/0020-custom-metric-definitions-and-bounded-or-filters.md), which defines saved overrides and shared custom validation; and [ADR-10](../adr/0010-owned-executable-acceptance-environments.md), which requires owned disposable integration stores and executed, non-skipping acceptance.

The existing deterministic tests live in `kansoku-core/test/Kansoku/QuerySpec.hs`, `kansoku-core/test/Kansoku/Metrics/CustomSpec.hs`, `kansoku-core/test/Kansoku/Metrics/HandlerSpec.hs`, `kansoku-core/test/Kansoku/Metrics/RoutingSpec.hs` and `kansoku-core/test/Kansoku/OpenApiSpec.hs`. Native suites include `kansoku-core/test/Kansoku/QueryIntegrationSpec.hs` and the AcquisitionIntegrationSpec, ActivityIntegrationSpec, SessionIntegrationSpec and TraitsSpec modules under `kansoku-core/test/Kansoku/Metrics/`. `scripts/custom_metrics_acceptance.py` already provides owned public custom queries and saved CRUD; `scripts/acceptance.py` runs native suites and packaged public scenarios. Preserve saved-resource cleanup through `scripts/acceptance_resources.py`.

## Plan of Work


### Milestone 1: Exact whole-range user queries and saved overrides


Add `NoTimeBucket` and encode/parse it as exactly `none` in JSON and URL instances. Explicitly map that wire value in both OpenAPI schema instances; preserve all four existing spellings. Add roundtrip and invalid-value tests. Do not normalize the new constructor to Nothing when parsing, merging saved defaults or selecting `effectiveGrain`: `Just NoTimeBucket` must win over a saved/default Day, and an explicit Day must override a saved NoTimeBucket.

In `kansoku-core/src/Kansoku/Metrics/Query.hs`, make `bucketExpr (Just NoTimeBucket)` return the SQL literal `''`. Keep `Nothing` behavior intact. Continue grouping on the existing constant bucket and typed dimension columns so every populated group has one point. Preserve exact aggregates, source selection, account/date predicates, filters and outer result bounds. This should serve calendar users, simple custom aggregations and acquisition without a second counting implementation. Keep acquisition's default channel grouping and complete retained identity scope.

Enforce the new route policy at execution/compiler boundaries, not just in documentation. Accept none for simple metrics dispatched as active_users, custom, events and page_views, plus session and acquisition compilers. Reject it for other simple builtin dispatches and generic ratios. Keep existing daily-only checks for rolling users, stickiness, lifecycle and retention, and existing no-grain rules for conversion, funnels, paths and custom ratios. Explicitly reject none in experiment execution, whose existing omission means whole range; audit its exhaustive grain matches so the new constructor cannot fall through to daily output. Unsupported combinations must return a permanent HTTP 400 before query execution, using the existing route-specific problem contract (a new unsupported-grain guard can use `invalid_time_grain`). Keep malformed/unknown wire values on the existing parser error path. Internal SQL-building entry points must reject unsupported modes too, rather than relying solely on handlers.

Test saved simple definitions with timeGrain omitted, null, day and none. Cover POST/GET/PUT/execution, an explicit none request overriding day, and day overriding a saved none. Old persisted definitions must continue to decode without migration. Ratio requests and ratio components must continue rejecting any explicit grain, including none. Preserve merged filter budgets, trait/cohort discovery and invalid loaded-definition validation.

Extend `scripts/custom_metrics_acceptance.py` with a small public proof before expanding fixtures: a single resolved user active on two days returns exactly one null-bucket point with value 1 for custom unique_count and calendar users. Use distinct session IDs on those days with the same channel and verify acquisition users yields one channel point with value 1. Compare the same requests without timeGrain to their two original daily points. The owned custom acceptance harness already supplies a server and both credentials; reuse it for all three routes. Deterministic checks plus `just custom-metrics-acceptance` must pass for this milestone.

### Milestone 2: Additive routes and preserved population semantics


Enable none for events and page views through the shared simple aggregation path. Extend `sessionCalendar` with one label, the empty string, when grain is NoTimeBucket. Reuse the existing grouped session aggregate and zero-fill join. Count, bounce_rate and average_duration_seconds must calculate from all selected sessions in the range. Use unequal daily session counts in fixtures so an average of daily rates or averages would fail. Keep grouped empty sessions absent and ungrouped empty sessions as one zero point for every measure. Simple event/user/custom and acquisition queries retain their sparse behavior: an empty matching population yields no points, including ungrouped queries; document this rather than changing unrelated no-data contracts.

Extend native fixtures in `kansoku-core/test/Kansoku/QueryIntegrationSpec.hs`, `kansoku-core/test/Kansoku/Metrics/AcquisitionIntegrationSpec.hs`, `kansoku-core/test/Kansoku/Metrics/ActivityIntegrationSpec.hs`, `kansoku-core/test/Kansoku/Metrics/SessionIntegrationSpec.hs` and `kansoku-core/test/Kansoku/Metrics/TraitsSpec.hs` where those families already own the relevant behavior. Avoid a new test family that the deterministic runner might accidentally execute against ambient services. Build a 30-day fixture spanning a calendar-month boundary, with repeated user activity, separate sessions, an anonymous subject subsequently resolved to a user, an empty identity, duplicate deliveries, bot rows and a foreign-account copy. Assert expected canonical subject sets independently of the production aggregate: a small Haskell Set or Python set keyed by expected group and resolved identity is sufficient. For sessions/acquisition derive expected primary subjects from the fixture's ordered complete sessions, not from the endpoint under test.

Exercise one and two dimensions across route, channel, country_code, device_class and current `user:plan`; cover entry_page on acquisition and sessions. Include nullable and empty dimension values, repeated filters including OR alternatives, cohort filters/grouping and both bot settings on the routes that expose includeBots. Preserve the distinction between row-level bot exclusion on users/page views and whole-session exclusion on acquisition/sessions. On custom, compare none with the same explicitly filtered event population and retain rejection of unsupported includeBots. Confirm a user can appear once in each of two groups: summing distinct group counts is not an overall unique total. Keep existing organization options on users working at the new grain without changing attribution rules.

Prove range boundaries, including activity exactly at from and to, and a session starting before from with events inside the range. The latter remains excluded from acquisition/sessions because selection uses the complete session's start. Replaying identical IDs before merges must leave values and groups unchanged. Check missing numeric properties stay excluded from sum/average and averages use all eligible samples, not daily averages. Retain errors for invalid ranges, unclosed users windows, unsupported dimensions and result overflow. Add a none case to the existing native limit fixture so loss of time buckets cannot bypass the 10,000-point cap.

Extend public proofs in `scripts/custom_metrics_acceptance.py`, `scripts/activity_acceptance.py` and `scripts/enrichment_acceptance.py` according to the fixtures they already own. Register new saved definitions and cohorts with `OwnedResources` and preserve strict list/pagination expectations. Milestone acceptance is the expected independent point map for every supported route and no change in the paired legacy requests, verified by the focused custom gate and owned packaged `just acceptance`.

### Milestone 3: Published contract and final verification


Update route descriptions in `kansoku-api/src/Kansoku/Metrics/Api.hs` and schema descriptions in `kansoku-api/src/Kansoku/Api/OpenApi.hs`, then regenerate `docs/api/openapi.json`. Test that JSON definition and query enums contain none, never notimebucket, and that supported and unsupported modes are documented. Existing wire point fields and route argument order stay unchanged; build the Haskell client and add a focused URL serialization check if the type-level conversion is not already exercised.

Update `docs/guides/query-metrics.md` with whole-range examples for users, custom unique_count and acquisition users, the six-route support matrix, unchanged omission defaults, saved override precedence, empty-result differences and calendar-only restriction for users. Explain that acquisition remains grouped by channel by default, per-group distinct counts can overlap, and summing daily distinct counts overcounts returning visitors. State the existing exclusive to boundary, closed-day users rule, bot policy and route-specific dimension scope. Explain that timeGrain null in a saved definition means no override, while the string none explicitly requests whole range.

Update relevant capability descriptions in `docs/capabilities/filtered-semantic-metrics.md`, `docs/capabilities/custom-metric-definitions.md` and `docs/capabilities/web-sessions-acquisition.md`. Distill the new temporal grouping contract into ADR-20 and update ADR-14's calendar-grain list and ADR-13's zero-fill wording. Preserve their stable handles and profiled metadata; inspect `mori show --full` and the local `docs/adr/profile.dhall` before edits, and maintain affected document/bundle logs with repository tooling. Run the final checks below, record concise evidence, triage implementation friction and fill the retrospective before completing the plan.

## Concrete Steps


Run all commands from the repository root, with Nix and the repository tools installed. The native harnesses launch their own PostgreSQL and ClickHouse processes and require local process/port access. Do not point destructive native suites at ambient databases. Start with the build and focused checks during milestone 1:

```bash
nix develop -c just build-with-tests
nix develop -c just deterministic-test
nix develop -c just custom-metrics-acceptance
```

Success means exit status zero, nonzero executed examples/assertions and no pending cases in required suites. Add regression assertions before the corresponding change when practical; the old implementation should reject none or fail the expected whole-range points. The focused custom target builds components and owns its services. The complete native suites run through the packaged harness during milestone 2.

After contract and documentation edits, run the final candidate checks:

```bash
nix develop -c just openapi
nix fmt
nix develop -c just check
nix develop -c just acceptance
git diff --check
```

`just check` verifies test builds, formatting, deterministic suites, generated contract drift, OpenAPI lint, documentation profiles, strict ADR validation and HTTP telemetry. `just acceptance` requires native tests and public scenarios against the packaged executable on fresh owned stores. Record concise outcomes rather than full private logs. If prerequisites fail, record the blocker; pending/skipped tests do not establish acceptance. Repeat only checks invalidated by subsequent changes.

Implementation commits use Conventional Commits with both trailers:

```text
ExecPlan: docs/plans/60-count-unique-users-over-a-whole-query-range.md
Intention: intention_01m6qgaprfex19r8kdzhd7eaxs
```

## Validation and Acceptance


IR-4 AC-1 passes when a 30-day query, for example from 2026-06-20 through exclusive 2026-07-20, counts one user active on several days once per selected group on users, custom unique_count and acquisition users, with every returned bucket null. For a fixture containing A on June 21 and July 2 and B on July 2, with both in the same channel, expect whole-range value 2; daily values are 1 and 2. Assert point cardinality and bucket fields, not just summed values. Public examples, using credentials from an owned running fixture, are:

```bash
curl --fail-with-body --get "$KANSOKU_BASE_URL/metrics/users"   -H "Authorization: Bearer $KANSOKU_METRICS_KEY"   --data-urlencode from=2026-06-20 --data-urlencode to=2026-07-20   --data-urlencode window=calendar --data-urlencode timeGrain=none
curl --fail-with-body --get "$KANSOKU_BASE_URL/metrics/custom"   -H "Authorization: Bearer $KANSOKU_METRICS_KEY"   --data-urlencode from=2026-06-20 --data-urlencode to=2026-07-20   --data-urlencode events=page_view --data-urlencode aggregation=unique_count   --data-urlencode timeGrain=none
curl --fail-with-body --get "$KANSOKU_BASE_URL/metrics/acquisition"   -H "Authorization: Bearer $KANSOKU_METRICS_KEY"   --data-urlencode from=2026-06-20 --data-urlencode to=2026-07-20   --data-urlencode measure=users --data-urlencode timeGrain=none
```

These curl examples assume the seeded account contains only the stated matching population; automated mixed fixtures must include their existing source_service isolation filter. Users and custom return a point shaped as follows, while acquisition retains its channel group:

```json
{"bucket":null,"group":{},"value":2}
```

AC-2 passes when one/two-dimension whole-range results equal independently computed distinct subject sets after the same route-specific selection, including traits, cohorts and bot choices. Entry_page is verified on acquisition, where it is supported. Event/user queries continue rejecting session-only dimensions. Cross-session repeats, identity resolution, account separation and replay must not inflate counts. Shared count/sum/average and session measures have independently calculated whole-range expected values too.

AC-3 passes when omitted grain, explicit hour/day/week/month and saved legacy definitions retain their existing semantics and baseline golden/route assertions. Add none tests without rewriting old expected outputs to accommodate unintended behavior. Rolling/daily-only modes, custom ratios, other unsupported routes, invalid ranges and unclosed observation windows still return documented errors. Empty and overflow behavior must match the decisions above.

AC-4 passes when the generated OpenAPI and guide agree on the wire spelling, six-route support matrix, users calendar restriction, null buckets, saved overrides and whole-period counting recipe. The generated-contract check and final packaged acceptance must both pass.

## Idempotence and Recovery


Generators and checks are repeatable. Owned harnesses create fresh stores and stop only their own processes; preserve private failure evidence and retry after fixing the cause. Saved-resource scenarios clean up only IDs created by the scenario, including on failure. No schema migration, materialized view, backfill or persisted whole-range aggregate is required.

The new server can read old definitions. An old server cannot decode a saved definition containing the new none value; before downgrading, explicitly remove or convert those owned definitions and stop clients sending none. Do not silently reinterpret none as a daily grain. Exact-query resource exhaustion continues to return the existing complete error, never partial counts or approximate fallback.

## Interfaces and Dependencies


The public change is the new TimeGrain wire value none, shared between URL requests and saved simple definitions. No new response field, client argument, dependency or version pin is required. Preserve `Maybe TimeGrain` in `MetricDefinition` and `QueryRequest`; the explicit constructor distinguishes whole-range override from omission. The native result remains String bucket, String group_key and Float64 value, with the empty bucket decoded as JSON null.

Mori discovery and local documentation inspection confirmed the existing driver query boundary at `mori://KovalevDima/ClickHaskell/docs/queries`; this work reuses it unchanged. No dependency bounds or compatibility workaround are being selected. If implementation reveals a dependency change is necessary, locate its sources with Mori and verify current authoritative registry releases and upstream tags before selecting versions. Other pending custom aggregation or acquisition plans may touch these files; preserve their accepted interfaces if they land first, and record any consequential integration change here without making them prerequisites.
