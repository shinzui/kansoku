---
id: 47
slug: support-organization-trait-filters-in-saved-cohorts
title: "Support organization trait filters in saved cohorts"
kind: exec-plan
created_at: 2026-10-16T17:20:48Z
intention: "intention_01m52vndmcenmvqq6w1yphfykk"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-10-16T17:20:48Z
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-16T17:46:01Z
      mode: "update"
      note: "Remove assumed deployed definitions and verify fresh first-release creation and execution"
---

# Support organization trait filters in saved cohorts

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current. Promote durable implementation decisions into the relevant ADRs before completion.

## Purpose / Big Picture


Close F2 in [REV-2](../reviews/2026-10-16-initial-release-implementation-correctness.md#f2-organization-trait-conditions-produce-unusable-saved-cohorts). A saved behavioural cohort containing `org:plan` currently saves successfully but returns 503 when used. After this change, governed organization traits work inside event conditions, including OR alternatives, and cohort members and metrics return the correct identified-user population.

This plan has three milestones. [EP-48](48-clean-acceptance-fixtures-across-telemetry-modes.md) repairs the unrelated packaged-suite fixture failure. Support the already-accepted combination using the existing organization-trait projection; do not withdraw it through new validation errors. The service is undeployed; all verification uses definitions created on fresh first-release stores.

## Progress


- [ ] M1: Cohort condition sources attach the required typed organization traits, including those referenced only inside OR alternatives.
- [ ] M2: Native/public checks prove exact members, updates, complement semantics, and account isolation for organization-filtered cohorts.
- [ ] M3: Metric composition and packaged gates pass, and the cohort contract documents organization trait conditions.

## Surprises & Discoveries


(None yet.)

## Decision Log


2026-10-16: Reuse the existing account-scoped current organization-trait join in each event condition. Cohort membership remains a population of identified users; this repair does not turn cohorts into organization cohorts or introduce historical trait snapshots.

2026-10-16: Condition attribution uses the organization stamped on the resolved event. An outer metric's organization aggregation or current-membership attribution must not change the saved cohort's membership meaning.

Revision note (2026-10-16): Removed pre-fix persisted-definition and upgrade expectations after confirmation that this is the service's first deployment.

## Outcomes & Retrospective


(To be filled during implementation.)

## Context and Orientation


`kansoku-core/src/Kansoku/Cohort/Query.hs` validates definitions and builds membership subqueries. In `compileCondition`, filters compile successfully but the population reads `analytics.events_resolved_http` without the aliases needed by `org:` predicates. ClickHouse then reports unknown identifier `org_trait_plan`. The native error is wrapped as a storage failure even though the backend is healthy.

`kansoku-core/src/Kansoku/Metrics/Query/Traits.hs` supplies `referencedOrganizationTraits :: [Text] -> [Text]` and `organizationSource :: [Text] -> Text -> Text`. The latter adds one account/organization join, exposing typed nullable `org_trait_*` columns. `kansoku-core/src/Kansoku/Metrics/Filter.hs` supplies `filterTerms`, which finds leaves inside filter alternatives. `kansoku-core/src/Kansoku/Metrics/Query/Filter.hs` compiles parameterized predicates. Reuse these functions, including numeric seats and missing-value semantics.

[ADR-19](../adr/0019-saved-query-time-cohorts-and-static-membership.md) defines identified-user cohorts, distinct-event counts, original exclusive `to` anchoring, zero-occurrence membership and `didNot` complements. [ADR-21](../adr/0021-organization-aggregation-and-current-membership.md) defines current traits joined by account and organization, nullable missing traits, and event attribution. [ADR-20](../adr/0020-custom-metric-definitions-and-bounded-or-filters.md) defines bounded OR alternatives inside ANDed filters. Preserve these decisions. A current trait is its latest retained value, so changing it can intentionally reclassify historical event membership.

## Plan of Work


### M1 — Attach the typed trait source at the condition boundary


In `compileCondition`, collect every filter term's dimension with `concatMap filterTerms`, pass them to `referencedOrganizationTraits`, and wrap that condition's bounded resolved source with `organizationSource`. Keep event-name selection, native operands, account binding, lookback and distinct event counting unchanged. Deduplication belongs to the existing trait helper. Do not attach organization traits globally to unrelated conditions or only to the outer metric source.

Extend `kansoku-core/test/Kansoku/Cohort/QuerySpec.hs` for string and numeric traits, organization traits appearing only on the second side of an OR group, and a condition without any organization traits. Verify operand binding and account-scoped source composition. Keep `user:` event conditions rejected in favor of the existing cohort-level traits field. Unsupported organization trait names/operators must continue to fail definition validation. M1 passes the deterministic compiler tests and an early native/public reproduction: save a `feature_used` condition with `org:plan = pro`, then fetch its size successfully on the owned stack.

### M2 — Prove populations and current-trait semantics


Extend `scripts/cohorts_acceptance.py` using disposable account-scoped fixtures. Within the July 1–3, 2026 query window, create users A and B with feature events stamped to organization One, user C stamped to organization Two, user D with a feature event lacking organization, and user E with only another ordinary event. Supply governed `group` version-two events assigning One plan pro/seats 10 and Two plan enterprise/seats 2. Keep group fixture timestamps ordered and distinct. Scope cohort conditions to a unique fixture event/property or service filter so unrelated scenario events cannot affect counts.

Create and update conditions using `org:plan`, numeric `org:seats`, and OR terms that combine organization traits with ordinary event filters. Assert exact member IDs, size and both page directions, not only HTTP status. Pro selects A/B; seats greater than five selects A/B; a pro-or-enterprise condition selects A/B/C. Missing/null organization traits do not satisfy comparisons. Test `set` and `unset` against the shared missing-value contract.

Include `didNot` and upper-bound-only conditions, preserving zero-occurrence users in the observed user universe; specifically ensure E remains eligible where zero matching events should qualify. Combine an organization event condition with a current user-trait condition. Update One's current plan/seats with a later group event outside the reporting window but still retained, then prove the old saved definition reflects the new current trait values. Replaying the earlier group event must not revert the winner. Use the same user and organization IDs in another account with different traits to prove the join does not leak membership. Anonymous-only subjects remain excluded.

Register all created saved definitions for cleanup; clear static membership if any existing shared helper creates it. Coordinate with EP-48's fixture ownership helper rather than introducing another cleanup pattern. M2 is complete when the owned public scenario passes with the above exact populations and the prior organization/cohort scenarios remain green.

### M3 — Verify composition and document semantics


Use the saved cohort through `/metrics/users`, a saved custom metric and organization aggregation, including negative cohort selection. Exercise a session or funnel consumer that widens its source window to ensure the cohort's own lookback remains anchored to the original exclusive `to`. This is an indirect cohort selector; direct organization dimensions on session sources remain subject to their existing validation rules. Extend `scripts/organizations_acceptance.py` only where organization aggregation needs its own regression. Create the cohort through the candidate server and verify that subsequent reads and metric queries execute it correctly.

Update `docs/guides/query-metrics.md` and ADR-19 to state that organization traits are allowed within event conditions, use current values, join against each event's organization, and select identified users. Preserve user traits in the separate traits field. Maintain the documentation bundle logs. After EP-48, run the full packaged gate with the same regression included through its existing cohort verifier call. Mark F2 addressed only with recorded public/native evidence.

## Concrete Steps


Run from the repository root; the acceptance commands own their databases and migrate them automatically.

```bash
nix develop -c just check
nix develop -c just cohorts-acceptance
nix develop -c just organizations-acceptance
nix develop -c just custom-metrics-acceptance
```

After EP-48 removes the unrelated fixture blocker, verify the final candidate and documentation.

```bash
nix develop -c just acceptance
nix develop -c just guides-check
nix develop -c just adr-check
nix develop -c just reviews-check
git diff --check
```

Each required command must exit zero without skipped/pending prerequisites. Record exact population checks and the private acceptance evidence directory. Do not substitute string-only SQL assertions for native execution.

## Validation and Acceptance


A saved condition `{"did":"feature_used","withinDays":30,"filters":[{"dimension":"org:plan","op":"eq","value":"pro"}]}` must create successfully and execute as 200 for size, members and metric selection. Under isolated fixtures it selects exactly A/B before the current-trait update. Both create and update paths enforce the same supported dimension/operator rules. Numeric seats uses numeric comparison, OR-only referenced traits are attached, and nullable comparisons agree with direct metric filtering.

Positive and negative selection, zero occurrences, cross-account duplicates, current-trait changes and replay have explicit expected populations. The SQL remains bounded by the existing lookback/resource limits and uses parameterized values. Cohorts without organization terms retain prior behavior. Final evidence includes successful packaged execution across all telemetry modes after EP-48.

## Idempotence and Recovery


No deployed definitions exist to migrate. Validate definition creation and execution together on fresh stores. Use fresh owned stores for destructive native checks and clean up only scenario-owned definitions. Current trait updates are fixture data and must not target an ambient service.

## Interfaces and Dependencies


The change is internal to `Kansoku.Cohort.Query.compileCondition` and the existing trait/filter helpers. Public definition JSON, cohort IDs, parameters, pagination and response types remain unchanged. No new dependency or version selection is required. EP-48 is a prerequisite only for claiming a passing complete packaged gate; the compiler and focused acceptance work can proceed independently of EP-46.
