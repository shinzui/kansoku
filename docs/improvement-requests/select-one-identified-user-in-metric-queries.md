---
type: Improvement Request
title: Select one identified user in metric queries
description: Add a filter dimension that selects the events, sessions and activity of one or a few identified users by user ID after identity resolution, on the event, page-view, users, sessions, acquisition, revenue, feature-adoption and custom metric routes, so a consumer can chart one user's activity with the aggregate routes it already uses.
generated:
  by: process:claude-code
  at: "2026-11-12T23:39:58Z"
requestId: IR-18
status: proposed
timestamp: "2026-11-12T23:39:58Z"
origin: mori://shinzui/kansoku-ui/masterplans/6-build-the-users-directory-and-user-profile-pages
dependencies:
  - ref: mori://shinzui/kansoku/okf/improvement-requests/concepts/IR-17
    kind: soft
    reason: The consumer reaches a user's charts from the profile IR-17 provides; the filter is useful and testable on its own.
acceptanceCriteria:
  - id: AC-1
    statement: Metric routes that resolve subjects accept a filter dimension, named by Kansoku and not colliding with the `user:<trait>` namespace, that selects one identified user by `eq` or a bounded `in` list of identified users, matching every event that resolves to that user, including stitched pre-login anonymous events, and never an anonymous subject whose ID has the same text.
    verification: Public HTTP tests seed one user with pre-login anonymous events, a second user, and an anonymous subject whose ID equals the first user's ID text; `/metrics/events` grouped by event_name with the filter counts exactly the first user's resolved events, and `neq` and `in` behave as documented.
  - id: AC-2
    statement: The filter composes with existing grouping, grains, `timeGrain=none`, property, trait, cohort and session-scoped dimensions on `/metrics/events`, `/metrics/page-views`, `/metrics/users`, `/metrics/sessions`, `/metrics/acquisition`, `/metrics/revenue`, `/metrics/feature-adoption` and `/metrics/custom`, with sessions and acquisition owned by the session's first resolved user exactly as current-trait selection already defines; routes that cannot honour it reject it with a documented problem rather than ignoring it.
    verification: One public test per listed route compares the filtered answer with the same seed computed by hand; `groupBy=cohort:<uuid>` with the filter returns only the user's in or out group; an unsupported route returns the documented problem.
  - id: AC-3
    statement: The dimension, its operators, the `in` list bound, its identity semantics and its cost relative to unfiltered queries are documented in the query guide and the OpenAPI document; existing query budgets and the 10,000-row result cap continue to apply.
    verification: Review the guide and OpenAPI document; a test exceeding the `in` bound is rejected with `invalid_metric`.
reviews:
  - kind: model
    reviewer: process:claude-code
    reviewed_at: "2026-11-12T23:39:58Z"
    document_timestamp: "2026-11-12T23:39:58Z"
    scope: content-and-metadata
    outcome: commented
    provider: anthropic
    model: claude-opus-5-5
    effort: unspecified
    context: >-
      Author consistency review against kansoku 2975714 (the query guide's filter grammar, current person traits and
      cohort sections, ADR-5, ADR-16 and ADR-19). No implementation, runtime evidence or independent review is claimed.
---

# Select one identified user in metric queries

Requested by `mori://shinzui/kansoku-ui/masterplans/6-build-the-users-directory-and-user-profile-pages` under intention `intention_01m79211k6exp96qd67t2b3zmx`. The consumer is `mori://shinzui/kansoku-ui/plans/32-enrich-the-user-profile-with-per-user-activity-charts`.

## Why

Kansoku UI's user profile page is meant to show more than a list of events: a calendar of the days the user was active, which events and pages they used most, the devices, browsers and countries of their sessions, the channel that first brought them, their revenue, and whether they belong to each saved cohort. Every one of these is an existing aggregate, reachable today for a population selected by traits or by a cohort, but not for one user. The filter grammar at 2975714 has no user-ID dimension: `user:<name>` names governed traits, and `cohort` needs a saved cohort. The only workaround, a static cohort holding one user, writes state for a read and is not something a UI should do per page view.

## Requested behavior

Kansoku owns the dimension's name. It must not collide with `user:<trait>` (a governed trait named `id` should stay possible), so something like `user_id` or `subject` is suggested but not required. Support `eq`, `neq` and a bounded `in` over identified user IDs. Matching happens after conservative identity resolution under [ADR-5](../adr/0005-evidence-based-multi-signal-identity-resolution.md): an event belongs to the user when it resolves to `user:<id>`, which includes pre-login anonymous events stitched to them, and never to an anonymous subject whose ID happens to have the same text, the same rule [ADR-16](../adr/0016-governed-current-user-traits-and-replay-safe-erasure.md) applies to traits.

Ownership follows the existing current-trait table: events, page views, users, revenue and feature adoption use each event's resolved user; sessions and acquisition use the first resolved user of the whole retained session, so all of a user's session events stay together; custom metrics follow their definition scope. Funnels, retention, lifecycle, stickiness, paths and experiments may support the filter if it falls out naturally, but are not required; any route that does not support it must reject it explicitly.

The filter should combine with grouping by `cohort:<uuid>`, so a consumer can ask "is this user in each of these cohorts" without listing members, and with `timeGrain=none` from IR-4, so a consumer can read one user's totals for a period.

## Out of scope

A per-user resource (IR-17), raw event reads, anonymous-subject selection, and organisation selection.

## Acceptance and ownership

AC-1 through AC-3 are required. Implementation remains in this repository.
