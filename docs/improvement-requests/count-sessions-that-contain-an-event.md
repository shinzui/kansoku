---
type: Improvement Request
title: Count sessions that contain an event
description: Let /metrics/sessions select the web sessions that contain at least one event of a given name (for example client_error), with the route's existing grouping, grains and attribute filters, so a consumer can report the share of sessions that saw an error.
generated:
  by: process:claude-code
  at: "2026-11-08T01:20:00Z"
requestId: IR-14
status: completed
completedAt: "2026-11-08T14:10:28Z"
timestamp: "2026-11-08T14:10:28Z"
targetPlan: docs/plans/66-count-sessions-that-contain-an-event.md
resolution: >-
  AC-1 through AC-4 delivered by plan 66: bounded containsEvent any-of selection
  over whole retained web sessions, every session measure and existing selection,
  authenticated HTTP and typed client, generated OpenAPI and the percentage recipe.
  Deterministic checks, native proofs at ordinary/tiny block sizes and the packaged
  public fixture in all three telemetry modes passed on 2026-11-08.
origin: mori://shinzui/kansoku-ui/masterplans/4-build-the-health-tab-of-the-reports-page
dependencies:
  - ref: mori://shinzui/kansoku/okf/improvement-requests/concepts/IR-8
    kind: soft
    reason: client_error is the motivating event; the selection itself is generic over event names.
acceptanceCriteria:
  - id: AC-1
    statement: /metrics/sessions accepts a selection of sessions by contained event name (one name or a set of names), and measure=count then counts only the selected whole retained sessions, assigned to their start bucket as today.
    verification: A public acceptance fixture with three sessions on one day, one of which contains a client_error, returns count 1 with the selection and 3 without it.
  - id: AC-2
    statement: The selection combines with the route's existing session-attribute filters, groupBy (for example entry_page or channel), timeGrain and includeBots, and with measure=bounce_rate and measure=average_duration_seconds.
    verification: The same fixture grouped by entry_page, and filtered by channel, returns the expected per-group counts.
  - id: AC-3
    statement: A session matches when any of its retained events has the named event name, wherever in the session it occurs and whether or not it is the first event; non-web events and events without a session ID never make a session match.
    verification: Fixture sessions whose client_error is the last event, and a server-side client_error with no session ID, prove both cases.
  - id: AC-4
    statement: The query guide documents the parameter or filter, its bounds (for example the maximum number of names), and an example of the share of sessions with an error as two requests.
    verification: Read docs/guides/query-metrics.md and the generated OpenAPI document.
reviews:
  - kind: model
    reviewer: process:claude-code
    reviewed_at: "2026-11-08T01:20:00Z"
    document_timestamp: "2026-11-08T01:20:00Z"
    scope: content-and-metadata
    outcome: commented
    provider: anthropic
    model: claude-opus-5-5
    effort: unspecified
    context: >-
      Author review against kansoku a01ef28 (docs/guides/query-metrics.md: the route parameter
      table, "measure=bounce_rate" and the sessions section, which rejects prop: filters and
      accepts only session-attribute filters). Nothing was run against a server; no independent
      verification attestation is claimed.
---

# Count sessions that contain an event

**Authored by:** a `claude-code` session in `mori://shinzui/kansoku-ui`, planning the Health tab
of its Reports page (`mori://shinzui/kansoku-ui/masterplans/4-build-the-health-tab-of-the-reports-page`).
**Addressed to:** `shinzui/kansoku` agents.
**Created:** 2026-11-08.

Filed with IR-13 for the same tab.


## Why

A site-health report's second headline, after the error count, is the share of visits that
hit an error: "1.5% of sessions, 61 of 3,980". It says how widespread a problem is in a way an
error count cannot. One broken script on a busy page makes hundreds of errors, while a hundred
errors spread over a hundred visits is a different problem.

Kansoku can count errors (`/metrics/events` with `event_name:eq:client_error`) and the people
who saw one (`/metrics/users` with the same filter), but not the sessions that contain one.
`/metrics/sessions` accepts only session-attribute filters, which select a session by its first
page view, and rejects `prop:` filters. No other route counts sessions. A consumer cannot
derive the number either: event-level session IDs are not exposed, by design.


## Requested change

Give `/metrics/sessions` a way to select sessions by an event they contain. Kansoku chooses
the name and form. Two shapes that would serve:

- a parameter, `containsEvent=client_error` (comma-separated names for "any of"), or
- a filter on a reserved session dimension, `{"dimension":"contains_event","op":"eq","value":"client_error"}`,
  which also gives `in` for free.

The selection should apply to all three measures and keep the route's existing semantics for
attribution, grouping, bot exclusion and start-bucket assignment.


## Notes

Selecting by a property of the contained event (for example only unhandled errors,
`prop:handled:eq:false`) would be useful but is not asked; event name alone answers the
report. The same selection gives consumers "sessions that converted" for any key event,
which kansoku-ui would also use.

kansoku-ui adopts this request as a gated milestone; until it lands its Health tab shows the
share of visitors who saw an error instead.
