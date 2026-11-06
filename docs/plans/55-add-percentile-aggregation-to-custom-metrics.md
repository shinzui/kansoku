---
id: 55
slug: add-percentile-aggregation-to-custom-metrics
title: "Add percentile aggregation to custom metrics"
kind: exec-plan
created_at: 2026-11-06T03:22:54Z
intention: "intention_01m6qe0rkpe9dap7p6pez9cask"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-11-06T03:22:54Z
---


# Add percentile aggregation to custom metrics

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log, and Outcomes & Retrospective current during implementation. Follow `agents/skills/exec-plan/FRICTION.md` for implementation friction and `agents/skills/exec-plan/ADR.md` for durable architecture decisions.

## Purpose / Big Picture


Implement [IR-7](../improvement-requests/add-a-percentile-aggregation-to-custom-metrics.md): clients can request p50, p75, or p95 of a declared numeric event property through `/metrics/custom`, save that definition, and pair its results with counts of the same samples. A quantile is a fraction of an ordered population; p75 means quantile 0.75. For samples 10, 20, 30, 40, this plan defines p75 as 32.5 using interpolation between adjacent values. Existing filtering, grouping, time buckets, account isolation, and cohort selection apply.

This plan creates one scalar percentile per request. Histograms, multiple quantiles per request, percentile ratio components, and UI work are outside scope. Creation of this document does not implement the feature.

## Progress


- [ ] Milestone 1: Ad-hoc percentile requests validate and return exact results through the public API and native database path.
- [ ] Milestone 2: Saved percentile definitions roundtrip and execute with existing defaults, filters, and isolation guarantees.
- [ ] Milestone 3: Grouped and bucketed percentile/count parity, edge cases, generated contracts, and user documentation pass the required gates.

## Surprises & Discoveries


## Decision Log


Decision (2026-11-05): Use exact inclusive interpolation (R-7) on finite Float64 property values. For sorted samples x with size n, interpolate at zero-based position (n−1)q; one sample returns itself. This makes even-sized medians intuitive and provides deterministic fixtures without an approximation error budget. Exact aggregation uses memory proportional to the number of samples; existing resource limits remain mandatory.

Decision (2026-11-05): Require a finite quantile strictly between zero and one, with no default; reject quantile on other aggregations and reject percentile in either ratio component. Save the field as `quantile`, matching the URL parameter. Old definitions without the field remain valid.

Decision (2026-11-05): Preserve the result shape and pair with existing count requests. Apply `prop:amount:set` (or the chosen property) explicitly to both requests, with identical events, dates, filters, grouping, and grain. Count requests omit property/quantile aggregation parameters. This counts the numeric population rather than all matching events and requires no new count aggregation.

## Outcomes & Retrospective


## Context and Orientation


`kansoku-api/src/Kansoku/Metrics/Definition.hs` owns `Aggregation`, `MetricDefinition`, and the untagged simple/ratio JSON union. Simple definitions currently have eight fields, including `aggregationProperty`; the union parser explicitly rejects unknown top-level fields. Saved definitions are JSON in PostgreSQL, managed by `kansoku-core/src/Kansoku/Metrics/DefinitionStore.hs` and `kansoku-core/src/Kansoku/Metrics/DefinitionHandler.hs`. No storage migration is expected.

`kansoku-core/src/Kansoku/Metrics/Custom.hs` constructs ad-hoc definitions, validates both ad-hoc and saved inputs, and merges saved filters/defaults into execution requests. `kansoku-core/src/Kansoku/Metrics/Handler.hs` rejects mixed saved/ad-hoc selectors and validates loaded definitions again. `kansoku-api/src/Kansoku/Metrics/Api.hs` declares the custom route, while `kansoku-core/src/Kansoku/Metrics/RequestValidation.hs` maintains its authenticated parameter allowlist. Both must recognize the new parameter.

`kansoku-core/src/Kansoku/Metrics/Query.hs` compiles simple aggregations in `buildSimpleSQL`, `propertyAggregateSQL`, and `simpleAggregateSQL`. Numeric aggregation already excludes null property values, selects canonical events (deduplicated accepted event facts), and switches to resolved events when traits or cohorts require identity resolution. `kansoku-core/src/Kansoku/Metrics/Query/Property.hs` validates numeric declarations and converts missing, null, incompatible, and non-finite historical values to SQL NULL. A cohort is a saved set of users selected at query time. Reuse these paths rather than introducing independent populations.

Relevant consulted decisions are [ADR-4](../adr/0004-queryable-event-properties-and-identity-resolved-projection.md), which owns declared properties, finite numeric extraction and replay-safe canonical facts; [ADR-9](../adr/0009-bounded-complete-aggregate-responses.md), which requires bounded inputs and complete results or an error; [ADR-10](../adr/0010-owned-executable-acceptance-environments.md), which requires disposable owned databases for native tests; and [ADR-20](../adr/0020-custom-metric-definitions-and-bounded-or-filters.md), which owns shared validation, saved defaults, account isolation and bounded AND/OR filters. [ADR-18](../adr/0018-stable-reader-sql-and-real-consumer-conformance.md) was also consulted: this work leaves the separate stable SQL reader interfaces unchanged.

`kansoku-core/test/Kansoku/Metrics/CustomSpec.hs` covers definition validation and compiler behavior. `kansoku-core/test/Kansoku/Metrics/HandlerSpec.hs` covers HTTP boundaries, and `kansoku-core/test/Kansoku/OpenApiSpec.hs` covers public schema. `scripts/custom_metrics_acceptance.py` already exercises public custom metrics, saved CRUD, replay, cohorts, traits and foreign accounts on owned stores. Extend this existing proof; its pagination assertions currently expect exactly five saved definitions, so explicitly account for new owned resources rather than weakening completeness assertions.

## Plan of Work


### Milestone 1: A working ad-hoc percentile


Add `Percentile` to `Aggregation` and its text/JSON conversion, and add `quantile :: Maybe Double` to `MetricDefinition`. Permit the JSON key in the simple-definition allowlist. Ensure missing quantile decodes as Nothing for historical definitions; omit absent quantile when encoding if necessary to preserve existing exact JSON roundtrip assertions. Update record constructors, builtins, fixtures and exhaustive matches found by searching for `MetricDefinition` and `Average` across the repository.

Extend `adHocDefinition` and shared validation to require a finite q with 0 < q < 1 and a declared numeric property for percentile. Reject missing q, zero, one, out-of-range, NaN/infinity, nonnumeric property, quantile on other aggregations, and percentile in either ratio component. Do not let implicit ratios created with `denominatorEvents` bypass the restriction. Validate in the compiler too so internal callers cannot silently fall through to count when a percentile definition is malformed.

Add `QueryParam "quantile" Double` adjacent to property on the custom route; update `customHandler`, its type, the mixed-parameter rejection, and the authenticated allowlist. Preserve existing problem responses and authentication order. Malformed numeric text may follow the existing route decoding error path; semantic invalidity must use the shared invalid-metric path. Duplicate or valueless quantile parameters must be rejected by request validation.

Compile percentile through `propertyAggregateSQL` using `quantileExactInclusive(q)(propertyExpression)`, retaining numeric NULL exclusion, account/date predicates, source selection, grouping, and resource budgets. Render q only from the validated finite numeric value as a canonical numeric SQL literal, never from raw caller text; all existing filter operands remain native parameters. Return the same Float64 value column. Do not compute percentiles in Haskell or average partial percentiles across buckets.

First prove a minimal public request through the native driver using samples 10, 20, 30, 40 with q=0.75 and expected value 32.5 in `scripts/custom_metrics_acceptance.py`. This checks the aggregate's availability and result decoding in the repository-pinned database before expanding variants. Run the deterministic and owned custom acceptance commands below. This milestone is accepted when the minimal public proof and invalid-input tests pass.

### Milestone 2: Saved definitions


Carry quantile through POST, GET, PUT and execution of saved simple definitions. Reuse `validateCustom` on write and execution. Add roundtrip tests with quantile present and absent, plus legacy sum/count/ratio payloads. Saved grouping and grain remain defaults overridden by request grouping/grain; saved and request filters remain conjoined under their combined budget. Saved quantile is part of the definition, not an execution override: `metric=<name>&quantile=...` must fail.

Extend the owned public scenario to create, read, execute, update and delete a percentile definition, comparing each result to the equivalent ad-hoc request. Include invalid writes, foreign-account access, cohort filters/grouping, saved trait filters and invalid loaded-definition validation. Register every created resource with `OwnedResources`; preserve cleanup and pagination checks. Acceptance is exact saved/ad-hoc point equality and unchanged legacy definition behavior under the deterministic and owned custom acceptance gates.

### Milestone 3: Complete semantics and published contract


Expand known-sample fixtures to two property groups and two days, checking p50, p75 and p95 separately per group/bucket and week aggregation from underlying samples. For each group/day use an explicit expected-value map, not a sum of returned percentiles. Cover singleton, repeated and negative values, zeros, absent groups, an empty range, missing/null/incompatible values, replay before merges, and foreign-account exclusion. Use native historical fixtures where public ingestion properly rejects incompatible values. Compare percentile and count point keys with identical explicit `prop:amount:set` filters; assert each count equals eligible canonical samples. A group containing only unset values must be absent from both results. Percentile follows average's sparse simple-metric behavior: no synthetic zero percentile and no point for an empty bucket/group, including an entirely empty result. Verify this through HTTP.

Update descriptions in `kansoku-api/src/Kansoku/Api/OpenApi.hs`, regenerate `docs/api/openapi.json`, and test the quantile schema and optional legacy field. The generated typed route in `kansoku-client/src/Kansoku/Client/Metrics.hs` must build; update existing custom-client invocations if their arity changes. Document exact interpolation, finite q bounds, numeric eligibility, empty results, sample-count pairing and non-atomic separate requests in `docs/guides/query-metrics.md` and update `docs/capabilities/custom-metric-definitions.md`. Separate requests can observe newly arriving data, so parity is a same-population recipe, not a transactional snapshot guarantee.

Update ADR-20 with the new aggregation contract and numeric source behavior, following the profiled ADR workflow; maintain affected document timestamps and bundle logs using repository tooling. Run final gates below, record concise evidence, triage implementation friction, and fill the retrospective before marking complete.

## Concrete Steps


Run commands from the repository root with Nix, Bun and the repository tools available. No ambient database is needed for deterministic checks. Native acceptance needs permission to launch the harness's owned PostgreSQL and ClickHouse processes and available build dependencies.

```bash
nix develop -c just build-with-tests
nix develop -c just deterministic-test
nix develop -c just custom-metrics-acceptance
```

Run the first native proof during milestone 1, then extend and rerun it after the saved-definition and edge-case changes. Successful runs exit zero with executed assertions, not skipped or pending integration cases. The custom acceptance target builds components and starts its own services through the existing harness.

After contract and documentation edits, regenerate and check the final candidate:

```bash
nix develop -c just openapi
nix fmt
nix develop -c just check
nix develop -c just custom-metrics-acceptance
git diff --check
```

`just check` includes test builds, deterministic suites, generated OpenAPI/contracts drift, schema lint, documentation profile checks and strict ADR validation. Preserve unrelated changes and inspect the generated diff. Record commands and short result summaries in Progress when the corresponding milestone passes. Implementation commits use Conventional Commits with both trailers:

```text
ExecPlan: docs/plans/55-add-percentile-aggregation-to-custom-metrics.md
Intention: intention_01m6qe0rkpe9dap7p6pez9cask
```

## Validation and Acceptance


IR-7 AC-1 passes when public requests with `events=payment_completed&aggregation=percentile&property=amount&quantile=0.75` yield the independently calculated per-group/per-bucket results, with normal filters, cohorts and time grains. For 10,20,30,40, expected p50=25, p75=32.5 and p95=38.5; use a small floating-point tolerance such as 1e-9. Replaying event IDs cannot change any value or eligible count. Invalid quantiles and unsupported combinations return 400 without executing a percentile query.

AC-2 passes when a saved definition shaped as below roundtrips, executes identically to ad-hoc selection, and receives the same validation on POST, PUT and execution:

```json
{"name":"payment_p75","description":null,"eventNames":["payment_completed"],"aggregation":"percentile","aggregationProperty":"amount","quantile":0.75,"filters":["prop:amount:set"],"groupBy":["prop:plan"],"timeGrain":"day"}
```

AC-3 passes when the guide states exact inclusive interpolation (with normal floating-point rounding, no approximate estimator), excluded values, singleton behavior, sparse empty results and resource-limit behavior. AC-4 passes when percentile and count requests have identical bucket/group keys and counts equal eligible samples using matching explicit set filters. Existing count/sum/average/ratio behavior and saved payloads remain covered by regression tests. These are required outcomes; no benchmark threshold or new response field is introduced.

## Idempotence and Recovery


Builds, generators and checks are repeatable. Owned acceptance creates fresh stores and retains diagnostic evidence; rerun it after fixes without resetting ambient services or deleting unrelated resources. No database migration or backfill is planned. Existing JSON definitions remain readable by the new server; an older binary cannot understand saved percentile definitions, so remove or convert those explicitly before a downgrade. Do not silently rewrite them to averages. Exact percentile resource exhaustion must use existing query-error behavior, never truncate samples or silently substitute an approximate result.

## Interfaces and Dependencies


The public addition is `aggregation=percentile`, URL `quantile`, and optional saved-definition `quantile`. The result remains the existing metric points shape. `Kansoku.Metrics.Definition`, `Kansoku.Metrics.Custom`, `Kansoku.Metrics.Handler` and `Kansoku.Metrics.Query` own the shared implementation; PostgreSQL continues storing JSON definitions and ClickHouse performs aggregation. There is no parent MasterPlan or external prerequisite implementation.

Mori discovery identified the driver documentation at `mori://KovalevDima/ClickHaskell/docs/queries`; its native SELECT result path remains unchanged. No new dependency or version pin is selected. The upstream [quantileExactInclusive reference](https://clickhouse.com/docs/reference/functions/aggregate-functions/quantileExactInclusive) documents exact R-7 interpolation and Float64 output. Its documented implementation retains and sorts samples, so query budgets remain essential. The early native proof verifies this contract against the actual pinned executable; do not infer compatibility solely from current web documentation. If a dependency change becomes necessary, first use Mori to locate sources and verify authoritative registry releases and upstream tags before selecting bounds or workarounds.
