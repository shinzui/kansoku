---
type: Improvement Request
title: Name the experiment conversion rate measure correctly in the query guide
description: The query guide says the experiment conversion endpoint returns a measure named rate, while the query compiler and its tests emit conversion_rate; correct the guide so API consumers read the measure kansoku actually returns.
generated:
  by: process:codex
  at: "2026-11-06T04:36:59Z"
requestId: IR-3
status: completed
completedAt: "2026-11-06T12:29:54Z"
resolution: >-
  AC-1 delivered by plan 61: the experiment conversion section of docs/guides/query-
  metrics.md names exposed, converted and conversion_rate (commit 1fb1eac). just guides-
  check and git diff --check passed; server behaviour is unchanged.
targetPlan: docs/plans/61-name-the-experiment-conversion-rate-measure-correctly-in-the-query-guide.md
origin: mori://shinzui/kansoku-ui/plans/11-add-a-chart-kind-registry-composed-chart-inputs-and-a-chart-options-panel
acceptanceCriteria:
  - id: AC-1
    statement: The experiment conversion section of the query-metrics guide names the three measures as exposed, converted, and conversion_rate.
    verification: Read docs/guides/query-metrics.md near the conversion endpoint and compare it with compileTraitExperimentConversion in kansoku-core/src/Kansoku/Metrics/Query.hs and the assertions in kansoku-core/test/Kansoku/QuerySpec.hs.
reviews:
  - kind: model
    reviewer: process:claude-code
    reviewed_at: "2026-11-05T04:54:03Z"
    document_timestamp: "2026-11-05T04:54:03Z"
    scope: content-and-metadata
    outcome: commented
    provider: anthropic
    model: claude-opus-5-5
    effort: unspecified
    context: >-
      Author review against kansoku 8171b5c source and tests; the fake and the chart transform in
      mori://shinzui/kansoku-ui were written from the guide and showed the effect. No independent
      verification attestation is claimed.
---

# Name the experiment conversion rate measure correctly in the query guide

**Authored by:** a `claude-code` session implementing
`mori://shinzui/kansoku-ui/plans/11-add-a-chart-kind-registry-composed-chart-inputs-and-a-chart-options-panel`.
**Addressed to:** `shinzui/kansoku` agents.
**Created:** 2026-11-05.

**Implementation plan:** [ExecPlan 61: Name the experiment conversion rate measure correctly in the query guide](../plans/61-name-the-experiment-conversion-rate-measure-correctly-in-the-query-guide.md).
Completed by Plan 61 on 2026-11-06; see `resolution` (status reconciled on 2026-11-13).


## Why

`docs/guides/query-metrics.md` line 383 says the experiment conversion endpoint "returns
`exposed`, `converted`, and `rate` as separate points in each variant's `group`". The compiler
emits a different name: `compileTraitExperimentConversion` in
`kansoku-core/src/Kansoku/Metrics/Query.hs` builds the measures from
`('conversion_rate',if(exposed=0,0.,converted/exposed))`, and
`kansoku-core/test/Kansoku/QuerySpec.hs` asserts `conversion_rate`.

A consumer that follows the guide finds no point named `rate`. kansoku-ui did, and its experiment
conversion chart labelled every variant "0.0% converted" against a real kansoku while its fake,
written from the same guide, looked correct. kansoku-ui now reads `conversion_rate`.


## What is asked

Change the guide's sentence to name `conversion_rate`. The code and tests are the behaviour
consumers already depend on, so the measure itself should not be renamed.
