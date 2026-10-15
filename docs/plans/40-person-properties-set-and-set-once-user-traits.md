---
id: 40
slug: person-properties-set-and-set-once-user-traits
title: "Person properties: set and set-once user traits"
kind: exec-plan
created_at: 2026-10-15T14:22:40Z
intention: "intention_01m4zwwdrjesytazp5tb39fe3n"
master_plan: "docs/masterplans/5-act-on-rev-1-close-silent-loss-paths-add-metric-filters-and-enrich-web-analytics.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-15T14:22:40Z
---

# Person properties: set and set-once user traits

This ExecPlan is a living document. Update its living sections and durable ADRs as work
proceeds. It is a child of
`docs/masterplans/5-act-on-rev-1-close-silent-loss-paths-add-metric-filters-and-enrich-web-analytics.md`
and acts on the person-properties half of finding E6 in
`docs/reviews/2026-10-15-architecture-and-feature-set-against-comparable-products.md`,
promoted into scope on 2026-10-15 (MasterPlan Decision Log).


## Purpose / Big Picture

Questions about who did something, in terms the browser does not know, will become
answerable over browser traffic: which documentation pages enterprise customers read, the
onboarding funnel for companies with more than fifty seats, retention of users who arrived
from the newsletter, revenue by billing country, experiment conversion among free-plan users.
A backend states a user's traits once with `identify` ("set", newest value wins) or
`identify_once` ("set-once", first value wins, for traits such as `signup_source` and
`initial_plan` that must never be overwritten), and every metric route can then filter or
group by `user:<name>`. Values are the user's current traits at query time; recording the
trait as of each event is a later option, and backend producers that need it keep stamping
traits onto their own events.


## Progress

- [ ] M1: `analytics.user_properties` and `analytics.user_properties_once` are populated from `identify` and `identify_once` events, with newest-wins and first-wins semantics proven on fixtures, ordered by corrected event time.
- [ ] M2: `user:<name>` works in `filter=` and `groupBy=` on every route that reads the identity-resolved view, with declared-trait enforcement through `identify` schema versions.
- [ ] M3: Both SDKs expose `identifyOnce`, the guides document traits, and erasure removes a user's trait rows.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Current-value semantics first. Traits are joined at query time by canonical user;
  a snapshot-at-event-time model (writing traits onto every event at ingest) is deferred.
  Rationale: Chosen on 2026-10-15 in discussion; the snapshot model changes the write path and
  the raw table and is a much larger plan, while set-once traits cover the historical questions
  that matter most.
  Date: 2026-10-15
- Decision: Two declared events rather than reserved keys inside one event. `identify`
  properties are "set"; a new `identify_once` event's properties are "set-once".
  Rationale: Kansoku's property names are validated against a strict charset and declared
  schemas, so `$set`-style reserved keys do not fit; two events keep the catalog honest and
  give both SDKs an obvious helper.
  Date: 2026-10-15
- Decision: Trait names are declared through new `identify` and `identify_once` schema
  versions, and only declared traits compile into `user:` dimensions.
  Rationale: Keeps ADR 4's compile boundary; a deployment adds traits the way it adds event
  properties, under ADR 7 versioning.
  Date: 2026-10-15
- Decision: Order trait writes by the event's `occurredAt` after EP-29 skew correction, with
  `receivedAt` as the tie-break.
  Rationale: Out-of-order delivery should resolve to the latest trait, not the last to arrive.
  Date: 2026-10-15


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

The only user-level data Kansoku stores today lives on events: an `identify` event
(declared in `kansoku-api/src/Kansoku/Event/Registry.hs` as version 1 with no properties)
carries traits inside its `properties`, and nothing records a user's current traits.
Metrics group and filter by event properties only, through the declared-property rule and
`getSubcolumn(properties_json, …)` expressions of
[ADR 4](../adr/0004-queryable-event-properties-and-identity-resolved-projection.md); the
`filter` grammar and `prop:` prefix come from
`docs/plans/31-metric-property-filters-and-dual-grouping.md`. Exact metrics read
`analytics.events_resolved`, whose `canonical_user` is the explicit `user_id` or the
identity-resolved user ([ADR 5](../adr/0005-evidence-based-multi-signal-identity-resolution.md));
anonymous users therefore have no traits, which is correct. Rollups are `AggregatingMergeTree`
tables fed by materialized views (`db/clickhouse/migrations/0006_rollups_v2.sql`); aggregate
states merge safely under at-least-once replay. Schema versions are immutable and additive
([ADR 7](../adr/0007-versioned-event-schema-governance-and-publication.md)). Erasure is the
runbook `docs/runbooks/identity-data-deletion.md`, which
`docs/plans/37-administrative-executable-for-keys-erasure-retention-and-replay.md` turns into
a command. The Haskell SDK's `identify` helper is in `kansoku-client/src/Kansoku/Client.hs`;
the browser SDK's is in `mori://shinzui/kansoku-ts` at `packages/kansoku-js/src/identity-api.ts`.

A "trait" is a property of a person rather than of an event: plan, company size, signup
source, country, role. "Set" means the newest value replaces the old; "set-once" means the
first value stays. No cross-repository ADR applies.


## Plan of Work

### M1: Storage

Add a migration (next unclaimed number) creating `analytics.user_properties`
(`account_id String, user_id String, name LowCardinality(String), value AggregateFunction(argMax, String, DateTime64(3, 'UTC'))`)
and `analytics.user_properties_once` (same key, `argMin` state), both `AggregatingMergeTree`
ordered by `(account_id, user_id, name)`. Feed them with materialized views over `events_raw`
for `event_name = 'identify'` and `'identify_once'` with `user_id != ''`, array-joining
`JSONExtractKeysAndValuesRaw(properties)` so each trait becomes one row, using `occurred_at`
as the ordering time (EP-29 corrects it at ingest; if EP-29 has not landed, note the
limitation) and storing values as JSON text so numbers and strings survive. Add a view
`analytics.user_traits` that merges both tables with set-once winning over set for the same
name only when the set table has no value, exposing `account_id, user_id, name, value`.
Backfill from existing `identify` rows in the migration.

### M2: Dimension

Extend the filter and group-by grammar from EP-31 with the `user:<name>` prefix. Compile it
only when the latest `identify` or `identify_once` schema declares `<name>` (add version 2 of
`identify` and version 1 of `identify_once` with an initial optional trait set: `plan`,
`signup_source`, `initial_plan`, `company_size`, `country`, `role`; deployments add more by
new versions). In `Query.hs`, a `user:` dimension forces the identity-resolved path and adds
one `LEFT JOIN analytics.user_traits AS t_<n> ON t_<n>.account_id = account_id AND t_<n>.user_id = canonical_user AND t_<n>.name = {trait_n}` per referenced trait, with the value cast for numeric operators. Document the join cost and
that rollup fast paths are bypassed.

### M3: SDKs, docs and erasure

Add `identifyOnce` to the Haskell client; specify the matching browser helper for the
kansoku-ts repository. Update `docs/guides/send-events.md` ("Traits") and
`docs/guides/query-metrics.md` ("User traits") with the semantics, including that values are
current at query time. Extend the erasure runbook and the `erase-user` command with
`ALTER TABLE … DELETE` on both trait tables for the account and user. Regenerate the catalog
and OpenAPI.


## Concrete Steps

```bash
just ch-migrate
cabal test kansoku-core --test-options='--match "Traits"'
just contracts && just openapi && just contracts-check && just openapi-check
```

Example:

```bash
curl -s --get http://localhost:8080/metrics/page-views -H "Authorization: Bearer $TOKEN" \
  --data-urlencode from=2026-07-01 --data-urlencode to=2026-08-01 \
  --data-urlencode 'filter=user:plan:eq:enterprise' --data-urlencode groupBy=route
```


## Validation and Acceptance

1. M1: two `identify` events for one user with `plan` values in reverse arrival order resolve
   to the later `occurredAt`; `identify_once` keeps the first `signup_source`; replaying an
   insert changes nothing.
2. M2: page views filtered by `user:plan:eq:enterprise` count only events whose canonical user
   currently has that plan, including anonymous events stitched to that user; an undeclared
   trait returns 400 `invalid_filter`; `groupBy=user:plan` on revenue yields one point per plan.
3. M3: after `erase-user`, no trait rows remain for the user; the catalog lists `identify_once`
   and `identify` version 2; the account-predicate completeness test covers the new joins.


## Idempotence and Recovery

Additive tables and views with replay-safe states; the backfill is re-runnable. Removing the
feature is dropping the views and tables; the events remain the source of truth.


## Interfaces and Dependencies

Hard dependencies: `docs/plans/26-bound-analytics-query-inputs-and-result-cardinality.md`
Complete and `docs/plans/31-metric-property-filters-and-dual-grouping.md` Complete (the
grammar this extends). Soft dependencies:
`docs/plans/29-correct-client-timestamp-skew-and-count-ingest-rejections.md` (ordering),
`docs/plans/32-time-aware-identity-bindings-and-bounded-resolution-cost.md` (resolution cost),
`docs/plans/37-administrative-executable-for-keys-erasure-retention-and-replay.md` (erasure
command). Claims the `user:` dimension prefix, the `identify_once` event, `identify` version
2, and the `analytics.user_properties`, `user_properties_once` and `user_traits` objects.
Update ADR 4 with the trait dimension and the current-value semantics.
