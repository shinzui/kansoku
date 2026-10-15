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

- [ ] M1: `analytics.events_resolved` exposes `organization_id` as an eighth column and `GET /metrics/organizations` returns active organisations per bucket with filters and grouping.
- [ ] M2: `aggregate=organizations` on users, funnel, retention, conversion and feature-adoption counts organisations instead of users.
- [ ] M3: Organisation properties from `group` events are stored and usable as `org:<name>` dimensions.
- [ ] M4: Events without an organisation can be attributed to their user's current organisation with `attribution=user_organization`.


## Surprises & Discoveries

(None yet.)


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


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

`AnalyticsEvent` carries an optional top-level `organizationId`
(`kansoku-api/src/Kansoku/Event/Types.hs`), stored as `events_raw.organization_id`
(`String DEFAULT ''`, `db/clickhouse/migrations/0004_events_raw_v2.sql`). Both SDKs set it
through `group`: the Haskell client in `kansoku-client/src/Kansoku/Client.hs` and the browser
SDK (`mori://shinzui/kansoku-ts`, `packages/kansoku-js/src/identity-api.ts`), which persists
the organisation and stamps it on subsequent events. The `group` event is declared by
`docs/plans/29-correct-client-timestamp-skew-and-count-ingest-rejections.md`. The
identity-resolved view `analytics.events_resolved` has a frozen seven-column contract
([ADR 4](../adr/0004-queryable-event-properties-and-identity-resolved-projection.md)) that does
not include the organisation; `docs/plans/32-time-aware-identity-bindings-and-bounded-resolution-cost.md`
rewrites the view's internals, so this plan's column addition must be coordinated with it.
The `organizations` route in `kansoku-api/src/Kansoku/Metrics/Api.hs` carries the standard
`MetricQuery` parameters and returns 404 `not_implemented`. Person properties and the
`user:` dimension pattern come from
`docs/plans/40-person-properties-set-and-set-once-user-traits.md`; filters from
`docs/plans/31-metric-property-filters-and-dual-grouping.md`; bounds from
[ADR 9](../adr/0009-bounded-complete-aggregate-responses.md). No cross-repository ADR applies.


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

Add `analytics.organization_properties` (`account_id, organization_id, name, value
AggregateFunction(argMax, String, DateTime64(3,'UTC'))`) fed by a materialized view over
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
just ch-migrate
cabal test kansoku-core --test-options='--match "Organization"'
just contracts && just openapi && just contracts-check && just openapi-check
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
5. Point cap, account predicate test and codes hold.


## Idempotence and Recovery

View recreation is additive in columns; the previous definition is kept as a comment in the
migration for rollback. New tables and views are replay-safe aggregate states.


## Interfaces and Dependencies

Hard dependencies: `docs/plans/26-bound-analytics-query-inputs-and-result-cardinality.md`
and `docs/plans/31-metric-property-filters-and-dual-grouping.md` Complete. Soft:
`docs/plans/32-time-aware-identity-bindings-and-bounded-resolution-cost.md` (coordinate the
view rewrite), `docs/plans/40-person-properties-set-and-set-once-user-traits.md` (trait
pattern), `docs/plans/36-funnel-modes-and-experiment-exposure-diagnostics.md` (array engine
for organisation funnels if exclusions are wanted). Claims the eighth view column, the
`aggregate` and `attribution` parameters, the `organization` and `org:` dimensions, `group`
version 2, and the `organization_properties` and `user_organizations` objects.
