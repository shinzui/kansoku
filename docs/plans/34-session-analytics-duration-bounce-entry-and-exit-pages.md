---
id: 34
slug: session-analytics-duration-bounce-entry-and-exit-pages
title: "Session analytics: duration, bounce, entry and exit pages"
kind: exec-plan
created_at: 2026-10-15T13:44:34Z
intention: "intention_01m4zwwdrjesytazp5tb39fe3n"
master_plan: "docs/masterplans/5-act-on-rev-1-close-silent-loss-paths-add-metric-filters-and-enrich-web-analytics.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-15T13:44:34Z
---

# Session analytics: duration, bounce, entry and exit pages

This ExecPlan is a living document. Update its living sections and durable ADRs as work
proceeds. It is a child of
`docs/masterplans/5-act-on-rev-1-close-silent-loss-paths-add-metric-filters-and-enrich-web-analytics.md`
and acts on findings E4 (part 5) and E7 of
`docs/reviews/2026-10-15-architecture-and-feature-set-against-comparable-products.md`.


## Purpose / Big Picture

`GET /metrics/sessions` will answer the questions every web-analytics dashboard shows next to
a session count: how long sessions last, what share bounce, and which pages they enter and
leave on. A session will be attributed to the bucket in which it started, so a visit spanning
midnight counts once.


## Progress

- [ ] M1: `analytics.sessions` is maintained by a materialized view from `events_raw` and agrees with a raw recount over the fixtures.
- [ ] M2: `/metrics/sessions` accepts `measure=count|bounce_rate|average_duration_seconds` and `groupBy` of `entry_route`, `exit_route` or `channel`, attributed by session start.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: A bounce is a session whose events are `session_start` plus at most one
  `page_view` and nothing else; duration is last event minus first event, zero for bounces.
  Rationale: Plausible, Umami, Matomo and Rybbit all define bounce as a single-interaction
  visit; the definition is stated so dashboards built on ClickHouse can match it.
  Date: 2026-10-15
- Decision: Session rollups use raw identity and the producer session id; no identity
  resolution.
  Rationale: Sessions are device-scoped by construction; stitching adds cost without changing
  the answer.
  Date: 2026-10-15


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

The browser SDK (`mori://shinzui/kansoku-ts`, `packages/kansoku-js/src/session.ts`)
generates a session id, rotates it after 30 minutes of inactivity (`sessionTimeoutMs`
default 1800000 in `client.ts`), emits `session_start` and stamps every event's `sessionId`.
The server stores it in `events_raw.session_id`. Today `buildSessionsSQLAggregate` in
`kansoku-core/src/Kansoku/Metrics/Query.hs` counts distinct non-empty session ids per bucket
of event time, so a session spanning two buckets counts in both (REV-1 E7). Rollups are
`AggregatingMergeTree` tables fed by materialized views
(`db/clickhouse/migrations/0006_rollups_v2.sql`); the account dimension leads every rollup key
([ADR 3](../adr/0003-api-key-authentication-and-account-scoped-analytics.md)). Metric routes
and bounds follow [ADR 9](../adr/0009-bounded-complete-aggregate-responses.md). If
`docs/plans/33-acquisition-and-device-enrichment-with-bot-flagging.md` has landed, `events_raw`
also carries `channel` and `is_bot`; this plan uses them when present and otherwise omits the
channel dimension and bot exclusion.


## Plan of Work

### M1: Session rollup

Add a migration (next unclaimed number) creating `analytics.sessions` as an
`AggregatingMergeTree` ordered by `(account_id, start_day, session_id)` with aggregate states:
`min(occurred_at)` and `max(occurred_at)`, `count()` events, `countIf(event_name = 'page_view')`
page views, `argMin(path(url), occurred_at)` entry route, `argMax(path(url), occurred_at)` exit
route, and, when the columns exist, `any(channel)` and `max(is_bot)`. Feed it with
`mv_sessions` over `events_raw WHERE session_id != ''`, keying `start_day` as
`toDate(min(occurred_at))` per session. Backfill from existing rows in the migration using the
same select, as `0014_experiment_exposures.sql` does for exposures. Because a session's events
arrive across several inserts, the start day stored by each partial state is the minimum seen
so far; the query path merges by session id and recomputes the start bucket from the merged
minimum, so partial states never produce a second row in results.

### M2: Measures and dimensions

Extend the sessions route with `measure` (default `count`) and `groupBy` values `entry_route`,
`exit_route`, `channel`. Compute per bucket of start time: `count` is distinct sessions,
`bounce_rate` is bounces divided by sessions (0 when none), `average_duration_seconds` is the
mean of `max - min` over non-bounce sessions. Exclude `is_bot = 1` sessions when the column
exists unless `includeBots=true`. Keep the old event-time counting available as
`attribution=event` for one release and document the change in `docs/guides/query-metrics.md`.
Regenerate OpenAPI and the client.


## Concrete Steps

Inside `nix develop` with the stack running:

```bash
just ch-migrate
cabal test kansoku-core --test-options='--match "Sessions"'
just openapi && just openapi-check
```

Example:

```bash
curl -s --get http://localhost:8080/metrics/sessions -H "Authorization: Bearer $TOKEN" \
  --data-urlencode from=2026-07-01 --data-urlencode to=2026-08-01 \
  --data-urlencode measure=bounce_rate --data-urlencode groupBy=entry_route
```


## Validation and Acceptance

1. M1: for the fixtures, `uniqExact(session_id)` from the rollup equals the raw count; a
   session inserted in two batches yields one merged row with the earlier minimum.
2. M2: a fixture session with only `session_start` and one `page_view` counts as a bounce; one
   with two page views has duration equal to their difference; a session crossing midnight
   counts once, in its start day; `groupBy=entry_route` lists the first page's route.
3. The account-predicate completeness test covers the new builder; the point cap applies.


## Idempotence and Recovery

The migration is additive and its backfill is re-runnable because aggregate states merge.
Dropping the view and table restores the previous behaviour; `attribution=event` keeps the old
numbers reachable during the transition.


## Interfaces and Dependencies

Soft dependency on `docs/plans/33-acquisition-and-device-enrichment-with-bot-flagging.md`
for `channel` and `is_bot`. Hard dependency on
`docs/plans/26-bound-analytics-query-inputs-and-result-cardinality.md` Complete (bounded
execution). Claims the `analytics.sessions` table and `mv_sessions` view. Update ADR 2's
rollup inventory, or the enrichment ADR from EP-33, with the session definitions.
