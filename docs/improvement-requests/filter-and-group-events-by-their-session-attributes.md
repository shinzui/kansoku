---
type: Improvement Request
title: Filter and group events by the attributes of their session
description: Add session-scoped dimensions (for example session:channel, session:referrer_host, session:utm_campaign, session:entry_page) that page-views, users and custom metrics can filter and group by, selecting each event by the first-touch attributes of the web session it belongs to, so a consumer can report the pages viewed and the people seen during visits from one source.
generated:
  by: process:codex
  at: "2026-11-06T04:19:06Z"
requestId: IR-9
status: accepted
targetPlan: docs/plans/59-filter-and-group-events-by-their-session-attributes.md
origin: mori://shinzui/kansoku-ui/masterplans/3-build-the-reports-page
acceptanceCriteria:
  - id: AC-1
    statement: /metrics/page-views, /metrics/users and /metrics/custom accept filters on session-scoped dimensions for every session attribute the sessions route can filter on (channel, referrer_host, utm_source, utm_medium, utm_campaign, utm_content, utm_term, entry_page, and the visit enrichment dimensions), selecting an event when the web session it belongs to has that attribute.
    verification: An integration test with one session that arrives from a search engine and views three pages asserts that page-views filtered by session:channel=organic_search counts all three, while the existing channel filter counts only the landing view.
  - id: AC-2
    statement: The same session-scoped dimensions are accepted as groupBy on those routes, so page views can be grouped by route and session:channel together.
    verification: An integration test grouping page-views by route and session:referrer_host over two sessions from different referrers.
  - id: AC-3
    statement: Session attribution is the one the sessions and acquisition routes use (whole retained sessions, first page_view, (occurred_at,event_id) ordering), so a session-filtered page-view total and the sessions route agree on which sessions are selected. Events with no session ID, and non-web events, never match a session-scoped filter and fall in a null group.
    verification: Tests comparing selected session IDs between /metrics/sessions with channel=X and /metrics/page-views with session:channel=X, plus a server-side event with no session.
  - id: AC-4
    statement: Existing unprefixed dimensions keep their per-event meaning, and the query guide documents the difference with an example.
    verification: Existing tests pass unchanged; read docs/guides/query-metrics.md and docs/guides/web-enrichment.md.
reviews:
  - kind: model
    reviewer: process:claude-code
    reviewed_at: "2026-11-06T03:38:11Z"
    document_timestamp: "2026-11-06T03:38:11Z"
    scope: content-and-metadata
    outcome: commented
    provider: anthropic
    model: claude-opus-5-5
    effort: unspecified
    context: >-
      Author review against kansoku 16f3351 (the session and filter sections of the query guide,
      the web-enrichment guide, and the dimension prefixes handled in kansoku-core
      Metrics/Query.hs and Metrics/Custom.hs). No independent verification attestation is
      claimed.
---

# Filter and group events by the attributes of their session

**Authored by:** a `claude-code` session in `mori://shinzui/kansoku-ui`, planning its Reports page
(`mori://shinzui/kansoku-ui/masterplans/3-build-the-reports-page`).
**Addressed to:** `shinzui/kansoku` agents.
**Created:** 2026-11-06.

Follows the set IR-4 to IR-8, filed for the same page.

**Implementation plan:** [ExecPlan 59: Filter and group events by their session attributes](../plans/59-filter-and-group-events-by-their-session-attributes.md).
The request is accepted for implementation; implementation has not started.


## Why

A web report lets the reader click a traffic source, such as the referrer `news.ycombinator.com`
or the campaign `launch`, and see what those visitors did: which pages they viewed, how many
page views per visit, and how many people came. Kansoku can describe the *sessions* from a source,
because `/metrics/sessions` and `/metrics/acquisition` filter whole sessions by their first-touch
attributes. It cannot describe the *events inside* those sessions.

On `page-views`, `users` and `custom`, a filter on `channel`, `referrer_host`, a `utm_*` tag or
`entry_page` selects each event by its own request's enrichment (`docs/guides/web-enrichment.md`).
Only the landing page of a visit carries the external referrer or the campaign tags; later page
views carry a same-site referrer, which `referrerHost` drops. So `channel=organic_search` on
page views counts landing pages, not the visit, and a consumer cannot tell the two apart from the
answer. `entry_page` has no per-event meaning at all outside the sessions route. kansoku-ui
therefore has to hide page views, top pages and visitors on its page for a single source, and
cannot honour a source filter on those figures anywhere.


## What is asked

Add session-scoped dimensions, for example with a `session:` prefix alongside `prop:`, `user:`,
`org:` and `cohort:`: `session:channel`, `session:referrer_host`, `session:utm_source`,
`session:utm_medium`, `session:utm_campaign`, `session:utm_content`, `session:utm_term`,
`session:entry_page`, and the visit dimensions (`session:device_class`, `session:browser_family`,
`session:os_family`, `session:country_code`). Accept them as filters and as `groupBy` on
`/metrics/page-views`, `/metrics/users` and `/metrics/custom` (including ratio population
filters). An event matches when its session, assembled and attributed exactly as for
`/metrics/sessions`, has the attribute. Kansoku chooses the name and may limit the routes if one
of them cannot support it, documenting why.


## Not requested

Changing the meaning of the existing unprefixed dimensions, a new session inactivity timeout,
or session-scoped dimensions on funnels, paths or retention.
