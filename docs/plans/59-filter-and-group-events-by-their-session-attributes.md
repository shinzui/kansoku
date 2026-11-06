---
id: 59
slug: filter-and-group-events-by-their-session-attributes
title: "Filter and group events by their session attributes"
kind: exec-plan
created_at: 2026-11-06T04:01:26Z
intention: "intention_01m6qg70kve4vs7m8qyfjey80s"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-11-06T04:01:26Z
---

# Filter and group events by their session attributes

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current during implementation. Record implementation friction using `agents/skills/exec-plan/FRICTION.md`, and distill durable decisions into the relevant ADRs before completion.


## Purpose / Big Picture


Implement [IR-9](../improvement-requests/filter-and-group-events-by-their-session-attributes.md). A consumer should be able to select visits from organic search and report every page viewed, active person, and custom event inside those visits. On `/metrics/page-views`, `/metrics/users`, and `/metrics/custom`, `session:channel` will describe the event's web session, while existing `channel` continues to describe the individual event. A search visit with three pages must produce three page views for `session:channel:eq:organic_search` and only its landing view for the ordinary channel filter.

The same session dimensions work in grouping, including `groupBy=route,session:referrer_host`, and in saved custom definitions and either population of a custom ratio. The feature uses existing retained session facts; it needs no ingestion changes, new timeout, storage migration, or backfill. Funnels, paths, retention, and other routes are outside this plan.


## Progress


- [ ] Milestone 1: Page-view filtering and grouping use whole retained session attributes, demonstrated through the real native query executor.
- [ ] Milestone 2: Calendar/rolling users and ad-hoc/saved custom metrics, including both ratio populations, accept the same dimensions without changing existing metric populations.
- [ ] Milestone 3: Native and authenticated public acceptance prove isolation, missing-session behavior, attribution parity, replay safety, and unchanged result limits.
- [ ] Milestone 4: Generated API documentation, query/enrichment guides, and ADRs describe the shipped behavior, and required checks pass.


## Surprises & Discoveries




## Decision Log


2026-11-06: Use an explicit `session:` namespace on the three requested routes, with a closed set of intrinsic session attributes. Keep the existing event and whole-session resolvers restricted to their current callers. This prevents shared query helpers from accidentally enabling session selection on excluded routes.

2026-11-06: Attach one fully assembled session row to each eligible web event by account, source service, and session ID. Apply event dates, event-name/property filters, event identity, and existing row-level bot policy to the event population. Do not filter the session relation by the event date range or by its start date. This preserves event metrics while adopting exactly the existing first-touch attribution, including sessions that started before `from`.

2026-11-06: A missing session never satisfies a session-scoped filter term, including `unset` and `neq`, and contributes null when grouped by a session dimension. A real session with a missing attribute can satisfy `unset`. Apply this eligibility guard inside each Boolean alternative, so an event can still satisfy an ordinary-event alternative in a mixed OR group. This follows IR-9's explicit missing-session requirement without changing the generic null-filter contract.

2026-11-06: Preserve current bot semantics: page views/users exclude individual bot events by default; custom metrics keep their existing population. Joining a session must not automatically exclude its clean events because another event in that session was a bot. Session/acquisition routes continue their whole-session bot exclusion. Attribution parity therefore means equal attribute values for equal keys, not identical counts across routes with different date/bot populations.


## Outcomes & Retrospective




## Context and Orientation


Kansoku is a Haskell service. `kansoku-api` defines HTTP types and shared filter grammar; `kansoku-core` validates metrics and compiles service-owned SQL for ClickHouse; `kansoku-server` runs the application. PostgreSQL stores saved custom definitions. A dimension is a named, typed value used in a predicate or grouping. Canonical events are accepted facts deduplicated by immutable event identity, so retry/replay cannot inflate aggregates. A retained session is all remaining web events sharing `(account_id, source_service, session_id)`, excluding empty session IDs. First-touch attribution uses the earliest `page_view`, or earliest event if no page exists, ordered by `(occurred_at, event_id)`.

`kansoku-core/src/Kansoku/Metrics/Query/Session.hs` already exports `sessionProjection` and `materializedSessionProjection`. The first assembles canonical events; the second merges `analytics.sessions` aggregate states into one row per session key. Both expose first-touch event/enrichment values, entry/exit URLs, session times, and the maximum bot flag. The state was established by `db/clickhouse/migrations/0020_replay_safe_sessions.sql`. Reuse it; never join raw aggregate-state rows directly, since a session can span several inserts and parts.

`kansoku-core/src/Kansoku/Metrics/Query/Dimension.hs` owns `GroupDimension`, type/label/expression rendering, `resolveDimension`, and `resolveSessionDimension`. The event resolver has no `session:` namespace; the whole-session resolver adds entry/exit pages and excludes organization dimensions. `kansoku-core/src/Kansoku/Metrics/Query/Filter.hs` compiles AND groups containing OR alternatives, binds every operand, and determines finite event scopes for property validation. Its current `unset` uses `isNull(expression)` without a session-presence guard. `kansoku-api/src/Kansoku/Metrics/Filter.hs` parses shorthand prefixes `prop`, `user`, and `org`; it must recognize `session` too. JSON filters already carry dimension names as text.

`kansoku-core/src/Kansoku/Metrics/Query.hs` connects dimensions to event sources. `compileSimpleMetric`, `simpleAggregateSQL`, `countEventsSQL`, `uniqueUsersSQL`, and `propertyAggregateSQL` cover simple metrics. `compileMetric` compiles ratio component predicates; `buildRatioSQL` executes them over a resolved event source. `compileUsers` handles calendar users directly and rolling users through `compileRolling` and `activityPopulation`. That activity helper is also used by excluded routes, so support must be explicitly selected by the users caller. `resolvedSource` adds current user/organization traits to the identity-resolved event relation. Preserve those enrichments and the existing canonical event identity when adding session columns.

`kansoku-core/src/Kansoku/Metrics/Custom.hs` validates saved definitions and merges saved simple defaults into a request. `customBuiltin` normalizes custom names so labels cannot dispatch built-in behavior. `kansoku-core/src/Kansoku/Metrics/Handler.hs` loads saved definitions and discovers cohorts across ratio component filters before removing those extra filters from the common request. Session-join discovery must inspect the actual definition as well as request filters; inspecting the final common request alone would miss component-only session predicates. `kansoku-core/src/Kansoku/Metrics/DefinitionHandler.hs` uses the same custom validation on writes.

Relevant ADRs were discovered by scanning local filenames/headings and reading these records. [ADR-12](../adr/0012-server-enrichment-and-first-touch-web-acquisition.md) owns first-page attribution, immutable enrichment, and the distinction between event bot exclusion and whole-session bot exclusion. [ADR-13](../adr/0013-whole-retained-replay-safe-web-sessions.md) requires merging retained state before selection, deterministic ordering, replay safety, and entry/exit values from page views only. [ADR-20](../adr/0020-custom-metric-definitions-and-bounded-or-filters.md) requires saved/ad-hoc parity, side-local ratio filters, shared validation, and bounded parameterized OR filters. [ADR-9](../adr/0009-bounded-complete-aggregate-responses.md) requires complete results up to 10,000 points, an overflow witness at 10,001, and existing work/deadline budgets. [ADR-10](../adr/0010-owned-executable-acceptance-environments.md) requires disposable owned integration stores and forbids treating skipped/pending examples as acceptance. The ADR bundle uses `docs/adr/profile.dhall`; preserve its stable handles and metadata contract.

The request originated from `mori://shinzui/kansoku-ui/masterplans/3-build-the-reports-page`; this plan requires no UI changes. Local [plan 56](56-attribute-conversions-to-first-touch-acquisition.md) also touches session/acquisition compilation, but its conversion feature is not a prerequisite. Coordinate shared code edits without changing its population contract. Preserve unrelated working-tree changes encountered during implementation.


## Plan of Work


### Milestone 1: Deliver the page-view path with shared session attribution


Add a closed `SessionAttribute` type and a `GroupBySessionAttribute` constructor in `kansoku-core/src/Kansoku/Metrics/Query/Dimension.hs`. The public suffixes are `channel`, `referrer_host`, `utm_source`, `utm_medium`, `utm_campaign`, `utm_content`, `utm_term`, `entry_page`, `exit_page`, `device_class`, `browser_family`, `os_family`, `country_code`, `event_name`, `source`, `source_service`, `host`, `route`, and `is_bot`. These are intrinsic attributes the sessions route can select today. `is_bot` is Boolean; the others are nullable strings using the same normalization as existing session expressions. `session:route` is the attribution event's route; `session:entry_page` specifically requires a page view. Do not include nested `session:prop:`, `session:user:`, `session:org:`, or cohort dimensions: those are separate governed event/person concepts, not intrinsic visit fields.

Introduce a separate resolver for event metrics that opt into session dimensions, delegating unprefixed names to the existing event resolver. Keep `resolveDimension` and `resolveSessionDimension` rejecting this namespace for existing callers. Return full prefixed labels in the response and use compiler-owned aliases for SQL expressions. Refactor existing expression helpers where needed so host/referrer normalization and nullable values cannot drift between event-attached sessions and whole-session metrics. Do not construct identifiers from unchecked suffix text.

Extend `kansoku-api/src/Kansoku/Metrics/Filter.hs` to parse `session:channel:eq:organic_search`, `session:country_code:unset`, and OR alternatives. Extend `kansoku-core/src/Kansoku/Metrics/Query/Filter.hs` so each session term compiles to `session_present AND <ordinary typed predicate>`. The presence condition must be inside the OR term, never added globally for all filters. Continue binding operands with distinct prefixes and preserving existing byte, group, and alternative bounds.

In `kansoku-core/src/Kansoku/Metrics/Query/Session.hs`, add an event-source decorator: a service-owned subquery selecting all event columns plus uniquely named nullable session attribute columns and an explicit session-presence marker. Left join the finalized `materializedSessionProjection` by all three key columns, additionally requiring the event to have `source='web'` and a nonempty session ID. Preserve the left event's `occurred_at`, `is_bot`, properties, and canonical subject. The right side must be unique per key. Use an explicit marker and nullable projections so an unmatched join yields null even under ClickHouse settings that fill nonnullable fields with defaults; do not rely on ambient `join_use_nulls` behavior.

Only decorate when grouping or filters need the session namespace. For page views, use the decorated canonical source after the existing raw/resolved source choice. Keep date/event/property/bot predicates outside session assembly. Add the first native fixture in a new `kansoku-core/test/Kansoku/Metrics/SessionAttributeIntegrationSpec.hs`, register it in `kansoku-core/test/Spec.hs` and `kansoku-core/kansoku-core.cabal`, and exercise `Query.run` with the real pool. Give the suite the description `Kansoku.Session attributes native`, add it to the native skip list in `scripts/deterministic-tests.py`, and create the owned runner described below. Acceptance is three versus one page views plus a correct two-dimension result, replayed at normal and tiny native blocks. This first executable join proof must pass before broadening consumers.

### Milestone 2: Extend the same relation to users and custom definitions


Pass explicit session support through the requested metric compilers in `kansoku-core/src/Kansoku/Metrics/Query.hs`, without enabling it in every shared `requestGrouping`, `requestFilters`, or `resolvedSource` call. Calendar users, rolling7, and rolling30 must select eligible activity events and then count their existing resolved identities. In rolling queries the event side retains its existing lookback window; the session side remains whole retained history. User/organization traits and cohorts retain their present event/identity meaning. Support existing users organization aggregation/attribution options by decorating the existing resolved source, without choosing the session's primary subject as the counted user or organization.

Update `kansoku-core/src/Kansoku/Metrics/Custom.hs` to use the opt-in dimension resolver when validating both saved and ad-hoc definitions. Support Count, UniqueCount, Sum, Average, and their ratio components through the existing aggregation paths. Any additional aggregation already present at implementation time must use the same decorated source rather than bypassing it. Preserve numeric property declarations and their per-event extraction. Saved simple filters/default grouping, request overrides, request filters, and both ratio component filters all participate in determining whether a join is needed. Deduplicate requested session columns and perform one attachment per event relation. A ratio's common filters apply to both populations; component predicates remain side-local inside their aggregates. Session-only component filters must trigger the join even with no common filters or session grouping.

Add deterministic cases to `kansoku-core/test/Kansoku/Metrics/FilterSpec.hs` and `kansoku-core/test/Kansoku/Metrics/CustomSpec.hs`, and native cases to the new suite. Acceptance requires active-user counts across more than one session, a rolling lookback case, numeric sums/averages unaffected by join multiplication, and ratios with different source selection on each side. Unsupported suffixes and excluded routes must fail during validation, before a storage request. Keep the current route-specific problem rendering (`invalid_filter`, `invalid_group_by`, or the existing custom-definition `invalid_metric` wrapper); do not invent a new error family.

### Milestone 3: Prove native semantics and authenticated consumer behavior


Complete the fixture matrix in Validation and Acceptance. Compare joined attributes against both existing session projections on known session keys, reusing the reference technique in `kansoku-core/test/Kansoku/Metrics/SessionIntegrationSpec.hs`. Sessions do not publicly return session IDs, so do not invent a new public ID dimension to test IR-9 AC-3: compare keys using native reference SQL and compare public aggregates over fixtures with deliberately known populations. Exercise acquisition/session route attribute parity on clean sessions whose starts lie in range; separately assert the documented differences for cross-boundary and mixed-bot sessions.

Extend `scripts/enrichment_acceptance.py` so its existing authenticated producer workflow proves landing-only versus visit-wide page selection, users, and route/referrer grouping. Extend `scripts/custom_metrics_acceptance.py` to create and execute saved simple and ratio definitions with session-scoped filters, fetch/update them, and prove account isolation. Use its existing `OwnedResources` scope to clean exactly the created definitions. Include an ad-hoc custom request and both shorthand and JSON filters. Retain the existing public workflow hooks in `scripts/acceptance.py`; do not run destructive native tests against a shared development service.

The native runner must reject missing prerequisites, zero examples, and pending cases through `test_support.hspec`. Add final-group overflow cases in `kansoku-core/test/Kansoku/Metrics/LimitsSpec.hs` or the new suite, using a session grouping that produces exactly 10,000 and 10,001 points. Existing parameterization and work-limit tests stay applicable; add a malformed suffix/injection case and a literal operand containing quotes/colons/pipes to prove the new path stays parameterized. Acceptance is the focused native runner, the existing custom public runner, and the packaged public workflow passing with the new assertions.

### Milestone 4: Publish the contract and finish validation


Update the three route descriptions in `kansoku-api/src/Kansoku/Metrics/Api.hs` and shared filter documentation as needed, then regenerate `docs/api/openapi.json`. The wire result remains unchanged: prefixed keys are ordinary keys in each point's `group` map. Update `docs/guides/query-metrics.md` and `docs/guides/web-enrichment.md` with the complete allowed suffixes, event versus session attribution examples, missing-session/operator behavior, saved ratios, rolling users, and date/bot distinctions. Show both JSON and shorthand filters and `groupBy=route,session:referrer_host`. State that people can occur in multiple session-channel groups, so summing grouped distinct-user counts is not a whole-range distinct-user total.

Update ADR-13 to record event attachment, its key/eligibility rules, and unchanged event time/identity populations. Update ADR-12's explanation of source attribution and ADR-20's namespace support where needed. Preserve ADR handles and maintain guide/ADR metadata and logs under their existing profiles. Do not mark IR-9 implemented until all four acceptance criteria actually pass. At completion, record concise evidence in this plan, triage recorded implementation friction, and run the required checks below. No runtime behavior is implemented by this create-mode task.


## Concrete Steps


All commands run from the repository root, `/Users/shinzui/Keikaku/bokuno/kansoku-project/kansoku`. These are future implementation/acceptance commands, not claims that acceptance ran during plan creation. Use the locked Nix development environment and owned service helpers. Never inspect or traverse `/nix/store` or target an ambient database.

```bash
nix develop --no-write-lock-file -c just build-with-tests
nix develop --no-write-lock-file -c just deterministic-test
```

Create `scripts/session-attributes-acceptance.py` using this existing helper contract, and add `session-attributes-acceptance: build-with-tests` to `justfile`, executing that script. The adjacent session/acquisition suites guard unchanged projection semantics.

```python
from isolated_clickhouse import isolated_clickhouse, apply_migrations
from test_support import binary, hspec

for block_size in (65536, 2):
    with isolated_clickhouse(block_size=block_size) as env:
        apply_migrations(env)
        for family in ('Kansoku.Session attributes native',
                       'Kansoku.Sessions native', 'Kansoku.Acquisition native',
                       'Kansoku.Activity native'):
            hspec([binary('kansoku-core:test:kansoku-core-test'),
                   '--match=' + family], env=env, timeout=300)
```

```bash
nix develop --no-write-lock-file -c just session-attributes-acceptance
nix develop --no-write-lock-file -c just custom-metrics-acceptance
nix develop --no-write-lock-file -c just openapi
nix develop --no-write-lock-file -c just openapi-check openapi-lint
```

Each test family must report a positive example count with zero failures and no pending examples. The public custom workflow must reach its success output after the new saved-definition assertions. If a tool/service prerequisite is unavailable, record the blocker rather than treating skipped tests as passing.

At the final coherent implementation boundary, format changed source, maintain documentation logs, and run:

```bash
nix fmt
nix develop --no-write-lock-file -c just check
nix develop --no-write-lock-file -c just acceptance
nix develop --no-write-lock-file -c dhall type --file docs/adr/profile.dhall
nix develop --no-write-lock-file -c okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
nix develop --no-write-lock-file -c just guides-check
git diff --check
```

Expect exit status zero from each required check. `just acceptance` must reach `Acceptance passed: required native/live tests, Hurl, packaged administration/startup and three telemetry modes.` with the new enrichment assertions executed. Native tests can clear fixture tables, so always run them through the owned runners. Do not run unrelated additional benchmark gates without a new concern that justifies them.

Record implementation provenance once per contributing model/session using `agents/skills/exec-plan/record-provenance.ts` and the runtime discovery procedure in `agents/skills/exec-plan/PROVENANCE.md`. Implementation commits use Conventional Commits and both trailers:

```text
feat(metrics): select event populations by session attributes

ExecPlan: docs/plans/59-filter-and-group-events-by-their-session-attributes.md
Intention: intention_01m6qg70kve4vs7m8qyfjey80s
```


## Validation and Acceptance


Use an isolated account with web service `session-attributes-web`. Session A belongs to person A and contains July 1, 2026 page views at `/landing`, `/pricing`, and `/checkout`; only `/landing` has referrer `https://www.google.com/search`, channel `organic_search`, and campaign `launch`. Later pages have same-site referrers and ordinary direct attribution. Session B belongs to person B and contains `/landing` and `/pricing`, arriving from `news.ycombinator.com` with channel `referral`. Query July 1 inclusive through July 2 exclusive. The session channel filter returns three A page views; the ordinary channel filter returns one. Session referrer grouping paired with route returns three Google route points and two Hacker News route points, each value one. Group labels include the full `session:` prefix. This proves IR-9 AC-1 and AC-2 through native execution and HTTP, not SQL text matching alone.

Users selected by A's channel count one person. Give A another selected session and assert the same calendar bucket still counts one; give A a session in B's channel and assert A may appear in both groups. Add clean activity in a rolling7/rolling30 lookback day whose session landing is earlier than that lookback; the user qualifies in the appropriate closed-day rolling bucket using the retained landing attribution. Retain the users route's existing restrictions on open days and grains. Exercise a current user trait/cohort and the existing organization option alongside a session filter so event identity semantics remain intact.

Add two web `payment_completed` events in A's session with amounts 2 and 4, and one in B's session with amount 6, using registered numeric property declarations. For A's session channel the custom count is 2, unique count is 1, sum is 6, and average is 3. A custom count/count ratio with numerator filter `session:channel:eq:organic_search` and denominator filter `session:channel:eq:referral`, with no common filter, returns 2. A request filter applies to both populations; a zero denominator preserves the existing zero result. Repeat through saved definitions and request grouping overrides, and test session grouping on ratios. Existing event-property grouping restrictions on ratios remain.

For every allowed suffix, compare the attached value to the corresponding existing session attribute on known keys. Supply distinct first-event and first-page values, including a lifecycle event before the landing page, a zero-page session, later conflicting campaign/device/country values, and two page events with identical timestamps but different event IDs inserted in reverse order. First page wins; absent a page, earliest event wins; entry/exit remain null for zero-page sessions. Repeat immutable inserts in different blocks and verify no count/sum/ratio inflation before background merges. Compare materialized and canonical reference projections. An event before the first page can still inherit that retained first-page attribution, even when the first page is outside the requested event interval.

Cross-boundary selection must retain event metric meaning: put A's landing before `from` and later pages inside the range. The later pages count under A's session attributes even though `/metrics/sessions` excludes A because its start precedes `from`. An event exactly at exclusive `to` does not count. Sessions/acquisition and the new predicates select the same keys when the comparison fixture places all starts/events in range and uses equivalent bot policy; use native key comparison for AC-3 rather than equating event counts with session counts.

Include a web event with no session ID, a non-web event with the same session text as A, an event in another service with that same ID, and another account using identical service/session IDs. No cross-service/account attachment is allowed. Missing-session and non-web events group under null for a session dimension and cannot satisfy any session filter term, including `unset`, `neq`, and an `in` list. A valid session with no country does satisfy `session:country_code:unset`. In `session:channel:eq:organic_search|source:eq:server`, a matching server event is admitted by its event alternative and has a null session group. Separate repeated filters still mean AND. These cases make the eligibility guard and OR placement observable.

Add a bot event to an otherwise clean session, including outside the event date range. Clean page views/users keep their existing row policy, while `session:is_bot=true` reflects the whole retained session flag. `includeBots=true` changes only the existing event-row exclusion; whole-session routes retain their established different default. Custom metrics do not acquire an undocumented default bot filter.

Unknown suffixes, empty/nested prefixes, unsupported scalar operators, duplicate/more-than-two groups, and session dimensions on excluded routes return existing permanent validation problems. Malformed values never become SQL identifiers or unbound operands. Exactly 10,000 final points succeed; 10,001 return `metric_result_too_large` without partial results. Existing filters, result shapes, replay behavior, and no-session requests pass unchanged. The two updated guides and generated API explicitly show event `channel` versus `session:channel`, satisfying AC-4.


## Idempotence and Recovery


The change is query-only and additive at the API dimension level. There is no migration or session-state rebuild. Existing retained-state correction/erasure rules remain in force. Rerunning owned acceptance creates fresh stores; public scenarios use unique event/session/service names and clean only their own saved resources. Never truncate a shared service to recover a fixture. A failed native join should be fixed within the existing resource and account boundaries, not by removing limits or filtering away unmatched events globally.

Regenerating OpenAPI is repeatable. Keep its generator edits and generated output together. Preserve unrelated edits, and resume from the first unverified milestone with concise failure evidence. Rollback consists of reverting this feature's query/parser/docs changes together; if saved definitions using `session:` have since been created, those definitions will require editing before they can execute against an older server. No accepted event data needs rewriting.


## Interfaces and Dependencies


Public endpoints, query parameter names, and `MetricResult`/`MetricPoint` types do not change. Session names are values of existing `filter` and `groupBy` parameters. Saved `CustomDefinition` JSON retains its shape. A valid session grouping can combine with any currently supported second dimension on the same route, within the existing two-dimension limit. No client generator schema redesign is required.

In `kansoku-core/src/Kansoku/Metrics/Query/Dimension.hs`, expose a closed attribute type, its label/type mapping, and an opt-in resolver with the same input/output shape as `resolveDimension`:

```haskell
resolveEventSessionDimension
  :: EventRegistry -> [EventName] -> Text
  -> Either DimensionError GroupDimension
```

In `kansoku-core/src/Kansoku/Metrics/Query/Session.hs`, add a service-owned helper of the following shape; its source argument is generated by the compiler, never accepted from the API:

```haskell
attachSessionAttributes :: [SessionAttribute] -> Text -> Text
```

An empty attribute list returns the original source. Otherwise the returned relation preserves all event columns, adds the required prefixed-dimension aliases, and carries a deterministic presence marker. Keep attribute expression ownership in the dimension layer to avoid an import cycle between Session and Query. In Query, collect referenced attributes from effective grouping, common filters, saved simple defaults, and both ratio components; thread explicit eligibility for the three routes through shared builders. Generic cohort, funnel, activity, and whole-session callers must keep their existing resolvers unless explicitly opted in by this plan.

No dependency version changes are planned. Mori lookup identified the existing driver at `mori://KovalevDima/ClickHaskell/packages/ClickHaskell` and its query reference at `mori://KovalevDima/ClickHaskell/docs/queries`; the reference was read during planning. Reuse the repository's current query-pool, native binding, block-decoding, and result-boundary code. If a dependency API question arises, use `mori registry search`, `mori registry show --full`, and `mori registry docs` to locate source before relying on memory. Any proposed new dependency bound or workaround requires authoritative package-registry and upstream-release verification. This plan is independent of pending conversion, percentile, channel-classification, and UI plans, while sharing their existing session/dimension interfaces.
