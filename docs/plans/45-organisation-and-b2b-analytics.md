---
id: 45
slug: organisation-and-b2b-analytics
title: "Organisation and B2B analytics"
kind: exec-plan
created_at: 2026-10-15T15:14:00Z
intention: "intention_01m4zwwdrjesytazp5tb39fe3n"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-15T15:14:00Z
  revisions:
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-16T12:47:09Z
      mode: "implement"
      note: "Implement organisation aggregation, governed traits and current membership attribution"
---

# Organisation and B2B analytics

This ExecPlan is a living document. Update its living sections and durable ADRs as work
proceeds. It is a standalone plan, independent of
`docs/masterplans/5-act-on-rev-1-close-silent-loss-paths-add-metric-filters-and-enrich-web-analytics.md`,
that implements the `/metrics/organizations` stub and the organisation-level analytics that
MasterPlan 3 deferred until property grouping existed.


## Purpose / Big Picture

A B2B product will be able to count customers, not people: active organisations per week,
the onboarding funnel by organisation (an organisation completes a step when any of its
users does), retention of organisations, revenue by organisation plan, and organisation
properties such as plan or seat count set once with `group`. Events already carry
`organizationId`; this plan makes it queryable and adds the organisation as an aggregation
unit, which is what PostHog calls group analytics and Amplitude calls accounts.


## Progress

- [x] M1 (2026-10-16): Migration 0025 appends organization_id without changing the original seven-column prefix. The public route returns exact bucket counts and organization filters; owned fixtures return [2,1], and the conservative identity battery plus two native cache cases pass.
- [x] M2 (2026-10-16): All five routes support organisation aggregation. Native/public checks distinguish [2,1] organisation funnel reach from [3,2] user reach, verify a chain completed by different members, retention [2,1], conversion 0.5 and feature adoption 1. User defaults and experiment parameter rejection pass.
- [x] M3 (2026-10-16): Governed group v2 stores current typed organisation traits with deterministic replay-safe ordering. Enterprise then pro resolves to pro; revenue groups as plan=pro, seats=10, value=7. Group v1 remains context-only; Haskell helper versions, erasure runbook and current-definition maintenance rebuild are updated.
- [x] M4 (2026-10-16): Current membership fills only unstamped events for resolved user subjects. Native/public checks cover pre-login stitching, anonymous/user text collisions, explicit-event precedence, moves outside the reporting range and rebuilds. Generated OpenAPI/contracts, client, documentation and all required bounds checks pass.


## Surprises & Discoveries

The rich resolved relations already include organization_id, so migration 0025 only
extends the public projections. The ordinary funnel already uses attribution for property
selection; the organisation values must coexist with first_touch/last_touch/step values.
The initial native run caught ClickHouse aggregate aliases shadowing raw organization_id;
qualifying source columns preserves the intended state type. The shared shorthand parser
also needed org added alongside user and prop.


## Decision Log

- Decision: Extend the frozen `events_resolved` contract from seven to eight columns by
  appending `organization_id`, and update ADR 4 in the same change.
  Rationale: Organisation aggregation must run on the identity-resolved path so a user's
  pre-login events count for the organisation they later join; appending keeps every existing
  consumer valid.
  Date: 2026-10-15
- Decision: An organisation "did" an event when any of its users did; organisation funnels
  and retention run the existing builders with `organization_id` as the aggregation key.
  Rationale: This is PostHog's and Amplitude's definition and reuses the engines unchanged.
  Date: 2026-10-15
- Decision: Organisation properties use the EP-40 pattern: an `AggregatingMergeTree` with
  `argMax` states fed by `group` events, current value at query time.
  Rationale: One trait model for people and organisations.
  Date: 2026-10-15


- Decision: Use typed trait values and the total ordering (occurred_at, received_at,
  event_id), matching the implemented person-trait model rather than timestamp-only String
  states. Reuse first-acceptance eligibility for group v2; group v1 stays context-only.
  Rationale: Seats needs numeric comparisons, and equal-timestamp writes must have a
  deterministic replay-safe winner. Date: 2026-10-16.
- Decision: Preserve the ordinary funnel's existing property attribution values. The new
  event/user_organization values select organisation attribution with first-touch property
  selection; experiment funnels retain their existing attribution type.
  Rationale: The parameter name is already released. Date: 2026-10-16.
- Decision: Current membership records any explicit nonempty user/organisation group binding,
  including group v1; only group v2 writes governed traits. Membership fallback applies
  only to resolved user subjects and only when the event organisation is empty.
  Rationale: Existing context-only SDK producers already establish membership without
  granting legacy properties trait eligibility. Date: 2026-10-16.
- Decision: Include both new aggregate tables in the current-definition administrative
  rebuild. Whole-session/acquisition sources reject organisation dimensions because this
  plan defines event-level organisation attribution only. Date: 2026-10-16.


## Outcomes & Retrospective

All four milestones are implemented. The owned organisation gate builds the repository,
runs five non-pending native/schema cases and exercises ordinary public ingest/reporting
against private PostgreSQL/ClickHouse and the built server. It verifies immutable replay,
member timelines, retention, current typed traits, attribution, account isolation, invalid
options and permanent error codes. The original conservative identity proof passes all
20 expected subjects, cached/direct parity and repeated rebuilds; both native cache lifecycle
cases pass. Deterministic coverage passes 380 core examples, 21 client examples and four
production probes. Generated contracts/OpenAPI checks, OpenAPI lint, formatting and strict
ADR validation pass.

The source adapter lets the existing engines share organisation populations without changing
their event ordering or ratio rules. The main integration lessons were preserving person
selectors before aggregation, qualifying ClickHouse aggregate inputs, and respecting the
released funnel attribution namespace. Durable decisions are recorded in
[ADR-21](../adr/0021-organization-aggregation-and-current-membership.md), with the view,
schema and reader records updated consistently. Current traits and membership deliberately
reclassify historical queries. Organisation erasure is a fenced manual runbook operation;
this plan does not add a public organisation-deletion command. No milestone remains open.


## Context and Orientation

`AnalyticsEvent` carries an optional top-level `organizationId`
(`kansoku-api/src/Kansoku/Event/Types.hs`), stored as `events_raw.organization_id`
(`String DEFAULT ''`, `db/clickhouse/migrations/0004_events_raw_v2.sql`). Both SDKs set it
through `group`: the Haskell client in `kansoku-client/src/Kansoku/Client.hs` and the browser
SDK (`mori://shinzui/kansoku-ts`, project-relative `packages/kansoku-js/src/identity-api.ts`;
code artifact URI pending), which persists
the organisation and stamps it on subsequent events. The `group` event is declared by
`docs/plans/29-correct-client-timestamp-skew-and-count-ingest-rejections.md`. The
identity-resolved view `analytics.events_resolved` now has an eight-column contract with
its original seven-column prefix preserved
([ADR 4](../adr/0004-queryable-event-properties-and-identity-resolved-projection.md)) that does
not include the organisation; `docs/plans/32-time-aware-identity-bindings-and-bounded-resolution-cost.md`
rewrites the view's internals, so this plan's column addition must be coordinated with it.
The `organizations` route in `kansoku-api/src/Kansoku/Metrics/Api.hs` carries the standard
`MetricQuery` parameters and returns 404 `not_implemented`. Person properties and the
`user:` dimension pattern come from
`docs/plans/40-person-properties-set-and-set-once-user-traits.md`; filters from
`docs/plans/31-metric-property-filters-and-dual-grouping.md`; bounds from
[ADR 9](../adr/0009-bounded-complete-aggregate-responses.md). The implementation decisions are in
[ADR-21](../adr/0021-organization-aggregation-and-current-membership.md). No cross-repository ADR applies.


## Plan of Work

### M1: View contract and active organisations

Add a migration recreating `analytics.events_resolved` with `organization_id` appended as the
eighth column (preserving the first seven exactly), and update ADR 4. Implement
`/metrics/organizations`: per bucket, `uniqExact(organization_id)` over events with a
non-empty organisation, with `filter`, `groupBy` (including `event_name`, `source_service`,
`prop:` and, after M3, `org:`), and `timeGrain`. Add `organization` as a built-in filter
dimension so a single organisation can be inspected (`filter=organization:eq:<id>`).

### M2: Organisation aggregation

Add `aggregate=users|organizations` (default `users`) to users, funnel, retention, conversion
and feature-adoption. Under `organizations`, the builders group by `organization_id` instead
of `canonical_user` and ignore rows with an empty organisation; funnels evaluate step order
over the organisation's merged event stream; retention cohorts are organisations by first
activity. Rollup fast paths are bypassed. Document that experiment endpoints keep user
aggregation.

### M3: Organisation properties

Add `analytics.organization_properties` with account/organisation/name keys and typed
argMax states ordered by (occurred_at, received_at, event_id) fed by a materialized view over
`group` events with a non-empty organisation, and a view `organization_traits`. Declare the
initial optional traits on `group` version 2 (`plan`, `seats`, `industry`, `country`) under
ADR 7, and add the `org:<name>` dimension to filters and grouping with the same join shape as
`user:`. Extend the erasure runbook with organisation-level deletion.

### M4: User-to-organisation attribution

Add `analytics.user_organizations` (`account_id, user_id, organization_id` by `argMax` over
`group` events) and `attribution=event|user_organization` (default `event`) on organisation
aggregation: under `user_organization`, an event without an organisation takes its canonical
user's current organisation. Document the current-value caveat exactly as EP-40 does for
traits. Regenerate OpenAPI and the client and document everything in the query guide
("Organisations").


## Concrete Steps

```bash
nix develop -c cabal build all --enable-tests
nix develop -c python3 scripts/organizations_acceptance.py
nix develop -c python3 scripts/identity_acceptance.py
nix develop -c python3 scripts/deterministic-tests.py
nix develop -c just contracts
nix develop -c just openapi
nix develop -c just contracts-check
nix develop -c just openapi-check
```

Example:

```bash
curl -s --get http://localhost:8080/metrics/funnel -H "Authorization: Bearer $TOKEN" \
  --data-urlencode from=2026-07-01 --data-urlencode to=2026-08-01 \
  --data-urlencode steps=workspace_created,invitation_accepted,document_created --data-urlencode aggregate=organizations
```


## Validation and Acceptance

1. M1: the view's first seven columns are byte-identical in name and order to ADR 4's list
   and all existing identity batteries pass; active organisations over fixtures with two
   organisations and three users equals 2; `filter=organization:eq:` narrows to one.
2. M2: a funnel where organisation A's users complete steps across different people reaches
   the last step once under `organizations` and twice under `users`; organisation retention
   counts A as retained when any member returns.
3. M3: `group` with `plan=enterprise` then `plan=pro` resolves to `pro`;
   `groupBy=org:plan` on revenue splits by organisation plan.
4. M4: a browser `page_view` without an organisation counts for its user's organisation only
   under `user_organization`.
5. Point cap, account predicate test and codes hold. The owned organisation gate runs
   nonzero native examples with no pending tests, then drives public ingest/reporting over
   private PostgreSQL/ClickHouse and the built server. Deterministic tests separately
   validate routing, client signatures, schema eligibility and compiler rejection paths.


## Idempotence and Recovery

View recreation is additive in columns; the previous definition is kept as a comment in the
migration for rollback. New tables and views are replay-safe aggregate states. The migration ledger skips already
applied filenames; retrying 0025 after partial DDL is safe because repeated argMax backfill
states cannot change winners. Ordinary maintenance uses current materialized-view definitions,
including the new organisation tables. The runbook documents fenced source deletion and
membership rebuild; do not erase only an aggregate row or replay old migrations as recovery.


## Interfaces and Dependencies

Hard dependencies: `docs/plans/26-bound-analytics-query-inputs-and-result-cardinality.md`
and `docs/plans/31-metric-property-filters-and-dual-grouping.md` Complete. Soft:
`docs/plans/32-time-aware-identity-bindings-and-bounded-resolution-cost.md` (coordinate the
view rewrite), `docs/plans/40-person-properties-set-and-set-once-user-traits.md` (trait
pattern), `docs/plans/36-funnel-modes-and-experiment-exposure-diagnostics.md` (array engine
for organisation funnels if exclusions are wanted). Claims the eighth view column, the
`aggregate` and `attribution` parameters, the `organization` and `org:` dimensions, `group`
version 2, and the `organization_properties` and `user_organizations` objects.

Revision note (2026-10-16): Align the implementation with landed typed person traits,
first-acceptance eligibility and deterministic ordering; reconcile the released funnel
attribution parameter and current-definition administrative rebuilds. Acceptance remains
the four original organisation outcomes.
