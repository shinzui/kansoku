---
type: Improvement Request
title: Measure retention by week or month with separate start and return events
description: Let /metrics/retention form cohorts by UTC ISO week or calendar month with offsets in that unit, and take a start event and a return event each with its own filters beside the shared filters, so a consumer can answer "of the people who signed up each week, how many came back to create a document in each later week" exactly.
generated:
  by: process:claude-code
  at: "2026-11-13T05:30:00Z"
requestId: IR-20
status: completed
completedAt: "2026-11-13T14:27:06Z"
resolution: >-
  AC-1 through AC-5 delivered by plan 70: exact UTC day/week/month cohorts,
  independent start/return event selections and filters, aligned period starts,
  complete-period maturity, existing population and resource bounds, typed clients,
  generated/served OpenAPI and query guidance. Deterministic, owned native/public
  and full Nix-packaged acceptance pass on Darwin arm64.
targetPlan: docs/plans/70-measure-retention-by-calendar-period-with-separate-start-and-return-events.md
timestamp: "2026-11-13T14:27:06Z"
origin: mori://shinzui/kansoku-ui/plans/36-analyse-retention-by-daily-weekly-or-monthly-cohorts-with-start-and-return-events
acceptanceCriteria:
  - id: AC-1
    statement: /metrics/retention accepts a period of day, week or month, defaulting to day with today's behaviour unchanged. With week or month, a cohort is the subjects whose first matching start activity falls in one UTC ISO week (Monday to Sunday) or one UTC calendar month, the cohort label is the period's first day as YYYY-MM-DD, and offsets count periods. Offsets are at most 32 distinct values in 1..365 for days, 1..52 for weeks and 1..12 for months.
    verification: Public HTTP tests over a seeded account compare weekly and monthly answers with hand-computed counts, including a subject active on several days of one week counted once, and reject an offset above each period's bound with a 400 problem.
  - id: AC-2
    statement: For week and month, from must be the first day of a period, otherwise a 400 problem with a documented code. to keeps the closed-day rule. The last cohort may be partial, counting first activity up to to. Offset N is emitted only when the whole period cohort+N has closed by to; mode=on counts any activity in period cohort+N, and on_or_after counts any activity from the start of period cohort+N through the end of period cohort+largest requested offset. Offset 0 is always the cohort size, and a mature missing return is zero.
    verification: Tests at period boundaries, including a month whose last day is the day before to and one that is not closed, an unaligned from, and on_or_after with a partly closed horizon.
  - id: AC-3
    statement: Optional startEvent and returnEvent name the event that puts a subject in a cohort and the event that counts as a return; when absent each means any matching activity, as today. Repeatable startFilter and returnFilter use the filter grammar and apply only to their side's activity, while filter still applies to both. Kansoku documents whether subject-level terms (cohort membership, user and organization traits) are accepted in a side filter and rejects them with a 400 problem if not. cohort=lifetime uses first matching start activity in retained history.
    verification: Seed subjects who sign up and later create documents, others who only sign up, and others who create documents without signing up in range; assert sizes count only sign-ups, returns count only document creation, and side filters narrow only their side.
  - id: AC-4
    statement: groupBy, aggregate=organizations, includeBots, the existing budgets, the 10000 complete-point bound and the omission of immature offsets apply unchanged to period and event-pair queries, and the query guide states which side's activity supplies event-level group values.
    verification: Grouped weekly answers with a start and return event pass the same population checks as daily ones; an over-large weekly request returns the documented resource or point-limit problem.
  - id: AC-5
    statement: The OpenAPI document, the query guide's Retention section and the typed Haskell client describe the new parameters, bounds, period alignment, maturity rule and labels.
    verification: Review the served OpenAPI document, the guide and the client module.
reviews:
  - kind: model
    reviewer: process:codex
    reviewed_at: "2026-11-13T13:52:04Z"
    document_timestamp: "2026-11-13T13:51:22Z"
    scope: content-and-metadata
    outcome: commented
    provider: openai
    model: gpt-6.1-sol
    effort: unspecified
    context: >-
      Verified the targetPlan and readable implementation link resolve to ExecPlan 70,
      the plan links back to IR-20, and all five acceptance criteria are referenced.
      This linkage check does not attest implementation or runtime acceptance.
---

# Measure retention by week or month with separate start and return events

**Authored by:** a `claude-code` session in `mori://shinzui/kansoku-ui`, planning cohort analysis
for its Retention tab
(`mori://shinzui/kansoku-ui/plans/36-analyse-retention-by-daily-weekly-or-monthly-cohorts-with-start-and-return-events`,
a child of `mori://shinzui/kansoku-ui/masterplans/7-build-the-insights-library-of-saved-analyses`).
**Addressed to:** `shinzui/kansoku` agents.
**Created:** 2026-11-12.

**Implementation plan:** [ExecPlan 70: Measure retention by calendar period with separate start and return events](../plans/70-measure-retention-by-calendar-period-with-separate-start-and-return-events.md).
Implementation is complete; all five criteria are verified by the evidence below.


## Why

kansoku-ui is turning its Retention tab into a cohort analysis, modelled on an open-source
analytics product: "first did `signup_completed`, came back and did `document_created`, measured
in weeks over 7 periods". The answer is a triangular table with one row per weekly cohort, a
People column, an average row and a curve.

Today's /metrics/retention answers daily cohorts with day offsets, and one set of filters defines
both the activity that puts a subject in a cohort and the activity that counts as a return. Two
things therefore cannot be expressed:

- **Weekly or monthly cohorts.** A consumer cannot build them from daily answers. A subject active
  on three days of week 2 must count once, and summing daily offsets counts them three times.
  Daily cohorts that began on different weekdays also do not align with week boundaries. The
  consumer refuses to combine exact unique counts across days, so only Kansoku can answer this.
- **Different start and return activity.** `event_name:eq:signup_completed` today means "signed
  up, then signed up again". The useful question is "signed up, then created a document".


## Requested change

Extend /metrics/retention. Kansoku chooses the final parameter names and problem codes. The
consumer's proposal, which it builds against a fake until this is delivered, is:

- `period=day|week|month`, defaulting to `day`. The existing `days` list is read as offsets in the
  period's units; a unit-neutral alias such as `offsets` is welcome. Weeks are ISO weeks starting
  Monday, in UTC. Cohort labels stay in `group.cohort` as the period's first day, so the response
  shape does not change.
- For week and month, an unaligned `from` is rejected (for example `invalid_retention_period`)
  rather than silently moved, so the answer's first cohort is never a hidden partial period.
- `startEvent` and `returnEvent`, one event name each.
- Repeatable `startFilter` and `returnFilter` with the `filter` grammar, each applied only to its
  side's activity.

Day-period requests that send none of the new parameters must answer exactly as today, because
the consumer sends `period` only when it is not `day`.


## Notes

Not requested: a first-ever cohort beyond retained history (the existing lifetime rule stands),
Sunday-start weeks or time zones other than UTC, unbounded or "unbounded return" retention, and a
summary or average row computed by Kansoku. The consumer derives the average as retained subjects
summed over the cohorts that have an offset, divided by those cohorts' sizes. That is exact,
because cohorts are disjoint.

kansoku-ui builds the feature against its fake Kansoku first. Its reconciliation and a real-Kansoku
session are a gated milestone that waits for this request. Until then, a real Kansoku answers
`unsupported_query_parameter` for the new parameters, and the consumer shows a notice instead.


## Delivery evidence

Plan 70 implements and verifies AC-1 through AC-5. `scripts/retention-acceptance.py`
seeds the public weekly signup/document and leap-February fixtures, checks independent
side filters, groups, defaults, budgets, shared saved membership and organization
aggregation, compares served/generated OpenAPI, and executes one required typed-client
example. The focused native harness passes 82 examples across ordinary/two-row blocks,
including weekly 10000/10001-point and memory-limit behavior. `just check` passes 537 core,
23 client and four probe examples plus formatting, generated contracts, profiles and
telemetry. Full `just acceptance` passes 18 migration cases, 682 core examples, 26 client
examples, the public reporting matrix in all three telemetry modes and seven administrative
families. Required cases have no failures or skips. Qualification is Darwin arm64 with
ClickHouse 26.8.28.14; no Linux qualification or release is claimed.

The final wire names are `period`, `days`, `startEvent`, `returnEvent`, `startFilter` and
`returnFilter`. `days` uses the chosen period; no `offsets` alias was added. Shared filters
apply to both sides. Starts supply group labels and only returns with matching group values
count. Side subject/session terms return `invalid_retention_filter`; week/month misalignment
returns `invalid_retention_period`. See the [Retention guide](../guides/query-metrics.md#retention)
and [Plan 70](../plans/70-measure-retention-by-calendar-period-with-separate-start-and-return-events.md)
for full acceptance evidence and the Haskell source-signature compatibility boundary.
