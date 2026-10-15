---
id: 26
slug: bound-analytics-query-inputs-and-result-cardinality
title: "Bound analytics query inputs and result cardinality"
kind: exec-plan
created_at: 2026-10-15T03:10:58Z
intention: "intention_01m4yrkpeve8c8aktyqnqdftv0"
master_plan: "docs/masterplans/4-align-kansoku-with-relevant-haskell-jitsurei-practices.md"
provenance:
  created_by:
    model: "gpt-6.1-sol"
    harness: "codex-cli"
    at: 2026-10-15T03:10:58Z
---

# Bound analytics query inputs and result cardinality

This ExecPlan is a living document. Update milestones, evidence, discoveries and durable ADRs.


## Purpose / Big Picture

A client will receive a complete metric answer within documented limits, or a clear permanent
problem asking it to narrow the query. Large date ranges, excessive funnel/retention inputs and
high-cardinality groups will no longer create unbounded Haskell result lists or silently partial
answers. Existing successful metric shapes and aggregation semantics remain intact.


## Progress

- [ ] M1: Every implemented metrics route rejects out-of-contract inputs before storage access with stable problem codes.
- [ ] M2: Every query result is capped before unbounded collection, with exact-bound success and over-bound explicit failure.
- [ ] M3: Database-backed correctness, SDK/OpenAPI behavior and the documented aggregate-response exception are verified.


## Surprises & Discoveries

None during implementation yet.


## Decision Log

On 2026-10-15, choose complete-or-error aggregate responses with fixed public bounds: a positive
from/to window of at most 366 days, at most 20 funnel steps, at most 32 distinct retention offsets
between 1 and 365, and at most 10,000 returned metric points. This is a deliberate policy choice,
not an inherited existing bound. Document it as a service-specific exception to the collection
pagination default. Do not call it Relay compliance or allow silent truncation.

On 2026-10-15, map limit violations to HTTP 400 non-retryable problems, preserving the shared
response algebra without misusing HTTP 413 (request-body size) for oversized query results.
Keep existing 90-day funnel-window semantics within the newly bounded date range.


## Outcomes & Retrospective

Not implemented.


## Context and Orientation

`kansoku-api/src/Kansoku/Metrics/Api.hs` defines typed metrics routes and `MetricResult`, whose
points field is a plain list. `kansoku-core/src/Kansoku/Metrics/Handler.hs` constructs requests,
parses comma-separated inputs, and converts query failures into API responses. Most routes have
no positive/max date-range check; explicit funnel windows do not bound the entire date range.
`kansoku-core/src/Kansoku/Metrics/Query.hs` compiles account-scoped SQL and uses `runSQLWith`
to concatenate all native ClickHouse blocks into a list. No result-row bound exists there.
Property groupings and experiment variants can grow with data. `Kansoku.Metrics.Query.Validate`
already validates SQL-safe names; preserve that boundary.

[ADR 3](../adr/0003-api-key-authentication-and-account-scoped-analytics.md) requires credential-derived
account scope and bound native query parameters. [ADR 4](../adr/0004-queryable-event-properties-and-identity-resolved-projection.md)
requires declared property grouping and the ordered identity projection.
[ADR 6](../adr/0006-exposure-based-experiment-analytics.md) distinguishes approximate exposure counts
from exact conversion/funnel results and promises empty success for valid no-data queries.
Retain these meanings. The response shape is owned by the completed error-contract prerequisite.

The relevant catalog is `mori://shinzui/haskell-jitsurei/docs/api-relay-pagination`. Its default
is cursor traversal of growing collections. A metric series is computed over an evolving event
set, and clients consume the aggregate as a whole; independently recomputed pages can disagree.
This plan adopts an explicitly documented bounded complete answer, not that catalog's narrow
reference-data exemption. Record the deviation in a new local ADR during implementation. There
is no existing local ADR authorizing unbounded metric results or this proposed limit policy.


## Plan of Work

### M1: Publish and enforce input limits consistently

Wait for all of `docs/plans/23-standardize-problem-details-and-the-generated-api-contract.md`.
Define shared public constants and documentation in
`kansoku-api/src/Kansoku/Metrics/Limits.hs`, and validated core query input construction in
`kansoku-core/src/Kansoku/Metrics/Query/Validate.hs` or a closely scoped adjacent module.
A valid time interval is half-open from inclusive to exclusive with 1..366 days. Require it
for every implemented route, including sessions, retention, experiments, funnels and ratios,
regardless of optional parameters. Keep not-implemented placeholders returning their existing
404; their input semantics are not invented here.

Validate comma-separated funnel input at 20 non-empty steps; preserve ordering and repeated
step semantics. Normalize retention offsets once to their existing canonical unique order,
count distinct offsets, require each in 1..365 and permit at most 32; offset zero remains an
implicitly included cohort point, not a user-supplied offset. Default offsets remain 1,7,14,30.
Use total validation without overflow-prone Int date arithmetic. Return 400 non-retryable
`invalid_date_range`, `query_range_too_large`, `too_many_funnel_steps` or
`invalid_retention_days`/`too_many_retention_days` as appropriate. Keep existing codes where
an existing case already has one. Add all new codes through the established problem catalog.
Validation failures must not acquire a query connection. Direct exported execution functions
must also enforce the same limits so non-HTTP callers cannot bypass them.

### M2: Bound results at the query boundary

Introduce an explicit execution error type separating compile/input faults, result overflow and
storage failure; do not misclassify an intentional overflow as clickhouse_unavailable. Every
implemented query path must pass through one bounded execution helper. Wrap complete aggregate
SQL with an outer projection of bucket, group_key, value, the existing deterministic order,
and `LIMIT 10001`. The extra row is an overflow witness: exactly 10,000 rows succeeds; 10,001
means the request cannot be answered within the contract. Apply the cap after grouping, totals,
ratios, identity resolution and funnel computations, never to raw input events. This bounds
transferred result rows, not database scan cost or execution duration; do not claim otherwise.

Inspect `mori://KovalevDima/ClickHaskell` through Mori before changing native selection, block
handling or query construction. Preserve current per-block field-order repairs and all query
parameters. A small high-cardinality fixture must prove the outer projection and order work
through the actual driver before applying the wrapper to every SQL family. Never collect the
unbounded list and then call take. Overflow returns a sanitized HTTP 400 problem with code
`metric_result_too_large`, retryable false and guidance to reduce the range/grouping. It returns
no partial MetricResult. Keep normal storage failures retryable 503 and rethrow asynchronous
cancellation rather than swallowing it in `try @SomeException` conversions.

### M3: Prove completeness and publish the exception

Extend `kansoku-core/test/Kansoku/Metrics/HandlerSpec.hs`, `Kansoku/QuerySpec.hs` and add
`Kansoku/Metrics/LimitsSpec.hs` plus isolated database-backed cases. Test before, at and beyond
all bounds, multiple driver blocks, high-cardinality properties and experiment variants. Existing
metric fixtures below the limits must return exactly the same aggregates in the same order;
no-data success stays empty. Account scoping and declared-property validation stay intact.

Update route descriptions and `MetricResult` schema with the maximum points and query limits;
regenerate docs/api/openapi.json. Add stable problem examples and client tests proving 400
limit violations are permanent, not retried as dependency outages. Update
`docs/guides/query-metrics.md` and create the local ADR describing fixed limits, complete-or-error
behavior, and the explicit pagination-standard deviation. Use the profiled ADR ID/log workflow.
Future unbounded resource collections remain subject to the Relay standard.


## Concrete Steps

All commands run from the repository root inside `nix develop`.

```bash
mori registry search ClickHaskell
mori registry show KovalevDima/ClickHaskell --full
mori registry docs KovalevDima/ClickHaskell
cabal test kansoku-core-test --test-options='--match Kansoku.Metrics.Limits' --test-show-details=direct
cabal test kansoku-core-test --test-options='--match Kansoku.Metrics.Handler' --test-show-details=direct
cabal test kansoku-core-test --test-options='--match Kansoku.Query.buildSQL' --test-show-details=direct
cabal test kansoku-client-test --test-show-details=direct
just openapi
nix build .#kansoku-server .#kansoku-client
```

Wire the named new specs into Cabal and test/Spec.hs; ensure the filters execute nonzero examples.
Database-backed acceptance must use a fresh private ClickHouse process and migrated fixtures,
never the ambient development analytics database. The final acceptance child provides common
orchestration; during this child record the isolated launch/fixture commands actually used.


## Validation and Acceptance

Observe 200 for a valid 366-day interval and 400 for 367 days or a reversed/empty interval.
Twenty funnel steps are admitted, twenty-one rejected without querying storage. Thirty-two
distinct valid retention offsets are admitted and thirty-three rejected. Duplicate retention
values normalize consistently. Exactly 10,000 points returns a complete response; 10,001
produces metric_result_too_large with no partial success body. At least one grouped property
query and one experiment-family query must prove this through the real native driver; all
SQL families must have coverage proving the shared bound wraps their final aggregate. Repeated
in-bound fixture queries retain order and exact prior values. Failure and cancellation must
release query-pool resources. Contract conformance must describe actual problem media types and
result caps. No database availability failure may be reported as an empty success.


## Idempotence and Recovery

No event or database schema migration is required. Fixtures are disposable and rerunnable only
inside private databases. Deploy server, client, docs and generated contract together; rollback
restores the former unbounded policy as an explicit contract rollback. Do not remove historical
data or apply LIMIT to ingest. Each query failure releases its pooled connection.


## Interfaces and Dependencies

Hard prerequisite: all of `docs/plans/23-standardize-problem-details-and-the-generated-api-contract.md`.
This child owns `Kansoku.Metrics.Limits`, validated input construction and the typed bounded-query
execution result. Keep default public limits fixed so documentation and validation cannot drift
with ambient configuration. The Hurl/CI child consumes the published values and stable codes.
Use the parent, child and intention trailers from frontmatter for implementation commits.
