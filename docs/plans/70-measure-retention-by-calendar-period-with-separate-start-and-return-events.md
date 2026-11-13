---
id: 70
slug: measure-retention-by-calendar-period-with-separate-start-and-return-events
title: "Measure retention by calendar period with separate start and return events"
kind: exec-plan
created_at: 2026-11-13T05:48:57Z
provenance:
  created_by:
    model: "gpt-6.1-sol"
    harness: "codex-cli"
    at: 2026-11-13T05:48:57Z
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-13T13:52:13Z
      mode: "implement"
      note: "Implement calendar retention and independent start/return populations with native and public acceptance"
---

# Measure retention by calendar period with separate start and return events

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current during implementation. Record implementation friction with `agents/skills/exec-plan/record-friction.ts`, following `agents/skills/exec-plan/FRICTION.md`. Distill durable decisions into `docs/adr/` before completion. This document authorizes no deployment or release.


## Purpose / Big Picture

After this change, a consumer can ask “of the people who signed up each UTC week, how many created a document in each later week?” and receive exact counts without adding overlapping daily unique-user answers. The same endpoint supports calendar months, separate filters for starting and returning activity, and the existing day behavior. A cohort is the starting population; an offset is the number of calendar periods after its starting period. The response keeps `group.cohort`, `group.offset`, and numeric values, including offset zero for cohort size.

Implement [IR-20](docs/improvement-requests/measure-retention-by-week-or-month-with-start-and-return-events.md), including all five acceptance criteria. Success is observable through seeded public HTTP requests and the typed Haskell client, with complete answers or documented errors. The requesting UI is `mori://shinzui/kansoku-ui/plans/36-analyse-retention-by-daily-weekly-or-monthly-cohorts-with-start-and-return-events`, under `mori://shinzui/kansoku-ui/masterplans/7-build-the-insights-library-of-saved-analyses`. UI implementation, averages, curves, saved-analysis changes, release publication, and first-ever acquisition outside retained history are outside this plan.


## Progress

- [ ] Milestone 1: Core retention computes exact day/week/month cohorts with independent start/return selections; deterministic validation and owned native fixtures prove boundaries, grouping, lifetime, and unchanged daily results.
- [ ] Milestone 2: Public HTTP and typed-client requests expose the new options with fail-closed validation; an owned producer-to-report workflow proves a weekly signup/document query and a monthly boundary query.
- [ ] Milestone 3: Full acceptance covers the IR-20 matrix, complete-result/resource limits, and compatibility; generated contract, guide, capability, terminology, and durable ADR context describe the verified behavior.

Creation handoff: implementation has not begun. The working tree already contains the untracked IR-20 source and edits to `docs/improvement-requests/index.md` and `docs/improvement-requests/log.md`. Concurrent saved-analysis implementation and documentation edits also appeared during research, including changes to `docs/guides/query-metrics.md`; preserve and reconcile that work rather than overwriting it. This is a standalone plan with no parent MasterPlan or active Intention ID.


## Surprises & Discoveries

(None yet.)


## Decision Log

2026-11-13: Use `period=day|week|month`, with omitted period meaning day. Retain `days` as the sole offset parameter, interpreted in the chosen unit; an `offsets` alias is optional in IR-20 and is excluded to avoid two competing scalar parameters. Keep defaults `[1,7,14,30]` for day; use `[1,2,4,8]` for week and `[1,3,6,12]` for month so omitted offsets are valid for every period.

2026-11-13: Side filters accept event-level dimensions and properties, including event organization IDs, but reject saved-cohort membership, current user/organization traits, explicit `user_id`, and session attributes. These subject selectors remain governed by the existing shared-filter contract; `user_id` and session attributes remain unsupported on retention. This avoids adding new subject-selection semantics while satisfying IR-20's explicit choice to document or reject subject terms on a side. Across all three filter lists, retain one eight-filter/16,384-byte budget.

2026-11-13: Preserve grouping as separate populations. Each start event supplies its cohort's group values, and return events qualify only when their independently evaluated group key equals that cohort's key. A subject can enter different dimension groups, just as today; do not promise disjointness across groups or sum them into a unique population. This retains old grouped daily behavior, including event-name groups that cannot return under a different event name.

2026-11-13: Retain `timeGrain` validation independently of `period`: omitted or `day` is accepted, while hour/week/month/none remains `invalid_time_grain`. `period` controls cohort alignment and offset units, and retention still has no time-series bucket. Preserve cumulative maturity: all nonzero `on_or_after` offsets wait for the largest requested period to close.


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Kansoku accepts events through its HTTP server, queues them in PostgreSQL, and writes replay-safe analytical facts to ClickHouse. Retention counts exact resolved subjects: identities consolidated by the existing identity policy, or organizations when `aggregate=organizations` is selected. Identity/profile/group-only events are excluded from activity, and individual bot rows are excluded by default. “Lifetime” means first matching activity still retained, rather than first ever.

`kansoku-api/src/Kansoku/Metrics/Api.hs` owns the typed `MetricsRoutes.retention` endpoint, `RetentionMode`, `CohortMode`, and response types. The route currently takes shared `MetricArguments`, then `days`, `mode`, `cohort`, `includeBots`, and organization options. `kansoku-api/src/Kansoku/Metrics/Limits.hs` exports the 32-offset and 365-day bounds. `kansoku-api/src/Kansoku/Metrics/Filter.hs` owns the JSON filter grammar, legacy shorthand, OR alternatives, and size limits. Top-level filters are conjoined; an OR group accepts any of its terms. Neither syntax nor nullable comparison semantics should change.

`kansoku-core/src/Kansoku/Metrics/Handler.hs` parses offsets with `parseOffsets`, defaults to `[1,7,14,30]`, loads saved-cohort definitions with `withCohorts`, and calls `Query.runRetentionMetric`. `kansoku-core/src/Kansoku/Metrics/RequestValidation.hs` rejects unknown names, duplicate scalars, missing values, and oversized filters after authentication. Its current allowlist rejects every proposed new parameter. Both layers need changes; editing only the route leaves the feature unusable.

`kansoku-core/src/Kansoku/Metrics/Query.hs` owns `compileRetention`, `activityPopulationFor`, `runObserved`, `historicalScope`, native parameter binding, and complete-result ordering. Today one distinct `(canonical_user, active_day, group_key)` population supplies both first matching activity and returns. `compileRetention` finds first activity per subject/group, uses `addDays`, joins activity on subject and group key, counts with `uniqExactIf`, and emits an empty transport bucket. `runObserved` validates positive date ranges of at most 366 days and closed UTC observation before executing through `QueryPool`. An exclusive `to` includes events before midnight on that date, and cannot be later than the UTC date captured at request start. `historicalScope` widens the lower read boundary for lifetime cohorts; `accountParameter` also includes saved-cohort lookbacks in identity preparation.

`kansoku-core/src/Kansoku/Metrics/Query/Filter.hs` compiles operands into native query parameters using a caller-supplied prefix and determines which selected event declarations govern properties. `kansoku-core/src/Kansoku/Metrics/Query/Dimension.hs` resolves dimensions and their types; `kansoku-core/src/Kansoku/Metrics/Query/Validate.hs` owns `validateOffsets` and `mkSqlName`. Event names use the existing 1..128 lowercase ASCII letter/digit/underscore/dot/colon/hyphen grammar. Reuse it without requiring an ingest-registry declaration: a valid unmatched name produces no matching activity. Properties must still have a compatible declared scalar type for the events selected on that side.

`kansoku-client/src/Kansoku/Client/Metrics.hs` derives `metricsClient` from `MetricsRoutes`. Route additions therefore change its generated Haskell function arguments even when HTTP callers using old parameters continue to work. Transport tests live in `kansoku-client/test/Spec.hs`. Query/validation tests live in `kansoku-core/test/Kansoku/QuerySpec.hs`, `kansoku-core/test/Kansoku/Query/ValidateSpec.hs`, and `kansoku-core/test/Kansoku/Metrics/LimitsSpec.hs`; route/handler tests live in `kansoku-core/test/Kansoku/Metrics/RoutingSpec.hs` and `kansoku-core/test/Kansoku/Metrics/HandlerSpec.hs`. The routing suite has a manually typed `retentionSentinel` that must acquire the new arguments. Native activity tests live in `kansoku-core/test/Kansoku/Metrics/ActivityIntegrationSpec.hs`; organization and trait tests live in `kansoku-core/test/Kansoku/Metrics/OrganizationSpec.hs` and `kansoku-core/test/Kansoku/Metrics/TraitsSpec.hs`.

`scripts/session-attributes-acceptance.py` already executes the activity native family at ordinary and two-row block sizes against owned ClickHouse instances. `scripts/activity_acceptance.py` provides `verify_activity`, invoked by `scripts/acceptance.py` against the packaged server. `scripts/cohorts_acceptance.py` exposes `main(verify=...)` for a focused public workflow owning both stores, credentials, migrations, and server. Its verifier receives `base`, `write_key`, `token`, `other_token`, and keyword arguments. Reuse those boundaries rather than directing destructive native fixtures at development services. `justfile` documents build, deterministic, generated-contract, and acceptance commands. Local native qualification is Darwin arm64 with the exact ClickHouse artifact already selected by the Nix shell; if Linux containers are needed, use Apple Container and preserve the actual qualification boundary. Never use Colima or traverse `/nix/store`.

ADR discovery scanned local filenames/headings and consulted [ADR-4](docs/adr/0004-queryable-event-properties-and-identity-resolved-projection.md), which owns declared property types and exact identity-resolved facts; [ADR-9](docs/adr/0009-bounded-complete-aggregate-responses.md), which requires native input binding, input bounds, ordered complete responses capped at 10,000 points, and complete resource-limit errors; and [ADR-14](docs/adr/0014-closed-day-exact-activity-and-retained-history-cohorts.md), which owns closed UTC activity, same-population lookbacks, retention modes, lifetime, and maturity. [ADR-19](docs/adr/0019-saved-query-time-cohorts-and-static-membership.md) anchors saved membership to the original `to` and keeps selectors on identified people before organization aggregation. [ADR-21](docs/adr/0021-organization-aggregation-and-current-membership.md) preserves merged organization timelines and explicit/current membership attribution. [ADR-10](docs/adr/0010-owned-executable-acceptance-environments.md) requires owned stores and non-skipping proofs. This plan extends ADR-14's day-only cohort rule and ADR-9's day-only offset bound; their other constraints remain.

The ADR bundle is profile-governed at `docs/adr/profile.dhall`, confirmed with `mori show --full`. During creation, `mori registry list`, `search kansoku`, `show shinzui/kansoku-ui --full`, and `docs shinzui/kansoku-ui` failed because the local registry PostgreSQL socket refused connections. Cross-repository references above come directly from IR-20 and are not claimed as independently resolved. No dependency additions, version bounds, or upstream API changes are required. If implementation introduces any, first locate source/docs with Mori and verify release versions at the authoritative registry and upstream tags.


## Plan of Work

### Milestone 1: Generalize the core population and calendar calculation


Add a separate `RetentionPeriod` type with day/week/month constructors in `kansoku-api/src/Kansoku/Metrics/Api.hs`, alongside HTTP parsing/rendering instances following the existing enum conventions. Do not reuse `TimeGrain`: period and output grain have different contracts. Add public week/month maximum offsets of 52 and 12 in `kansoku-api/src/Kansoku/Metrics/Limits.hs`, preserving existing constants. Add a period-aware offset validator in `kansoku-core/src/Kansoku/Metrics/Query/Validate.hs`; keep `validateOffsets` as its day wrapper. Normalize ascending distinct nonzero offsets, enforce at most 32, and add offset zero internally. Preserve the day parser's current empty/comma handling and defaults; do not turn legacy parser cleanup into a compatibility change. Parse integers before conversion to `Int`, so oversized numbers fail safely.

In `kansoku-core/src/Kansoku/Metrics/Query.hs`, introduce retention-specific options and new builder/executor functions whose exact signatures are in Interfaces and Dependencies. Keep `QueryRequest` unchanged and preserve all existing retention builders/runners as wrappers using day and absent side selections. Add typed compile-error mapping for retention validation failures so builders, direct executors, and HTTP retain the same problem codes. A shared validation entry point must check offset bounds, event names, combined filter budgets, side-filter semantics, period alignment, and grain before cohort loading or pool checkout; the executor and compiler must enforce applicable checks independently of HTTP.

For weeks require `from` to be a UTC Monday; for months require day one. Reject misalignment with `invalid_retention_period`, without moving the date. Day accepts any date. Continue the positive, at-most-366-day range and closed-day `to` rule; `to` need not be aligned. Use a service-owned calendar operation selected by the enum: truncate to UTC day, Monday week, or calendar month; advance by whole days, weeks, or months. Never approximate months as 30 days or anchor ISO weeks on Sunday. For each subject/group, find the first matching start day over the window or retained-history scope, then assign its period's first day as the cohort label. Keep only first-start dates in `[from,to)`; alignment makes their period labels safe. The last cohort can be partial and still emits its observed size.

Construct independent start and return populations from the existing canonical activity source. Both apply account, activity exclusions, bot policy, shared filters, organization aggregation/attribution, and shared current-trait/cohort selectors. Add each side's optional event-name equality and side filters only on that side. The lifetime start population reads retained history; returns need only `[from,to)`. Prepare one identity scope covering both populations and all existing cohort lookbacks, anchored to the original exclusive `to`. Profile updates must never become start or return activity. Avoid changing `activityPopulationFor`'s callers for rolling users or lifecycle; factor a retention helper when necessary.

Use distinct parameter prefixes such as `retention_start_filter` and `retention_return_filter` for both independently compiled filter lists, plus distinct start/return event parameters. Never reuse `metric_filter_1_1` for two different operands. Compile `shared ++ startFilter` against the start event scope and `shared ++ returnFilter` against the return event scope. Include explicit event names when establishing each scope for governed properties. Resolve grouping on both scopes and require compatible dimension types. Contradictory valid event predicates yield no matching rows; they must not silently broaden the SQL selection. User values remain native parameters; only the closed period enum selects SQL calendar expressions.

Start-side rows determine group labels and first matching start activity separately per subject/group. Return-side rows evaluate the same dimensions and join on equal subject and group key, using the existing nullable-group encoding. A subject starting under `source_service=A` and returning only under B does not return for A. Current trait groups continue using current values on both sides. Deduplicate activity at subject/group/period or count exact subjects after joins so several return days cannot multiply a retained count. Return-only subjects never acquire a cohort, and repeated start events do not create later cohorts within a group.

For cohort start C and nonzero offset N, `on` counts a subject once if any selected return falls in `[advance(C,N),advance(C,N+1))`. Emit that offset only when `advance(C,N+1) <= to`. For maximum requested offset H, `on_or_after` counts once in `[advance(C,N),advance(C,H+1))`, including unrequested intermediate periods, and emits any nonzero offset only if `advance(C,H+1) <= to`. Offset zero is always cohort size regardless of return selection or maturity. Use a left join or equivalent zero-preserving calculation: a mature missing return is zero, while an immature offset is absent. Keep numeric cohort/offset ordering, the null transport bucket, and `group.cohort` formatted `YYYY-MM-DD`.

Acceptance is passing validator/compiler tests plus actual native results. First run one weekly signup/document example through the production query runner before expanding the matrix; calendar expression types, parameter namespaces, and exact joins must work through the driver. Extend `kansoku-core/test/Kansoku/Metrics/ActivityIntegrationSpec.hs` and adjacent trait/organization tests with the behavioral cases below. Keep the activity tests in the existing `Kansoku.Activity native` family so the current ordinary/tiny-block harness executes them. Deterministic tests use sentinel storage values that fail if invalid options acquire storage. Existing old-function tests must continue to pass unchanged in meaning.

### Milestone 2: Expose validated HTTP and typed-client options


Append `QueryParam "period" RetentionPeriod`, `QueryParam "startEvent" Text`, `QueryParam "returnEvent" Text`, `QueryParams "startFilter" MetricFilter`, and `QueryParams "returnFilter" MetricFilter` after the existing retention `days/mode/cohort/includeBots/OrganizationOptions` arguments and before its final response. Preserve the old argument order; only append new arguments. Adapt `retentionHandler` and every local route-record construction or call. In `kansoku-core/src/Kansoku/Metrics/Handler.hs`, choose period-specific omitted-offset defaults, validate options before `withCohorts`, and invoke the new core executor with the unchanged shared `QueryRequest`. A scalar event name is trimmed and checked by `mkSqlName`; a supplied empty value is invalid, and a comma-separated list is not one event name. Each absent name independently means any activity matching its side's filters.

In `kansoku-core/src/Kansoku/Metrics/RequestValidation.hs`, permit the five names only on retention. Allow repetition of `filter`, `startFilter`, and `returnFilter` on that route; the new scalars cannot repeat. Require each side-filter occurrence to have a value, apply UTF-8/JSON parsing and existing OR grammar, and apply one total eight-filter and 16,384 decoded UTF-8 byte budget across all three lists. Common malformed grammar or budget overflow uses `invalid_filter`. Semantically unsupported side dimensions use `invalid_retention_filter`, including inside an OR alternative. Specifically reject `cohort`, `cohort:<id>`, `user:*`, `org:*`, `user_id`, and `session:*` on a side; allow ordinary retention event dimensions such as `organization`, `source_service`, and governed `prop:*`. Preserve the existing shared-filter checks, including retention's `user_id` rejection. The same budgets and recursive restrictions must hold for typed direct calls.

Keep error precedence consistent with current authentication and malformed-request handling. Repeated scalars and bare side parameters return `invalid_query_parameter`; malformed period enum text uses the existing Servant `malformed_request` problem. An aligned-value failure uses `invalid_retention_period`; invalid/empty event names use `invalid_retention_event`. Out-of-range offsets use existing `invalid_retention_days`, now with unit-aware detail, and more than 32 distinct offsets uses `too_many_retention_days`. Other existing date, grain, grouping, property, resource, and point-limit problem codes remain. Test invalid names/offsets/alignment and unsupported side terms combined with an otherwise loadable shared cohort filter using a sentinel unavailable cohort store, proving validation wins before storage. Invalid inputs must never become empty successful answers.

In `kansoku-client/src/Kansoku/Client/Metrics.hs`, add Haddock documentation and a `retentionClient` alias derived from `Metrics.retention metricsClient`, exporting it with the complete route signature. Keep the route record as the single source of transport serialization. Update local client call sites and routing sentinels. In `kansoku-client/test/Spec.hs`, capture the outgoing HTTP request to prove omission of all five new options preserves old wire requests, period/name values encode correctly, and repeated side filters remain separate parameters alongside shared filters and the bearer credential. The source-level new arguments require `Nothing`/empty lists from callers; document this compatibility boundary rather than claiming Haskell source compatibility.

Add `scripts/retention-acceptance.py`, with a verifier accepting the `scripts/cohorts_acceptance.py` `main(verify=...)` callback contract and forwarding supported keyword arguments. It owns the standard stores/server through that existing harness, seeds through public ingestion, polls only reads, and first proves the weekly fixture and monthly maturity boundary specified below. Extend `scripts/activity_acceptance.py` with a reusable verifier for these cases and call it from both the focused harness and `verify_activity`, ensuring the packaged `just acceptance` path also exercises them. Keep fixture source namespaces distinct so old daily expected counts are unaffected. After this milestone, the new public producer-to-query path must actually pass; do not defer its first execution to final documentation work.

### Milestone 3: Complete behavioral coverage and publish the verified contract


Expand core and public cases to all scenarios in Validation and Acceptance. Keep all old daily fixtures and compare omitted period versus explicit day with absent names/side filters. Cover both modes, both cohort modes, grouped and organization results, bot changes, current traits/cohort filters, exact replay-safe identity behavior, and point/resource failures. Extend the existing activity cap tests to a weekly event-pair request with 5,000 independent groups and exactly two mature points each: 10,000 succeeds; one additional group produces `metric_result_too_large`, with no partial points. Exercise a deliberately tiny configured resource budget through the existing native fixture pattern and assert `query_resource_limit` for the generalized path. Do not invent new deployment settings or remove fail-closed limits to make a test pass.

Update `kansoku-api/src/Kansoku/Metrics/Api.hs` route descriptions and `kansoku-core/test/Kansoku/OpenApiSpec.hs`, then regenerate `docs/api/openapi.json` with `just openapi`. Describe period enum/defaults, unit bounds, implicit zero, aligned `from`, arbitrary closed `to`, cumulative full-horizon maturity, event-name grammar, combined filter budget, side restrictions, group matching, and errors. Verify these details in the served `/openapi.json`, not just the committed file. Update the Retention section, route table, bounds table, and examples in `docs/guides/query-metrics.md`. Include weekly signup/document and monthly examples, and explain that a partial final cohort contributes size without immature returns. Preserve old day examples.

Update `docs/capabilities/activity-retention.md`, `docs/terminology/retention-offset.md`, and `docs/terminology/retention-cohort.md` to describe period units and separate selections; retain stable handles and add evidence only after it passes. Update ADR-14 for calendar cohorts, side selection, and group/maturity semantics, and ADR-9 for period-specific bounds. Preserve the day-only output-grain rule for other activity metrics. Inspect `docs/adr/profile.dhall` before modifying its metadata, and maintain corresponding bundle timestamps/log entries through the existing OKF commands. Before declaring IR-20 satisfied, reconcile its five criteria with the recorded results; update its status/evidence only using the local improvement-request profile and established convention. Creation of this plan alone does not change IR-20 status.

Acceptance is successful focused native/public proofs and the relevant build, deterministic, OpenAPI, formatting, documentation-profile, and packaged gates below. Record the exact commands, nonzero executed-case counts, result summaries, and any real platform limitation concisely in Progress and Outcomes. Triage friction recorded during implementation and distill the final durable decisions into the ADRs. Communicate the final wire parameter names and semantics for the requesting consumer's reconciliation milestone in the completion report; no message to another repository or service is authorized by this plan.


## Concrete Steps

Run commands from the repository root. Enter the pinned development shell once; the remaining commands run inside it. These are implementation instructions, not evidence of checks already executed during plan creation.

```bash
cd /Users/shinzui/Keikaku/bokuno/kansoku-project/kansoku
nix develop --no-write-lock-file
just build-with-tests
just deterministic-test
```

Build must exit zero; deterministic core/client/probe suites must execute nonzero examples with no failures or pending cases. For focused development after building, run:

```bash
cabal test kansoku-core:kansoku-core-test --test-show-details=direct --test-option='--match=Kansoku.Activity inputs'
python3 scripts/session-attributes-acceptance.py
python3 scripts/retention-acceptance.py
```

The first command proves pure activity-input validation; the second requires the existing native activity and adjacent session/acquisition families at both block sizes, without pending examples. The third is added in Milestone 2 and must report passing weekly/monthly public fixtures through owned stores and the real server. Broader deterministic validation remains required for handler, routing, SQL builder, and client tests. Required native prerequisites failing must make these commands fail.

At the final coherent boundary, regenerate once and run the repository gate:

```bash
just openapi
just check
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
okf validate docs/improvement-requests --strict --profile docs/improvement-requests/profile.dhall --profile-enforce --log-enforce
just acceptance
git diff --check
```

`just check` covers test builds, non-mutating formatting, deterministic tests, generated drift, OpenAPI lint, documentation-profile checks, and the existing telemetry gate. If the formatting gate reports affected Haskell files, run `nix fmt`, inspect its diff, and rerun the affected checks. The explicit strict ADR check preserves the skill contract; validate improvement requests when recording their final evidence/status. `just acceptance` executes the packaged server and must include the extended activity workflow. Record public and native proof separately: compiling is not runtime evidence, and a successful Darwin run does not establish Linux qualification.

For a manual query against an owned running fixture, use its actual base URL and service token; the placeholders below are environment variables supplied by that fixture, not literal credentials. Seed the weekly dataset in Validation and Acceptance first.

```bash
curl --fail-with-body --get "$KANSOKU_RETENTION_BASE/metrics/retention" \
  -H "Authorization: Bearer $KANSOKU_RETENTION_TOKEN" \
  --data-urlencode 'from=2026-07-06' --data-urlencode 'to=2026-07-27' \
  --data-urlencode 'period=week' --data-urlencode 'days=1,2' \
  --data-urlencode 'startEvent=signup_completed' \
  --data-urlencode 'returnEvent=document_created' \
  --data-urlencode "filter=source_service:eq:$KANSOKU_RETENTION_SOURCE"
```

Expect HTTP 200 with the sorted cohort/offset counts shown below, null buckets, and metric `retention`. Do not print or commit credential values. The automated verifier supplies its own credentials and unique source, so a manual server is unnecessary for acceptance.


## Validation and Acceptance

Use this hand-computed weekly fixture for both native and public tests. All events have the same fixture source and ordinary nonbot resolved identities. A and B sign up on July 6, C signs up on July 12, and D signs up on July 13, 2026. A creates documents July 13, 15, and 19, and July 20; C creates one July 20; D creates one July 20. E creates a document July 14 but never signs up. An older subject signs up July 5 and July 7 and creates a document July 14. F signs up July 26 with no return. “Signs up” is `signup_completed`; “creates a document” is `document_created`. With `from=2026-07-06`, `to=2026-07-27`, `period=week`, `days=1,2`, and `cohort=window`, the old subject belongs to the July 6 cohort because its first in-range signup is July 7. `mode=on` produces exactly these ungrouped values:

```text
cohort       offset  value
2026-07-06   0       4
2026-07-06   1       2
2026-07-06   2       2
2026-07-13   0       1
2026-07-13   1       1
2026-07-20   0       1
```

A's three return days in week one contribute one subject. B is a mature non-returner; E contributes nothing to size or returns. With lifetime, July 6 size becomes 3 and offset one becomes 1, since the old subject's retained signup belongs to the previous week. With window and `on_or_after`, July 6 offset one becomes 3 (A, C, old subject) and offset two stays 2. July 13 still emits size, but both nonzero offsets are omitted because its largest horizon closes August 3. July 20 also emits only size. Requery with `to=2026-07-26`: July 6 offset one remains mature for `on`, offset two is absent, and all its nonzero cumulative offsets are absent. These exact assertions cover IR-20 AC-1/AC-2 and must pass through the public workflow early.

For months, seed M signing up January 31, 2024 and returning February 1 and February 29; N signs up January 1 and never returns; P signs up February 29. With `from=2024-01-01`, `to=2024-03-01`, `period=month`, `days=1`, January size is 2 and offset one is 1, while February emits size 1 only. With `to=2024-02-29`, January size stays 2 but its offset one is omitted because February 29 is outside the observation window and the full February period has not closed. February may be absent if P is its only start. Add month/year rollover, 28/29/30/31-day periods, an ISO week crossing a year, Monday midnight, Sunday 23:59:59.999, and an event exactly at exclusive `to`. Week and month `from` misalignment must return 400 `invalid_retention_period`; an unaligned `to` remains valid. Partial final cohorts always emit only their actually observed starters and mature offsets.

For independent selections, prove both name options independently default to any activity, unknown valid names give empty start cohorts or mature zero returns, repeat starts do not re-cohort, return-only subjects are excluded, and earlier unrelated retained activity does not move a lifetime signup cohort. Narrow start and return sides separately with event attributes and governed properties. Show a common source filter removes activity from both sides, while a start-only country filter cannot remove a qualified return from another country when ungrouped. Use distinct operands occupying the same filter position on both sides to expose native parameter-name collisions. Exercise JSON OR groups and shorthand, event-name filters conjoined with explicit names, missing properties, numeric/boolean types, and null groups. These prove AC-3 rather than just checking generated SQL text.

For AC-4, group weekly event-pair queries by one and two dimensions. Starts label their group and only returns with the same group values count; a cross-source return fails its starting source group. `groupBy=event_name` with different names produces mature zero returns under the preserved matching rule. Test shared current user traits, organization traits, and saved membership, including terms inside OR groups, anchored to original `to`. For organization aggregation, seed two members of one organization where one signs up and another returns: the organization has size one and return one, while person aggregation has no retained signup person from that pair. Preserve empty-organization exclusion, explicit stamped organization precedence, and current-membership fallback. Bot/profile-only activity, anonymous-to-identified stitching, replayed immutable IDs, and another account must obey the existing population rules on both sides. Keep old daily fixture values and omission/order behavior unchanged. Explicit `period=day` equals omitted period for valid legacy requests; no-new-option HTTP calls retain their old defaults, filters, status, and response shape.

Input tests cover day 365/366, week 52/53, month 12/13, zero, negative, huge integer, repeated/unsorted offsets, 32 versus 33 distinct values, and period-specific defaults. Values outside the unit's range return `invalid_retention_days`; deduplicated count overflow returns `too_many_retention_days` when values are otherwise in range. Explicitly test 33 valid weekly offsets; for months, the 12-value range means a 33-distinct-valid-offset case is impossible. Test repeated/bare/empty scalars, unsupported parameters on other routes, invalid enum values, invalid names, side subject/session terms, eight versus nine total filters, combined byte limits, and unknown property types. Every error is an `application/problem+json` response, and invalid options must fail before cohort loading/query acquisition. Preserve `unclosed_observation_window`, 366-day range bounds, `invalid_time_grain`, and 10,000/10,001 complete-point/resource-limit behavior.

For AC-5, typed-client capture tests prove scalar omission/encoding and repeatable side lists; at least one actual typed-client request in the owned public harness must reproduce the weekly expected response. Add an example named `live integration retention` in `kansoku-client/test/Spec.hs`; the existing deterministic runner excludes the `live integration` family. Invoke only this example from the focused verifier through `test_support.hspec` with `KANSOKU_REQUIRED_INTEGRATION=1`, `KANSOKU_SERVER_URL=base`, `KANSOKU_RETENTION_SERVICE_TOKEN=token`, and `KANSOKU_RETENTION_SOURCE` set to the seeded source. Use the weekly dates and expected counts above. These are test-only coordinates, following the existing live-analysis setup; no production option is needed. Required mode must reject absent coordinates or pending/zero examples. Compare served OpenAPI with the generated operation and assert all five options are documented, the two new side-filter parameters are repeatable while the three new scalars are not, and bounds/defaults/alignment/maturity agree with the guide. Preserve existing generated-contract checks. Record a concise mapping from AC-1 through AC-5 to executed evidence when complete.


## Idempotence and Recovery

This change needs no schema migration, materialized view, backfill, or persistent first-seen state. First matching starts and returns are computed from retained facts on every request. Old core functions remain wrappers, allowing additive development and direct regression comparisons. A server binary rollback restores prior HTTP behavior; new consumers must continue handling unsupported parameters against an older server.

Builds and generators are repeatable. Review generated OpenAPI changes and do not discard unrelated working-tree edits. Owned native/public harnesses allocate fresh stores and source namespaces; retry by starting a fresh harness run, retaining failed evidence and stopping only its recorded processes. Never run truncating native tests against ambient stores, reset shared databases, or reuse a failing fixture by silently skipping cases. If native environment qualification is unavailable, record that as missing evidence and leave the relevant milestone unfinished.

Commit meaningful implementation boundaries on the current branch using Conventional Commits and `ExecPlan: docs/plans/70-measure-retention-by-calendar-period-with-separate-start-and-return-events.md`. Preserve the existing IR-20 working-tree changes. Record subsequent plan revisions through `agents/skills/exec-plan/record-provenance.ts` after resolving the current runtime model per `agents/skills/exec-plan/PROVENANCE.md`; never hand-edit provenance.


## Interfaces and Dependencies

No new external dependency or package-version change is planned. Continue using the current Servant route/client derivation, native ClickHouse query path, PostgreSQL-backed shared saved-cohort definitions, and pinned development shell. Do not choose dependency versions from memory; any later dependency work requires Mori source/docs lookup and authoritative release verification.

Add these public types and retention-specific entry points, with existing wrappers retaining their signatures. Names below are proposed implementation names; keep the responsibilities and compatibility guarantees if local naming needs adjustment. `RetentionPeriod` belongs in `kansoku-api/src/Kansoku/Metrics/Api.hs`; the options/builders/runners belong in `kansoku-core/src/Kansoku/Metrics/Query.hs`; the period validator belongs in `kansoku-core/src/Kansoku/Metrics/Query/Validate.hs`.

```haskell
data RetentionPeriod = RetentionDay | RetentionWeek | RetentionMonth

data RetentionOptions = RetentionOptions
  { period :: !RetentionPeriod,
    startEvent :: !(Maybe Text),
    returnEvent :: !(Maybe Text),
    startFilters :: ![MetricFilter],
    returnFilters :: ![MetricFilter]
  }

defaultRetentionOptions :: RetentionOptions
-- RetentionDay, Nothing, Nothing, [], []

validatePeriodOffsets
  :: RetentionPeriod -> [Int] -> Either QueryLimitError [Int]

validateRetentionOptions
  :: RetentionOptions -> QueryRequest -> [Int]
  -> Either QueryLimitError [Int]

buildRetentionMetricSQLWithOptions
  :: EventRegistry -> RetentionMode -> CohortMode -> RetentionOptions
  -> QueryRequest -> [Int] -> Either QueryCompileError Text

runRetentionMetricWithOptions
  :: (IOE :> es)
  => EventRegistry -> QueryPool -> RetentionMode -> CohortMode
  -> RetentionOptions -> QueryRequest -> [Int]
  -> Eff es (Either QueryExecutionError MetricResult)
```

`validateRetentionOptions` returns normalized nonzero offsets and validates all pure options, including wire-filter semantics and alignment; compiler-specific property/group resolution still uses the registry. Keep date/observation validation at the existing execution boundary, with HTTP checks performed before cohort loading where applicable. The new options do not enable unsupported selectors on any other metric.

The HTTP argument order remains principal, `from`, `to`, `groupBy`, `timeGrain`, shared filters, `days`, `mode`, `cohort`, `includeBots`, `aggregate`, `attribution`, followed by period, start event, return event, start-filter list, and return-filter list. `kansoku-client/src/Kansoku/Client/Metrics.hs` exports `retentionClient` with the corresponding authenticated client signature. The successful `MetricResult` shape stays unchanged: `metric=retention`, null bucket, dimensions plus cohort/offset labels, and exact numeric counts. Shared constants, generated OpenAPI, documentation, and the consumer-facing completion report must all agree on this contract.
