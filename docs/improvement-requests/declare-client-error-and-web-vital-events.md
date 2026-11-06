---
type: Improvement Request
title: Declare client error and web vital events
description: Declare client_error and web_vital event schemas in the registry, and ask the browser SDK to capture them, so a consumer can report JavaScript errors and Core Web Vitals by page next to product analytics.
generated:
  by: process:codex
  at: "2026-11-06T14:09:01Z"
requestId: IR-8
status: completed
completedAt: "2026-11-06T14:09:01Z"
resolution: >-
  AC-1 through AC-4 delivered by plan 57: catalog v5 and enforced v1 contracts,
  public/native error and p75 report proofs, sending/query documentation, and
  mori://shinzui/kansoku-ts/plans/7-capture-client-errors-and-web-vitals-with-explicit-opt-in.
  Deterministic, custom-metrics and full packaged acceptance gates passed on 2026-11-06.
targetPlan: docs/plans/57-declare-client-error-and-web-vital-events.md
origin: mori://shinzui/kansoku-ui
dependencies:
  - ref: mori://shinzui/kansoku/okf/improvement-requests/concepts/IR-7
    kind: hard
    reason: Web vitals are reported as a 75th percentile per metric and per page, which needs the percentile aggregation.
acceptanceCriteria:
  - id: AC-1
    statement: The registry declares client_error with bounded string properties for the error message and type, a handled Boolean, and a description that says stack traces and personal data are not to be sent.
    verification: Read the generated docs/contracts/events.json and the golden test.
  - id: AC-2
    statement: The registry declares web_vital with a metric property restricted to LCP, INP, CLS, FCP and TTFB by a pattern and a nonnegative numeric value whose unit each metric defines (milliseconds, or unitless for CLS).
    verification: Read docs/contracts/events.json and an ingest test rejecting an unknown metric name.
  - id: AC-3
    statement: Errors grouped by route and by prop:message, users affected by errors, and p75 per vital per route are all expressible with existing routes plus IR-7, and the guide shows each query.
    verification: Run the documented queries against fixture events in the integration suite.
  - id: AC-4
    statement: A follow-up for the browser SDK in mori://shinzui/kansoku-ts is recorded, covering opt-in capture of uncaught errors and unhandled rejections (deduplicated and rate-limited) and of web vitals sent once per page view.
    verification: The follow-up exists where kansoku-ts tracks requested work and links to this request.
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
      Author review against kansoku aaf84df docs/contracts/events.json and
      docs/event-schema-governance.md; mori://shinzui/kansoku-ts was checked for error or vitals
      capture and has none. No independent verification attestation is claimed.
---

# Declare client error and web vital events

**Authored by:** a `claude-code` session in `mori://shinzui/kansoku-ui`, planning a Reports page.
**Addressed to:** `shinzui/kansoku` agents, with a follow-up for `shinzui/kansoku-ts`.
**Created:** 2026-11-05.

Part of the set filed with IR-4; that request lists the others.

**Implementation plan:** [ExecPlan 57: Declare client error and web vital events](../plans/57-declare-client-error-and-web-vital-events.md).
Completed 2026-11-06. Catalog v5 publishes and ingestion enforces both v1 contracts. The
sending guide and `scripts/site_health_scenario.py` prove the error, affected-user and vital
p75 recipes through the public API on owned databases. Deterministic, custom-metric and full
packaged acceptance gates pass. The unimplemented browser follow-up is
`mori://shinzui/kansoku-ts/plans/7-capture-client-errors-and-web-vitals-with-explicit-opt-in`;
its independent flags default off and its acceptance covers privacy, bounded labels,
deduplication/rate limits, final measurements, attribution and reversible lifecycle behavior.


## Why

The site-health report the kansoku-ui owner wants has errors over time, users affected, where
errors happen by page, the slowest pages by LCP, and a p75 for each Core Web Vital. Kansoku's
catalog declares no event for either signal, and the browser SDK in `mori://shinzui/kansoku-ts`
captures neither. Undeclared names are accepted, but per
`docs/event-schema-governance.md` and the query guide, `prop:` grouping and filtering need a
declared scalar property. Without a declaration a report cannot group errors by message or
vitals by metric.

Declaring them in Kansoku, rather than in each producer, keeps one contract for every app that
reports into the same account.


## What is asked

- Declare `client_error` v1 and `web_vital` v1 in `defaultRegistry`
  (`kansoku-api/src/Kansoku/Event/Registry.hs`), regenerate `docs/contracts/events.json`, and
  document them in `docs/guides/send-events.md`. Both use the standard top-level `url` and
  session context so `route` and session dimensions work.
- Show the report queries in the guide (errors by route and by message, users affected, p75 per
  vital and route).
- Record the browser SDK work in kansoku-ts. Capture there should be opt-in.


## Not requested

Stack trace storage, source maps, issue grouping or alerting. That is error-tracking product
scope; this request covers only counts and percentiles a report needs. Session replay, and
signals derived from it such as rage clicks or failed requests, are out of scope.
