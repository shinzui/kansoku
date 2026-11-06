---
type: Improvement Request
title: Count unique users over a whole query range
description: Let the users, custom unique_count and acquisition users measures return one unbucketed answer per group for the whole from..to range, so a consumer can show exact visitors for a period instead of summing daily buckets that count returning users more than once.
generated:
  by: process:codex
  at: "2026-11-06T04:07:22Z"
requestId: IR-4
status: accepted
targetPlan: docs/plans/60-count-unique-users-over-a-whole-query-range.md
origin: mori://shinzui/kansoku-ui
acceptanceCriteria:
  - id: AC-1
    statement: /metrics/users, /metrics/custom with aggregation unique_count, and /metrics/acquisition with measure=users each accept a documented way to request one unbucketed answer for the whole range, returned as points whose bucket is null.
    verification: Query each route for a 30-day range with a user active on several days and assert one point with bucket null whose value counts that user once.
  - id: AC-2
    statement: The unbucketed answer composes with groupBy (one or two dimensions, including route, channel, country_code, device_class, entry_page and user traits) and with filters, cohorts and includeBots exactly as the bucketed answer does.
    verification: Compare grouped unbucketed answers with an independent distinct count over the same resolved identities in the integration suite.
  - id: AC-3
    statement: Existing requests keep their meaning; omitting timeGrain still means day buckets on routes where it does today.
    verification: Existing route and golden tests pass unchanged.
  - id: AC-4
    statement: The query guide and OpenAPI document the new grain value, which routes accept it, and that it is the correct way to count users over a period.
    verification: Read docs/guides/query-metrics.md and docs/api/openapi.json.
reviews:
  - kind: model
    reviewer: process:claude-code
    reviewed_at: "2026-11-05T21:06:04Z"
    document_timestamp: "2026-11-05T21:06:04Z"
    scope: content-and-metadata
    outcome: commented
    provider: anthropic
    model: claude-opus-5-5
    effort: unspecified
    context: >-
      Author review against kansoku aaf84df (Query.hs effectiveGrain, Custom.hs, the query guide
      and OpenAPI enums), while comparing a reports page in an open-source analytics product with
      what mori://shinzui/kansoku-ui can build. No independent verification attestation is claimed.
---

# Count unique users over a whole query range

**Authored by:** a `claude-code` session in `mori://shinzui/kansoku-ui`, planning a Reports page.
**Addressed to:** `shinzui/kansoku` agents.
**Created:** 2026-11-05.

This is part of the set filed with IR-5, IR-6, IR-7 and IR-8 for kansoku-ui's Reports page.

**Implementation plan:** [ExecPlan 60: Count unique users over a whole query range](../plans/60-count-unique-users-over-a-whole-query-range.md).
The request is accepted for implementation; implementation has not started.


## Why

A web report leads with "visitors in this period": the distinct people seen between `from` and
`to`, next to page views and sessions. Kansoku cannot answer it. Every route that counts users is
bucketed:

- `effectiveGrain` in `kansoku-core/src/Kansoku/Metrics/Query.hs` returns
  `requestedGrain <|> defaultGrain <|> Just Day`, so a simple custom `unique_count` with no
  `timeGrain` is daily.
- The OpenAPI `timeGrain` enum on `/metrics/users`, `/metrics/custom` and `/metrics/acquisition`
  is `hour | day | week | month`.
- The only unbucketed custom answer is a ratio, which returns a fraction, not a count.

Page views and sessions can be summed across buckets because each event or session falls in one
bucket. Users cannot: someone active on twelve days is counted twelve times. `timeGrain=month`
only works when the range is one calendar month. The same gap affects per-row "visitors" in
tables of pages, countries, devices, channels and landing pages.


## What is asked

Add a grain value, for example `timeGrain=none`, that returns one point per group with
`bucket: null` (the response contract already allows a null bucket). Accept it at least on
`/metrics/users` (calendar window), `/metrics/custom` for `count`, `unique_count`, `sum` and
`average`, and `/metrics/acquisition` with `measure=users`. Accepting it on the additive routes too
(`page-views`, `events`, `sessions`) would let a consumer use one shape for every figure on a page.
Kansoku chooses the name.


## Not requested

Approximate counts, or changing the default grain of any route.
