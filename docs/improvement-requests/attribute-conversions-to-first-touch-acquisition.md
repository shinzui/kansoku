---
type: Improvement Request
title: Attribute conversions to first-touch acquisition
description: Add converted-user and conversion-rate measures to /metrics/acquisition for a caller-supplied list of conversion events, credited to the visitor's first-touch channel, referrer, campaign or landing page, so a consumer can rank traffic sources by how well they convert.
generated:
  by: process:claude-code
  at: "2026-11-05T21:06:04Z"
requestId: IR-5
status: proposed
origin: mori://shinzui/kansoku-ui
dependencies:
  - ref: mori://shinzui/kansoku/okf/improvement-requests/concepts/IR-4
    kind: soft
    reason: A whole-range answer is what a source table shows; with only bucketed answers the converted users per row cannot be summed over the period.
acceptanceCriteria:
  - id: AC-1
    statement: /metrics/acquisition accepts a list of 1..20 conversion event names and measures for the converted users and the conversion rate (converted users divided by the users in the same population), grouped by any acquisition dimension including channel, referrer_host, utm_source, utm_medium, utm_campaign and entry_page.
    verification: An integration test with users from two channels, some of whom later emit a listed event, asserts converted counts and rates per channel.
  - id: AC-2
    statement: Conversion joins on the canonical, identity-resolved user, so an anonymous first-touch visit followed by a signup sent under the user ID after an alias counts as one converted user in the first-touch group.
    verification: A test with an anonymous web session, an alias and a server-side conversion event under the user ID asserts the conversion lands in the anonymous session's channel.
  - id: AC-3
    statement: The guide states the population and timing rules (which session a user is credited to, whether the conversion must follow it, and whether it must fall inside the range), and the denominator of the rate is the same population as its numerator.
    verification: Read the acquisition section of docs/guides/query-metrics.md and compare it with the compiler and tests.
  - id: AC-4
    statement: Bot exclusion, session-attribute filters, groupBy limits and the result-size limit apply as they do for measure=users.
    verification: Existing acquisition tests extended with the new measures.
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
      Author review against kansoku aaf84df (Ingest/Channel.hs, the acquisition and custom-metric
      sections of the query guide, the web-enrichment guide). No independent verification
      attestation is claimed.
---

# Attribute conversions to first-touch acquisition

**Authored by:** a `claude-code` session in `mori://shinzui/kansoku-ui`, planning a Reports page.
**Addressed to:** `shinzui/kansoku` agents.
**Created:** 2026-11-05.

Part of the set filed with IR-4; that request lists the others.


## Why

The question a marketing report answers is "which channels, sources, campaigns and landing pages
bring people who convert?" A row shows visitors, converted visitors, conversion rate and bounce
rate. Kansoku gives visitors (`/metrics/acquisition measure=users`) and bounce
(`/metrics/sessions measure=bounce_rate`) by first-touch attribute. Nothing gives the
conversions.

A custom metric grouped by `channel` looks close but answers something else. Enrichment
classifies every event from its own request, so `channel` on a `user_registered` or
`subscription_started` event describes that request, not how the person first arrived. Server-side
producers send no referrer, and `referrerHost` drops same-site referrers, so most conversion
events classify as `direct`. A consumer cannot join the two answers either: both are
aggregates, and per-user rows are not exposed.


## What is asked

Add to `/metrics/acquisition` a conversion event list (for example
`conversionEvents=user_registered,subscription_started`) and measures for the converted users and
the conversion rate. A suggested population: each user is credited to the attributes of their
first selected session in the range, and counts as converted if they emitted any listed event at
or after that session's start and before `to`. That keeps rows additive and makes the rate's
denominator the same people as its numerator. A session-level variant (the session itself
contained a conversion) is acceptable instead if Kansoku records why; either way the guide must
say which.

Saved metric definitions should be usable as the event list later, but that is not required here.


## Not requested

Multi-touch or last-touch models, revenue attribution, or changes to how sessions or channels are
classified.
