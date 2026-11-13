---
type: Improvement Request
title: Save named analyses for an account
description: Add an account-scoped saved-analysis resource holding a name, a description, a kind (trends, funnel or retention) and a bounded client-versioned JSON document, with create, read, update and delete, cursor pages ordered by most recent update, a kind filter and optimistic concurrency, so consumers can keep a shared library of analyses that people reopen.
generated:
  by: process:claude-code
  at: "2026-11-12T23:50:00Z"
requestId: IR-19
status: proposed
timestamp: "2026-11-12T23:50:00Z"
origin: mori://shinzui/kansoku-ui/masterplans/7-build-the-insights-library-of-saved-analyses
acceptanceCriteria:
  - id: AC-1
    statement: A service token can create, list, read, replace and delete saved analyses of its own account. Listing is a Relay connection with the same first/after/last/before parameters and bounds as /metric-definitions. An unknown or another account's analysis is a 404 problem, and a write key is rejected.
    verification: Public HTTP tests over two accounts create, read, replace and delete an analysis; assert account isolation on every route, 404 for an unknown and a foreign ID, and rejection of a write key.
  - id: AC-2
    statement: An analysis has a server-assigned ID, a name (1 to 120 characters after trimming), an optional description (at most 500 characters), a kind from a closed set that starts as trends, funnel and retention, a positive integer documentVersion chosen by the client, a document that is a JSON object of at most 32 KiB when serialized, and createdAt and updatedAt times. Kansoku validates these bounds with a 400 problem naming the field, stores the document without interpreting it, and returns it as an equal JSON value.
    verification: Tests reject an empty name, an over-long name and description, an unknown kind, a non-object document (array, string, null), a document over the limit and a zero documentVersion; a nested document with Unicode, numbers and nulls round-trips equal.
  - id: AC-3
    statement: Every analysis carries a revision that changes on each successful replace. Replace and delete accept the revision the client last read and fail with a 409 (or 412) problem, changing nothing, when it is not the current one.
    verification: Two clients read the same analysis; the first replace succeeds and advances the revision; the second, sending the old revision, is rejected and the stored analysis is the first client's; a delete with the old revision is also rejected.
  - id: AC-4
    statement: The list is ordered by updatedAt, most recent first, with a deterministic tie-break, keeps stable cursors across pages, and accepts an optional kind filter.
    verification: Tests replace an older analysis and observe it move to the first page; equal updatedAt values page deterministically; kind=funnel returns only funnels, with correct cursors.
  - id: AC-5
    statement: An account holds at most a documented number of analyses (1,000 is enough for the consumer), and creating one more is a problem response. The routes, bounds, ordering, concurrency rule and the fact that Kansoku neither interprets nor executes the document are described in the OpenAPI document and the query guide, and the typed Haskell client gains the resource as it has metric definitions.
    verification: A test fills a small configured limit and is refused; review the served OpenAPI document, the guide and the client module.
reviews:
  - kind: model
    reviewer: process:claude-code
    reviewed_at: "2026-11-12T23:50:00Z"
    document_timestamp: "2026-11-12T23:50:00Z"
    scope: content-and-metadata
    outcome: commented
    provider: anthropic
    model: claude-opus-5-5
    effort: unspecified
    context: >-
      Author review against kansoku 2975714: docs/api/openapi.json (the /metric-definitions and
      /cohorts resources and their Relay page parameters) and
      docs/capabilities/custom-metric-definitions.md. Nothing was run against a server; no
      independent verification attestation is claimed.
---

# Save named analyses for an account

**Authored by:** a `claude-code` session in `mori://shinzui/kansoku-ui`, planning its Insights
library (`mori://shinzui/kansoku-ui/masterplans/7-build-the-insights-library-of-saved-analyses`).
**Addressed to:** `shinzui/kansoku` agents.
**Created:** 2026-11-12.


## Why

kansoku-ui is adding an Insights page: a library of saved analyses that the people sharing an
account reopen. Each one is a trend (counts, unique users or sums of events over time), a funnel
(how many people complete a sequence of steps) or a retention analysis (how many people come back
after their first visit). Each card shows a name, a description, when the analysis was last
updated and a small preview. Opening a card restores the analysis exactly as it was saved.

A library is account state that must survive a reload, another browser and another analyst.
kansoku-ui stores nothing of its own (its ADR-7 keeps it free of persistence, and its ADR-1 makes
Kansoku its only backend). Kansoku's saved metric definitions cannot hold the library: a funnel or
retention analysis is not a metric, and a trend may combine several answers. Saved cohorts are
populations. No existing resource fits.


## Requested change

Add an account-scoped saved-analysis resource. Kansoku chooses the route name (`/analyses` would
match `/metric-definitions` and `/cohorts`) and the exact field names.

The document is deliberately opaque. It holds the client's own description of the analysis: the
metric request in kansoku-ui's search form, a relative date range such as "last 30 days", the chart
kind and chart options. That vocabulary changes with the client, and the client versions it with
`documentVersion`. Kansoku validates only the envelope and the size and never executes the
document, so it takes on no compatibility burden for it. The kind is in the envelope, not the
document, so a list can be filtered by kind and another client can tell what an analysis is
without parsing it.

Optimistic concurrency matters because several people, and later agents, edit the same library.
Without it, the last writer silently discards another person's change.


## Notes

Not requested: seeding default analyses into new accounts (the consumer offers a button that
creates starter analyses on demand); server-side search by name (the consumer filters a bounded
list); validating or executing the document; and references from an analysis to the cohorts or
saved metrics it uses (a deleted reference fails at query time, as saved metric definitions do
today).

Later, a typed and executable form of the document could let agents and other clients build and
run analyses through Kansoku alone. It is not asked now. The kind and documentVersion fields
leave room for it.

kansoku-ui builds the library against its fake Kansoku first. Its persistence against a real
Kansoku is a gated milestone that waits for this request.
