---
id: 68
slug: select-identified-users-in-metric-queries
title: "Select identified users in metric queries"
kind: exec-plan
intention: intention_01m799qcyte1kvc37y7phtjdxd
created_at: 2026-11-13T00:18:09Z
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-11-13T00:18:09Z
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-11-13T01:52:49Z
      mode: "implement"
      note: "Implement bounded resolved-user selection within the existing metric contract"
---

# Select identified users in metric queries


This ExecPlan is a living document. Maintain Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective during implementation. Follow `agents/skills/exec-plan/PLANS.md`, `agents/skills/exec-plan/ADR.md`, and `agents/skills/exec-plan/FRICTION.md` for updates, durable decisions, and implementation friction.

## Purpose / Big Picture


Implement [IR-18](../improvement-requests/select-one-identified-user-in-metric-queries.md): consumers can chart one identified user's activity using the existing metric endpoints, without creating a temporary cohort. A request such as `/metrics/events?from=2026-07-01&to=2026-07-02&groupBy=event_name&filter=user_id:eq:alice` will include Alice's pre-login events when current identity evidence resolves them to Alice, while excluding an unrelated anonymous subject named `alice`.

The filter works on events, page views, users, sessions, acquisition, revenue, feature adoption, and custom metrics. It retains existing populations, date rules, grouping, result shapes, and execution limits. Session selection keeps the complete session owned by its first resolved user. This is backend query work; the user directory/profile resource in [Plan 67](67-read-identified-users-profiles-and-event-history.md), raw history reads, anonymous selection, organisation selection, and UI changes are outside scope.

## Progress


- [x] Milestone 1 (2026-11-13): Core compilers select resolved identified users with bounded operands, correct event/session ownership, and passing deterministic and native behavior tests.
- [x] Milestone 2 (2026-11-13): Public HTTP and saved/ad-hoc custom metrics satisfy the eight-route contract, reject unsupported uses before execution, and pass an owned-store acceptance workflow.
- [x] Milestone 3 (2026-11-13): Query guide, generated OpenAPI and ADRs publish the contract; focused acceptance and documentation checks pass. The broad packaged gate was stopped to honor the user’s testing scope.

Acceptance evidence: `just build-with-tests` succeeds; the acquisition acceptance runner passes 50 native cases across block sizes 65536 and 2, including lone-ID stitching, anonymous collisions, same-ID account isolation and complete first-user session ownership. `just deterministic-test` passes 524 core examples, 22 client examples and four production probes. The owned-store identified-user workflow passes all eight routes, opaque IDs, saved simple/side-local ratios, cohort in/out, mixed OR, bounds and a cross-midnight session with identity evidence outside the start-date range. Existing custom metrics acceptance passes unchanged. OpenAPI generation/check/lint, guide validation and strict ADR validation pass. The packaged server/client build and its 662-example core run also passed, but the full packaged workflow was intentionally stopped before completion; no three-telemetry-mode acceptance is claimed.

## Surprises & Discoveries


## Decision Log

2026-11-13: Honor the user’s instruction to keep testing focused on this API change. The eight-route owned-store workflow, native ownership checks, deterministic tests and documentation checks provide completion evidence. Stop the unrelated broad packaged regression run; completing that run is not required for this implementation.


2026-11-12: Name the dimension `user_id` and make it filter-only. Support `eq`, `neq`, and `in` with 1..20 raw string entries per list, checked before deduplication. The request targets one or a few users; twenty is an explicit small-population bound below the generic grammar's 100-value ceiling. The `user:<trait>` namespace, including a possible governed trait called `id`, remains separate. Values are original opaque IDs, not namespaced subjects or SQL names.

2026-11-12: `neq` selects other identified users only. Anonymous and empty subjects fail every `user_id` comparison. This follows the existing rule that missing scalar values fail comparisons, including `neq`; it is not a complement over all anonymous activity. Guards belong inside each Boolean term so another OR alternative may independently select an anonymous event.

2026-11-12: Support precisely the eight requested route families, including all existing users windows, session/acquisition measures, and custom aggregations. Other metric routes explicitly reject the dimension. Preserve each route's existing restrictions: `timeGrain=none` remains unavailable for revenue, feature adoption, rolling users and custom ratios, and `session:` dimensions remain limited to page views, users and custom. This implements composition with existing capabilities without adding new grain or dimension support.

2026-11-12: Use existing resolved relations and whole-session assembly. Do not add a raw-user predicate, identity-specific storage projection, migration, persisted one-user cohort, or dependency upgrade. A user filter alone must trigger the same identity-aware source and preparation scope that traits/cohorts already require.

## Outcomes & Retrospective

Implemented bounded, filter-only `user_id` selection on all eight requested route families, including saved/simple/component custom populations, resolved event ownership and complete first-user sessions. Focused public acceptance satisfies IR-18 AC-1 through AC-3; compiler/client/native checks and generated documentation checks pass. No dependency, migration or execution-budget change was needed. ADR-9, ADR-16 and ADR-20 retain the durable contract. The broad packaged gate was stopped after the user reiterated the focused scope; it is not reported as passing. FRIC-25 in `docs/friction-log/` is accepted: use a per-invocation local Nix builder override when remote dispatch delays an owned acceptance run.


## Context and Orientation


An identified user is a resolved subject of kind `user` with an original `subject_id`. An anonymous subject has kind `anonymous` even if its ID has identical text. The rich HTTP relation `analytics.events_resolved_http` exposes those fields and `canonical_user`, the tagged representation `user:<original id>` or `anonymous:<original id>`. Canonical events deduplicate repeated immutable event IDs. Resolution uses account-scoped retained evidence, including evidence outside the requested occurrence interval; it does not mean selecting raw `user_id` from ingested events.

`kansoku-api/src/Kansoku/Metrics/Filter.hs` defines the shared JSON/shorthand grammar, `filterTerms`, AND-combined repeated filters and bounded OR alternatives. It already limits groups to eight, alternatives to eight, `in` to 100 scalar entries, each string to 1024 UTF-8 bytes, and combined decoded filters to 16384 bytes. `kansoku-core/src/Kansoku/Metrics/Query/Filter.hs` binds operands natively and renders each term separately. `kansoku-core/src/Kansoku/Metrics/Query/Dimension.hs` currently uses `GroupDimension` for both filters and grouping, so adding a new constructor without a filter-only resolver would accidentally expose grouping.

`kansoku-core/src/Kansoku/Metrics/Query.hs` owns public builders/runners and compilation. `requestFiltersFor` and `requestGroupingFor` choose event/session-attribute resolvers. `hasUserTraits` is currently a broader identity-source switch that includes organisation and cohort needs; `simpleAggregateSQL`, `compileSessionsWithContains`, `runSessionMetricWithContains`, and `compileAcquisition` depend on it. `rawResolvedSource` supplies the private relation; `runSQL` prepares identity on the physical connection before executing it. A filter must be discovered even when it occurs only inside an OR alternative or saved ratio component.

`kansoku-core/src/Kansoku/Metrics/Query/Session.hs` assembles retained web events sharing `(account_id, source_service, session_id)` before date/attribute selection. Its resolved `primary_subject` chooses the earliest identified subject ordered by `(occurred_at,event_id)`, falling back to anonymous only when there is no identified user. `kansoku-core/src/Kansoku/Metrics/Query/Traits.hs` attaches traits to this owner. Session filters must apply to this finalized owner, never remove constituent events. Acquisition conversions use first-touch attribution over retained sessions and conversions; retain that algorithm while selecting owners.

`kansoku-core/src/Kansoku/Metrics/Custom.hs` validates saved definitions and merges simple defaults into a request. Ratios retain their component filters separately. `compileMetric` parses both components and combines their dimension discovery for the source, while keeping their predicates local to their own aggregates. `kansoku-core/src/Kansoku/Metrics/Handler.hs` loads definitions/cohorts and maps errors; `kansoku-core/src/Kansoku/Metrics/RequestValidation.hs` checks public filters after authentication and before handlers. Generic filter syntax failures currently return `invalid_filter`, so the requested dimension-specific `invalid_metric` requires an intentional shared validation/error path.

`kansoku-api/src/Kansoku/Metrics/Api.hs` owns route descriptions and the generated OpenAPI contract. `docs/api/openapi.json` is generated, not hand-maintained. `docs/guides/query-metrics.md` describes the route matrix. `kansoku-core/src/Kansoku/Metrics/Registry.hs` establishes that feature adoption counts resolved users of `feature_used`, revenue sums `payment_completed.amount`, and active users exclude identity-only events. Keep those meanings.

Relevant ADRs were discovered by filename/heading and read for this plan. [ADR-5](../adr/0005-evidence-based-multi-signal-identity-resolution.md) requires conservative tagged identity and complete retained evidence. [ADR-9](../adr/0009-bounded-complete-aggregate-responses.md) requires positive ranges of at most 366 days, native time/memory budgets, and complete answers of at most 10000 points; the 10001st row is an overflow witness, never a partial response. [ADR-13](../adr/0013-whole-retained-replay-safe-web-sessions.md) fixes retained-session assembly, start-date attribution, bot behavior and replay safety. [ADR-16](../adr/0016-governed-current-user-traits-and-replay-safe-erasure.md) supplies event-versus-first-session-user ownership. [ADR-19](../adr/0019-saved-query-time-cohorts-and-static-membership.md) requires account-scoped identified membership and original request `to` anchoring. [ADR-20](../adr/0020-custom-metric-definitions-and-bounded-or-filters.md) requires bounded AND-of-ORs, saved/common/component filter composition, and shared compiler limits.

The consumer is `mori://shinzui/kansoku-ui/plans/32-enrich-the-user-profile-with-per-user-activity-charts`, coordinated by `mori://shinzui/kansoku-ui/masterplans/6-build-the-users-directory-and-user-profile-pages`. This plan is standalone and has no dependency on delivery of IR-17. Mori registry discovery failed during authoring because its notification PostgreSQL socket refused connections. These consumer references come from IR-18; cross-repository resolution and dependency internals were not verified. This plan relies on inspected local implementation and proposes no new dependency APIs. At creation, unrelated changes existed in the improvement-request index/log and an untracked named-analysis request; preserve them.

## Plan of Work


### Milestone 1: Compile and execute identified-user selection


Create `kansoku-core/src/Kansoku/Metrics/Query/UserSelection.hs` as the shared owner of discovery and semantic validation, registering it in `kansoku-core/kansoku-core.cabal` as needed. Put the public `maxSelectedUserIds = 20` constant in `kansoku-api/src/Kansoku/Metrics/Limits.hs`. Walk every `filterTerms` result. Accept only `eq`/`neq` with one nonempty string or `in` with 1..20 nonempty strings; preserve exact bytes and case, and reuse the 1024-byte generic bound. Never trim, lowercase, remove an existing `user:` prefix, parse as UUID, or apply `mkSqlName`. Bound lists before optional deduplication, so 21 copies of Alice fail. Numeric-looking IDs require a JSON string or quoted shorthand operand because the existing shorthand parser infers numbers.

Add a dedicated compiler error for invalid identified-user selection mapped to `invalid_metric`, and use the same validator from public request validation. Generic malformed JSON, oversized aggregate filter payloads, and grammar violations keep `invalid_filter`; a syntactically valid 21-entry list must return `invalid_metric`. Reject unsupported operators, empty IDs, nonstring operands and unsupported route use through the new semantic path. `groupBy=user_id` returns `invalid_group_by`, including saved defaults; `user:id` continues through governed trait lookup.

Keep ordinary dimension resolution closed to `user_id`. Add a filter-specific wrapper/resolver and a service-owned internal dimension/expression representation to reuse native parameter binding in `compileFiltersWith`. Event predicates compare a nullable original ID expression such as `if(subject_kind='user',subject_id,CAST(NULL,'Nullable(String)'))`. Session predicates use `if(startsWith(primary_subject,'user:'),substring(primary_subject,6),CAST(NULL,'Nullable(String)'))`. The prefix removal is on the internal tagged subject only. No caller-supplied text may become an SQL expression. Do not base event matching on `canonical_user` where organisation aggregation can replace that column. Ordinary comparison compilation already coalesces null to false; verify `in` and `neq` against the actual native engine as well.

Extend the identity-source discovery switch, preferably renaming `hasUserTraits` to explain its broader role, and update all uses coherently. A lone `user_id` filter, including an OR-only occurrence, must cause count, sum, average and percentile queries to use resolved facts. Sessions and acquisition session counts must switch from the materialized fast path to canonical resolved assembly. Session execution must prepare the retained identity scope, not just the selected dates. Existing cohort lookback and original `to` anchoring remain intact. Do not push the user predicate below identity resolution or session assembly and do not discard evidence to save work.

Add capability checks to all public core builders/runners as well as HTTP. Support events, page views, users calendar/rolling7/rolling30, sessions, acquisition, revenue, feature adoption, and custom. Reject on conversion, organizations, paths, funnel, retention, lifecycle, stickiness, and every experiments route. Shared internal helpers used by supported and unsupported routes must not accidentally opt unsupported entry points in. For users/feature adoption with existing organisation aggregation options, the filter still selects event `subject_kind/subject_id` before the existing aggregation; it must not reinterpret a user ID as an organisation ID.

Extend `kansoku-core/test/Kansoku/Metrics/FilterSpec.hs`, `kansoku-core/test/Kansoku/QuerySpec.hs`, and `kansoku-core/test/Kansoku/Metrics/CustomSpec.hs` for validation and compiler behavior. Extend `kansoku-core/test/Kansoku/Metrics/TraitsSpec.hs`, `kansoku-core/test/Kansoku/Metrics/SessionIntegrationSpec.hs`, and `kansoku-core/test/Kansoku/Metrics/AcquisitionIntegrationSpec.hs` for actual values. These native families are already run by `scripts/acquisition-acceptance.py` at ordinary and tiny block sizes. First prove a stitched event and a complete session with only `user_id` selection before expanding the matrix: another trait filter would mask a missing identity-source trigger. Milestone acceptance is native equality to hand-computed results and deterministic rejection tests, not SQL substring assertions alone.

### Milestone 2: Deliver the public and saved-definition contract


In `kansoku-core/src/Kansoku/Metrics/RequestValidation.hs`, validate route support and dimension semantics after the existing grammar checks and authentication. Invalid supported-route selection and unsupported-route selection must fail before cohort loading or query checkout. Apply equivalent checks to saved definitions in `kansoku-core/src/Kansoku/Metrics/Custom.hs` and to the effective request/components in `kansoku-core/src/Kansoku/Metrics/Handler.hs`. Request filters on a saved metric can be rejected before definition lookup; definition-owned filters can only be checked after that definition is loaded. Revalidate loaded definitions rather than trusting historical writes.

Saved simple filters AND with request filters. A common `user_id` filter selects both ratio sides; a component-only filter selects only its own side while still forcing source discovery. Retain the combined group/byte budgets. Mixed OR alternatives such as `user_id:eq:alice|event_name:eq:page_view` keep their ordinary Boolean meaning, including anonymous page views matched by the second term. New selection must not escape into cohort definition conditions merely because a shared resolver was extended; leave that separate API's accepted dimensions unchanged unless already explicitly supported.

Add HTTP tests to `kansoku-core/test/Kansoku/Metrics/HandlerSpec.hs` and `kansoku-core/test/Kansoku/Metrics/RoutingSpec.hs`, including a sentinel unavailable pool and a cohort operand to prove user-selection rejection precedes storage access. Test every unsupported route with otherwise valid required parameters. Extend `kansoku-client/test/Spec.hs` to capture a typed JSON filter containing an opaque ID, proving the existing `MetricFilter` transport sends it intact. No route argument or client function signature changes are needed.

Create `scripts/user_selection_acceptance.py` with `verify_user_selection(base, write_key, token, other_token, **kwargs)` and a standalone entry point calling the owned-store `main` from `scripts/cohorts_acceptance.py` with that verifier. Follow `scripts/traits_acceptance.py`, `scripts/custom_metrics_acceptance.py`, and `scripts/acceptance_resources.py` for public ingestion, finite visibility polling, saved resource cleanup, and isolated source-service names. The cohort harness supplies extra erasure/large-upload arguments; the verifier can ignore those unrelated options. Wire the verifier into `scripts/acceptance.py` beside the traits/cohort workflows for each telemetry mode. Account isolation can be checked by reading the same requested ID with `other_token`; native tests must also seed the exact same ID in a second account.

Use the fixtures and expected answers below. Include at least one authenticated real HTTP assertion per required route, saved and ad-hoc custom execution, cohort in/out grouping, unknown-user empty results, and the 21-entry `invalid_metric` response. This milestone is accepted when the standalone public workflow passes against owned PostgreSQL/ClickHouse and deterministic handler/client tests pass.

### Milestone 3: Publish and verify the consumer contract


Update `docs/guides/query-metrics.md` with the exact dimension, operators, limits, nullable/negative semantics, opaque-ID examples, supported route matrix, and event/session ownership. Explain that identity or cohort changes may reclassify historical results, selecting an absent user yields an ordinary empty metric rather than a profile 404, and result shape/bot/date rules remain route-specific. Include both JSON and shorthand examples, using JSON strings for numeric-looking IDs and IDs containing `|`. Explain that `in` is a combined population, not implicit per-user grouping.

Describe cost honestly: filtering one user does not imply a keyed lookup or a scan proportional to that user's events. Raw count/sum/percentile paths now pay identity-resolution cost, and sessions can require retained-history assembly; warm connection snapshots may help, but existing execution/memory deadlines and the 10000-point complete-result cap apply. Do not promise a speedup or relax budgets to pass tests.

Amend descriptions in `kansoku-api/src/Kansoku/Metrics/Api.hs`, then regenerate `docs/api/openapi.json`. Add assertions in `kansoku-core/test/Kansoku/OpenApiSpec.hs` for semantics, bounds and unsupported-route documentation, and inspect the live schema in the public workflow. Preserve the existing filter wire type. At completion update ADR-16 with explicit-ID selection and ADR-9 with the bound/error contract; update ADR-20 only where saved/component behavior needs additional durable explanation. Preserve stable ADR handles and use the repository's profile/log workflow. Refresh guide metadata/log consistently. Do not mark IR-18 implemented until public evidence satisfies AC-1 through AC-3.

Run the relevant final gates below, record concise evidence, triage material implementation friction, and distill any additional durable discoveries into the applicable ADR. No performance benchmark threshold or new platform qualification is introduced by this plan.

## Concrete Steps


All commands run from the repository root, containing `cabal.project`, `flake.nix`, and `justfile`. Inspect `git status --short` and preserve unrelated work. Use the locked development environment and the migration-embedding build wrapper:

```bash
nix develop --no-write-lock-file -c just build-with-tests
nix develop --no-write-lock-file -c just openapi
nix develop --no-write-lock-file -c just deterministic-test
nix develop --no-write-lock-file -c python3 scripts/acquisition-acceptance.py
```

The build must succeed. Deterministic families must have zero failures/pending cases; the acquisition/session/trait native families must run positive case counts at block sizes 65536 and 2 with zero failures/pending. Run the first focused native proof during Milestone 1. Extend existing covered families rather than introducing a native family that the deterministic runner accidentally executes against its sentinel port.

After adding the public verifier, run:

```bash
nix develop --no-write-lock-file -c python3 scripts/user_selection_acceptance.py
nix develop --no-write-lock-file -c just custom-metrics-acceptance
```

The new verifier should print `Identified-user metric selection: passed (8 routes)` only after all assertions, including negative tests, pass. The custom gate must retain its existing saved/component/session population proofs. Scripts own disposable stores and fail on missing prerequisites; skipped native coverage is not acceptance. `scripts/isolated_clickhouse.py` currently qualifies native Darwin arm64 execution. If Linux execution is needed, use Apple Container and preserve the explicit coverage boundary; never use Colima or silently substitute an unqualified runtime. Do not inspect `/nix/store` or traverse the filesystem root.

At the final candidate, run checks whose evidence is invalidated by the completed changes:

```bash
nix develop --no-write-lock-file -c just openapi-check
nix develop --no-write-lock-file -c just openapi-lint
nix develop --no-write-lock-file -c just guides-check
nix develop --no-write-lock-file -c okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
nix develop --no-write-lock-file -c just format-check
nix develop --no-write-lock-file -c just acceptance
git diff --check
```

Before ADR edits inspect `mori show --full` and the declared `docs/adr/profile.dhall`, then use `okf log add --help` for the installed log interface. The explicit `okf validate` command adds strict enforcement to the local ADR profile/log checks. Do not rewrite unrelated files to satisfy formatting. Packaged acceptance must exercise the new workflow in each existing telemetry mode and retain normal sanitized evidence. No application tests are claimed by this plan's creation.

For a manual check against an already running fixture instance, use its issued service token and source service. The public verifier must print the nonsensitive fixture source and Alice ID so these values can be copied:

```bash
curl --fail-with-body --get "$BASE_URL/metrics/events" \
  -H "Authorization: Bearer $SERVICE_TOKEN" \
  --data-urlencode 'from=2026-07-01' --data-urlencode 'to=2026-07-02' \
  --data-urlencode 'groupBy=event_name' --data-urlencode 'timeGrain=none' \
  --data-urlencode "filter=source_service:eq:$FIXTURE_SERVICE" \
  --data-urlencode "filter=user_id:eq:$ALICE_ID"
```

For the baseline below, the response is HTTP 200, metric `events`, null buckets and event-name values `page_view: 2`, `identify: 1`, `feature_used: 1`, `payment_completed: 2`. No Bob or colliding anonymous points contribute.

## Validation and Acceptance


For AC-1, give every fixture invocation a fresh prefix and source service. In one account, seed Alice's session with a pre-login `page_view` at 12:00:00, an `identify` v2 at 12:00:10 binding her cookie to her explicit user ID and setting `plan=pro`, another page view at 12:00:20, `feature_used` with `feature=export` at 12:00:30, and payments with amounts 2 and 4 at 12:00:40 and 12:01:00. Use July 1, 2026 UTC and valid registered properties/schema versions. Both pages have route `/alice`, and the first-page URL carries `utm_medium=email` to establish channel `email`. Seed Bob's separate session with one page, the same feature, and a payment of 10. Seed an anonymous-only session whose anonymous ID equals Alice's original user ID text, with one page, the same feature, and a payment of 100. Its cookie must not equal Alice's bound cookie. Replay the immutable baseline and verify unchanged results.

`eq Alice` yields six events, `neq Alice` yields Bob's three events only, and `in [Alice,Bob]` yields nine. The anonymous collision never satisfies a user term. Add a separate user whose original ID starts with `user:` and IDs containing quotes/backslashes/Unicode; JSON filter transport must preserve them and native binding must match exactly without treating them as SQL or stripping prefixes. A valid unknown ID returns the route's ordinary no-data shape. Test the same ID in another account and ambiguous shared-cookie evidence that remains anonymous. Evidence outside the selected event dates must still stitch qualifying candidate events.

For AC-2, the eight baseline public route checks are: events as above; page views 2; calendar users 1; session count 1, average duration 60 seconds and bounce rate 0; acquisition sessions/users 1 in the email group; revenue 6 using a supported day grain; feature adoption one user in feature `export` using a supported day grain; custom payment count 2, unique_count 1, sum 6, average 3 and percentile at 0.5 equal to 3. For a custom ratio of payment count to page-view count with common Alice selection and no explicit grain, expect 1. A saved ratio with Alice only on the numerator and the source-service baseline on both sides returns 2/4, proving its denominator retains Bob and the anonymous subject. Validate saved simple defaults and request conjunction independently.

Create static cohorts containing Alice and containing only Bob using public APIs. `groupBy=cohort:<id>` with Alice selection emits only `in` for the first and only `out` for the second, with values matching the selected population; a nonexistent membership group must not appear as a zero-valued second group. Combine user selection with a governed `user:plan` trait, `prop:amount` numeric filter on payment scope, and `session:channel` on supported page-view/users/custom routes. Test AND and mixed OR with an anonymous page as the independent alternative. Unsupported property/session namespaces retain their existing errors.

Use separate session fixtures to prove ownership: two explicit users sharing one retained session produce different event-level selections, but only the first resolved user selects the complete session and its acquisition attribution. An earlier anonymous event subsequently stitched to that first user remains present. Cross-midnight input and identify evidence after the selected session-start date must not shrink duration, move attribution to the login event, or lose the session. Native and public checks must include a filter that is the only reason to choose the identity-aware session branch. Preserve `containsEvent`, bot exclusion/opt-in and acquisition conversion measures; verify a converted user's first-touch channel and denominator remain unchanged by equivalent trait versus ID selection.

Exercise every currently allowed grain for affected route families and `none` on events, page views, calendar users, sessions, acquisition and simple custom metrics. Rolling7/rolling30 use their existing daily windows and lookback; include an Alice event just before the requested output range. Revenue/feature adoption/rolling users/custom ratios retain their existing explicit-`none` error. Existing organisation aggregation on users/feature adoption must still filter the original user and then count the existing organisation population. Do not add organisation-ID selection.

For AC-3, exactly 20 raw ID entries are accepted and 21 are rejected with HTTP 400 `invalid_metric`, including 21 identical IDs. Test invalid operators, empty strings, wrong scalar types, malformed/over-budget filters, and `groupBy=user_id` with the documented error split. A generic 101-entry list is already a grammar error (`invalid_filter`); the dimension-specific bound applies to grammar-valid lists. All unsupported metric routes reject `user_id` with `invalid_metric`, including inside an OR group, rather than returning ignored-filter answers. Authentication and principal-derived account scope precede validation. Use sentinel-store tests to prove validly parsed rejected requests do not load cohorts or acquire query connections.

Retain complete-result and resource-limit coverage. Add an identified-user filtered variant to the existing fixtures in `kansoku-core/test/Kansoku/Metrics/LimitsSpec.hs` and/or `scripts/query-limits.py` so 10000 grouped points succeed, 10001 fail without partial data, and cold identity preparation remains under the shared budget. Use existing deterministic exhaustion fixtures rather than asserting arbitrary wall-clock performance. Review generated and live OpenAPI plus the guide for the name, 20-ID limit, operators, ownership, cost, and unchanged result limits.

## Idempotence and Recovery


No schema migration, backfill or durable per-user selection object is required. Old requests without the new dimension preserve their source choices and answers. Reverting the implementation restores rejection of the previously unknown dimension; saved custom definitions containing it then require editing before execution, so document that compatibility consequence.

Tests create fresh event/source identifiers and owned databases; replay only deliberately immutable events within a case. Use `OwnedResources` to remove test definitions/cohorts. Never clear ambient stores. Retain failed owned-fixture evidence and rerun with a fresh fixture rather than modifying existing user data. Do not turn missing native prerequisites into passing skips.

On implementation, append one provenance revision with `agents/skills/exec-plan/record-provenance.ts` and verified current runtime identity. Log material friction as it happens and triage it at completion. Commit relevant changes on the current branch with Conventional Commits and `ExecPlan: docs/plans/68-select-identified-users-in-metric-queries.md`. No intention was linked at creation. Implementation uses `intention_01m799qcyte1kvc37y7phtjdxd`, created with `mina ci --json` at the user’s instruction; include its `Intention:` trailer on implementation commits.

## Interfaces and Dependencies


The public addition is a new value of the existing filter dimension string. For example:

```json
{"dimension":"user_id","op":"eq","value":"alice"}
{"dimension":"user_id","op":"neq","value":"alice"}
{"dimension":"user_id","op":"in","value":["alice","bob"]}
```

There is no new route parameter, response field, grouping dimension, client argument, or identifier namespace. An ID is a nonempty opaque string subject to the existing 1024 UTF-8 byte scalar limit. Each `in` term permits 1..20 raw entries; normal eight-group/eight-alternative and aggregate-byte budgets still apply. Conditions combine under the existing AND-of-OR grammar.

`Kansoku.Metrics.Query.UserSelection` owns shared term discovery and semantic validation returning structured selection errors. `Kansoku.Metrics.Query.Filter` retains native operand binding; filter-only dimension resolution supplies the event or finalized session expression. `Kansoku.Metrics.Query` owns route capability checks, resolved-source selection, physical-connection identity preparation, and mapping the selection error to `invalid_metric`. `Kansoku.Metrics.RequestValidation` reuses those pure rules before storage. Saved definitions use the same rules through `Kansoku.Metrics.Custom` and are revalidated at execution.

Use the current locked Haskell/native dependencies and repository-owned query infrastructure. Before making any new dependency API assumption, use Mori to locate its source/docs; if dependency bounds, pins or compatibility workarounds become necessary, verify current released versions against the authoritative registry and upstream tags. Restore registry access before relying on dependency internals. Neither the UI consumer's release nor Plan 67 is a prerequisite for executing this plan.
