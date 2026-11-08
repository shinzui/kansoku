---
type: Improvement Request
title: Stop counting client errors and web vitals as session engagement
description: Classify client_error and web_vital as non-engagement events in the session rules, as session_start and page_leave already are, so that turning on kansoku-js's opt-in error and vital capture does not remove bounces and change a site's bounce rate.
generated:
  by: process:claude-code
  at: "2026-11-08T01:20:00Z"
requestId: IR-13
status: completed
completedAt: "2026-11-08T06:55:25Z"
timestamp: "2026-11-08T06:55:25Z"
targetPlan: docs/plans/65-stop-counting-client-errors-and-web-vitals-as-session-engagement.md
resolution: >-
  AC-1 through AC-4 delivered by plan 65. Both diagnostic names are non-engagement
  for every stored version while preserving duration. Direct and replicated
  fenced migrations reconstruct retained sessions; native, packaged HTTP,
  upgrade/recovery, replica and documentation checks passed.
origin: mori://shinzui/kansoku-ui/masterplans/4-build-the-health-tab-of-the-reports-page
dependencies:
  - ref: mori://shinzui/kansoku/okf/improvement-requests/concepts/IR-8
    kind: soft
    reason: IR-8 declared the two events and recorded, in ADR-7 and the sending guide, that they currently count as engagement; this request changes that classification.
acceptanceCriteria:
  - id: AC-1
    statement: A web session whose only events are one page_view plus any number of client_error and web_vital events is a bounce under measure=bounce_rate, on /metrics/sessions and wherever else the engagement rule applies.
    verification: A session-rule test and a public acceptance fixture with one page_view followed by a web_vital (LCP) and a client_error in the same session, asserting bounce_rate 1 for that session, and 0 when a declared application event such as feature_used is added.
  - id: AC-2
    statement: Sessions without client_error or web_vital events keep their bounce classification and observed duration exactly; whether the two events extend observed duration is decided and documented (they may, as page_leave does).
    verification: The existing session examples pass unchanged, and docs/guides/query-metrics.md lists client_error and web_vital beside session_start and page_leave in the non-engagement list and states the duration rule.
  - id: AC-3
    statement: Sessions already retained before the change are reclassified by a documented, fenced rebuild path, or the guide states exactly which sessions keep the old classification and how an operator rebuilds them.
    verification: A runbook or guide section, and an acceptance case that rebuilds a retained fixture session containing a web_vital and observes the new bounce result.
  - id: AC-4
    statement: The sending guide's warning that automatic collection can remove bounces is replaced by the new rule, and ADR-7's engagement consequence is updated or superseded.
    verification: Read docs/guides/send-events.md ("Client errors and web vitals") and docs/adr/0007-versioned-event-schema-governance-and-publication.md.
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
      Author review against kansoku a01ef28 (docs/guides/query-metrics.md "measure=bounce_rate",
      docs/guides/send-events.md "Client errors and web vitals", ADR-7 and ADR-13) and
      kansoku-ts 68b0fea (the autocapture.clientErrors and autocapture.webVitals options in
      packages/kansoku-js/README.md). Nothing was run against a server; no independent
      verification attestation is claimed.
---

# Stop counting client errors and web vitals as session engagement

**Authored by:** a `claude-code` session in `mori://shinzui/kansoku-ui`, planning the Health tab
of its Reports page (`mori://shinzui/kansoku-ui/masterplans/4-build-the-health-tab-of-the-reports-page`).
**Addressed to:** `shinzui/kansoku` agents.
**Created:** 2026-11-08.

Filed with IR-14 for the same tab.


## Why

The query guide defines a bounce as a session with exactly one distinct page_view and no
engagement events, and lists the events that are not engagement: session_start, page_leave,
identify, identify_once, alias, group and experiment_viewed. Every other event is engagement.
IR-8 declared `client_error` and `web_vital` without adding them to that list, and both the
sending guide and ADR-7 say so: "automatic collection can remove bounces and extend observed
duration. Decide deliberately before enabling it in a product."

kansoku-js 0.1.0 and later send web vitals on every page view once a site sets
`autocapture.webVitals`. Most page views produce at least one vital (FCP and TTFB are reported
on almost every load, LCP on most), so a site that turns the option on sees its bounce rate
fall to near zero overnight. Nothing the visitor did changed. kansoku-ui's Reports page shows
bounce rate as a headline figure and per page, source and device, so the Health tab that reads
these events would make the Web tab beside it wrong.

Neither event is a visitor acting on the page. A web vital is a measurement the browser takes,
much like the page_leave the SDK already sends at exit. A client error is something that went
wrong. They describe the page view; they are not engagement with it.


## Requested change

- Add `client_error` and `web_vital` to the non-engagement events in the session rules
  (wherever session_start and page_leave are classified), for every schema version of the two
  names.
- Decide whether they extend observed duration. Extending it, as page_leave does, is
  acceptable: vitals are finalized at page exit, near the page_leave time.
- Provide the fenced rebuild path for retained sessions that ADR-7 says a reclassification
  needs, or document which sessions keep the old rule.
- Update the query guide's bounce paragraph, the sending guide's warning and ADR-7.


## Notes

A configurable engagement list per account would also answer this, but it is a larger change
and not what is asked. Undeclared application events stay engagement as today.

kansoku-ui adopts this request as a gated milestone: until it lands, its Reports page warns
beside bounce rate and session length when the period contains these events.
