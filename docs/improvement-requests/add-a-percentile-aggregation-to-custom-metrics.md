---
type: Improvement Request
title: Add a percentile aggregation to custom metrics
description: Let /metrics/custom and saved metric definitions compute a percentile (for example p50, p75 or p95) of a declared numeric property, so consumers can report latency-like values such as web vitals and page durations, where averages mislead.
generated:
  by: process:claude-code
  at: "2026-11-05T21:06:04Z"
requestId: IR-7
status: proposed
origin: mori://shinzui/kansoku-ui
acceptanceCriteria:
  - id: AC-1
    statement: /metrics/custom accepts a percentile aggregation with a declared numeric property and a quantile strictly between 0 and 1, with the same events, filters, groupBy, timeGrain and cohort rules as average.
    verification: Integration test over known samples asserting p50, p75 and p95 per group and per bucket.
  - id: AC-2
    statement: Saved metric definitions accept the same aggregation and quantile, validated on write and execution.
    verification: POST, GET and run a saved percentile definition in the integration suite.
  - id: AC-3
    statement: The guide states whether the percentile is exact or approximate, its error bound if approximate, and how empty groups and missing or unset values behave.
    verification: Read the custom metrics section of docs/guides/query-metrics.md.
  - id: AC-4
    statement: A percentile can be paired with a sample count for the same group, so a consumer can hide groups with too few samples.
    verification: Run percentile and count requests with identical filters and grouping and assert the groups match.
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
      Author review against kansoku aaf84df kansoku-core/src/Kansoku/Metrics/Custom.hs and the
      custom metrics section of the query guide. No independent verification attestation is
      claimed.
---

# Add a percentile aggregation to custom metrics

**Authored by:** a `claude-code` session in `mori://shinzui/kansoku-ui`, planning a Reports page.
**Addressed to:** `shinzui/kansoku` agents.
**Created:** 2026-11-05.

**Implementation plan:** [ExecPlan 55: Add percentile aggregation to custom metrics](../plans/55-add-percentile-aggregation-to-custom-metrics.md).

Part of the set filed with IR-4; that request lists the others. IR-8 depends on it.


## Why

Custom metrics offer `count`, `unique_count`, `sum`, `average` and `ratio`. Latency-like values
are skewed, and the convention is to report a high percentile: Core Web Vitals are rated at the
75th percentile. A site-health report shows "slowest pages by LCP p75" and a p75 for each vital.
The same need exists for data Kansoku already has, such as `page_leave.durationMs`, where a
median is more honest than a mean.


## What is asked

Add a percentile aggregation that takes a declared numeric `property` and a quantile, for example
`aggregation=percentile&property=value&quantile=0.75`. Accept it in ad-hoc requests and saved
definitions. Kansoku chooses between exact and approximate computation and documents the choice.
It need not be allowed as a ratio component.


## Not requested

Several quantiles in one request, or histograms.
