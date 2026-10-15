---
type: Architecture Decision Record
title: Bounded complete aggregate responses
description: Bound metric inputs and final aggregate cardinality, returning a complete answer or a permanent problem instead of cursor pages over changing aggregates.
docId: ADR-9
status: Accepted
date: 2026-10-15
timestamp: 2026-10-15T04:51:11Z
generated:
  by: process:codex
  at: 2026-10-15T04:44:00Z
originatingPlan: docs/plans/26-bound-analytics-query-inputs-and-result-cardinality.md
---

# ADR 0009: Bounded complete aggregate responses

## Context

Metric series are computed from a changing account-scoped event set, rather than
stored collections of independently retrievable resources. Unbounded property and
variant groups could previously transfer and collect arbitrary result lists in
Haskell. Independently recomputed cursor pages would not guarantee a consistent
aggregate answer across changing input data.

[ADR-3](0003-api-key-authentication-and-account-scoped-analytics.md) owns account
isolation and native query parameters, [ADR-4](0004-queryable-event-properties-and-identity-resolved-projection.md)
owns declared properties and the shared identity projection, and
[ADR-6](0006-exposure-based-experiment-analytics.md) owns exact/approximate experiment
semantics and no-data success. These contracts remain in force.

## Decision

Every implemented metrics execution function enforces a positive half-open date
range of at most 366 days, at most 20 non-empty ordered funnel steps, and at most
32 distinct retention offsets between 1 and 365. Repeated funnel names retain
ordered repetition semantics; retention values normalize to ascending unique order,
with offset zero added implicitly for cohort size. The existing 90-day funnel window
remains. Public constants live in the API package and are not deployment settings.

Each complete aggregate query projects the three native result fields, orders them
explicitly and transfers at most 10,001 rows. Exactly 10,000 succeeds; an extra row
witnesses overflow and produces a permanent 400 metric_result_too_large problem
with no partial MetricResult. The limit sits after all grouping, ratios, identity
resolution, retention and funnel computation. It bounds result transfer/collection,
not database scan cost or execution duration.

Ordering is a closed service-owned choice. Ordinary series use bucket then group,
conversion uses group key, retention uses cohort then numeric offset, plain funnels
use numeric step, and experiment funnels use variant then numeric step. Hidden typed
sort columns pass through the aggregate subquery but stay out of the wire projection.
The driver returns its block list in reverse arrival order; execution restores block
order before concatenating, independently of its existing per-block field repairs.
Native account/name parameters remain.

The execution result distinguishes compile/input errors, result overflow and storage
failure. Input failures never check out a connection. Overflow follows a successful
bounded read and does not invalidate its connection. Native errors are translated only
after the shared pool has disposed the failed handle; asynchronous cancellation
propagates. Storage failures remain retryable 503. Body-size 413 is not reused for
query/result bounds.

This is an explicit deviation from the growing-collection cursor policy at
`mori://shinzui/haskell-jitsurei/docs/api-relay-pagination`, not Relay compliance or
a reference-data exemption. Future resource-list APIs still follow that standard.

## Alternatives considered

Cursor pages of independently recomputed aggregates were rejected because the event
set can change between requests. Silently truncating the answer was rejected because
it makes partial totals look complete. Applying LIMIT to raw events was rejected
because it changes the metric. Collecting all rows before truncation was rejected
because it leaves Haskell memory use unbounded. A second query-pool recovery policy
was rejected because readiness and analytics share the accepted ADR-2 boundary.

## Consequences

Clients can rely on complete successful answers within documented bounds and must
narrow a query after a permanent limit rejection. Existing successful result shapes,
account isolation, empty results and metric meanings remain. OpenAPI publishes the
point-array maximum and route limits. Native evidence passes for 10,000/10,001 property and experiment answers, two retention
cohorts with offsets 1, 2 and 10, ten-step plain and per-variant funnels, and recovery
through the shared size-one pool. Large, small and tiny-block settings exercise block
arrival order independently of field decoding. Required fixtures own disposable
ClickHouse processes and fail missing prerequisites or zero/pending examples.
