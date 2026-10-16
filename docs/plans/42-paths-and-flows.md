---
id: 42
slug: paths-and-flows
title: "Paths and flows"
kind: exec-plan
created_at: 2026-10-15T15:14:00Z
intention: "intention_01m4zwwdrjesytazp5tb39fe3n"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-15T15:14:00Z
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-16T11:26:52Z
      mode: "implement"
      note: "Implement bounded canonical-user paths, page flows and reverse traversal with native acceptance"
---

# Paths and flows

This ExecPlan is a living document. Update its living sections and durable ADRs as work
proceeds. It is a standalone plan, independent of
`docs/masterplans/5-act-on-rev-1-close-silent-loss-paths-add-metric-filters-and-enrich-web-analytics.md`,
that implements the path analysis the product vision lists as later scope and the
2026-10-15 assessment named as a remaining product-analytics gap.


## Purpose / Big Picture

`GET /metrics/paths` will answer "what do users do after X" and "how do users get to Y":
starting from an event (or ending at one), it returns the most common sequences as weighted
transitions, step by step, with a drop-off node where sequences end. With `by=route` it
becomes a page-flow report over `page_view` events, the "where do visitors go from the
pricing page" view every web-analytics tool offers.


## Progress

- [x] M1 (2026-10-16): Start-anchored event paths return exact per-step user counts, deterministic top-K and an `(other)` fold. Native fixtures prove exclusions, filters, first-start ownership, replay handling, account isolation and 400 input faults.
- [x] M2 (2026-10-16): Route flows, entry mode, consecutive-route collapse and `(end)` nodes pass native fixtures, including bot exclusion and UTF-8/quoted route parameters.
- [x] M3 (2026-10-16): Last-end reverse paths pass millisecond/tie/window fixtures and the real HTTP route. OpenAPI is regenerated/current and lints with zero errors; typed client serialization passes. The guide and ADR 9 record ordering and flow semantics.


## Surprises & Discoveries

The current funnel implementation already provides millisecond/event-ID sorting and
canonical replay-safe input through `resolvedSource`; the plan's old `windowFunnel`
reference is historical. Paths reuse that sorter and the identity query pool rather
than querying the stable public view without its request-scoped identity bounds.

The current development shell lacked libmaxminddb in pkg-config. Build and acceptance
commands therefore run through `nix develop -c`.


## Decision Log

- Decision: Paths are computed per user from `analytics.events_resolved` with array
  functions, bounded by `steps` (1 to 10, default 5), `top` (1 to 20 per step, default 10),
  a window of at most 90 days from the anchor, and the global point cap; the first anchor
  occurrence per user is used.
  Rationale: Per-user arrays are the ClickHouse idiom for sequences; the bounds keep the
  answer complete-or-error under ADR 9 instead of streaming an unbounded graph.
  Date: 2026-10-15
- Decision: Transitions are counted in unique users, not occurrences, and a user contributes
  one sequence per query.
  Rationale: Matches PostHog's paths and keeps counts comparable with funnels.
  Date: 2026-10-15

- Decision: Reverse traversal starts at the last physical anchor; route collapse follows
  anchor/window selection in traversal order. Both directions emit `(end)` on observed
  exhaustion, and event mode requires an anchor.
  Rationale: Preserve first/last occurrence timestamps and give step 1 the immediate
  successor/predecessor meaning with a single exhaustion marker.
  Date: 2026-10-16
- Decision: Each step retains K transitions, ties resolved by source/target names, plus
  one remainder with both source and target `(other)`. Final ordering includes that
  point by its summed count. CSV allowlists/denylists accept at most 100 event names;
  route anchors accept at most 1024 UTF-8 bytes. Filters precede anchoring.
  Rationale: A single folded edge can combine several origins, so a real source would
  misrepresent it. One transition per user/step makes the sum an exact user count.
  These input bounds retain the established bounded-query contract.
  Date: 2026-10-16


## Outcomes & Retrospective

All three milestones are complete. `GET /metrics/paths` and the generated Haskell
`pathsClient` support forward event paths, forward/entry page flows and reverse paths.
No schema or dependency changes were required. The query reuses account-scoped identity
preparation, native parameter binding, canonical replay handling, filter compilation,
resource limits and the final complete-response guard.

Acceptance on 2026-10-16: `nix develop -c cabal build all --enable-tests` passed;
`nix develop -c python3 scripts/paths-acceptance.py` passed 8 examples with zero failures
or pending cases against owned ClickHouse with two-row blocks. This includes the maximum
210-point answer, numeric step order, count conservation and native memory-limit failure.
`nix develop -c python3 scripts/deterministic-tests.py` passed 372 core examples, 20 client
examples and 4 probe tests. OpenAPI regeneration/currentness passed and lint reported zero
errors (existing-style documentation warnings remain). Formatting and strict ADR validation
passed for all 19 records. ADR 9 now holds the durable semantics and closed ordering rule.

The top-K fold necessarily loses individual edge connectivity for the omitted transitions;
the synthetic source is explicit in the contract. `(end)` describes observed exhaustion
inside the selected date/time window. Neither marker claims permanent user churn. Array
construction remains subject to the existing native work limits rather than truncating
raw timelines to produce partial successful answers.


## Context and Orientation

Funnels compute per-user ordered behaviour in `funnelAggregate`
(`kansoku-core/src/Kansoku/Metrics/Query.hs`) with the array engine delivered by
`docs/plans/36-funnel-modes-and-experiment-exposure-diagnostics.md`. Paths reuse
`sortedTimelineSQL` in `kansoku-core/src/Kansoku/Metrics/Query/Funnel.hs`, sorting tuples
of millisecond time, immutable event ID and label. [ADR 15](../adr/0015-deterministic-selected-funnel-chains-and-exclusive-exposure-diagnostics.md)
explains deterministic ties and replay-safe input; paths deliberately select only the
first start or last end rather than the funnel's best attempt. Routes, bounds and the closed ordering rules are in
`kansoku-api/src/Kansoku/Metrics/Api.hs` and
[ADR 9](../adr/0009-bounded-complete-aggregate-responses.md); result points carry `bucket`,
`group` and `value`. The `route` dimension is `path(url)` ([ADR 4](../adr/0004-queryable-event-properties-and-identity-resolved-projection.md)
describes the projection), and filters come from
`docs/plans/31-metric-property-filters-and-dual-grouping.md`. No cross-repository ADR applies.

A "transition" is an ordered pair of consecutive events in one user's sequence at a given
step index. "Top-K fold" means that, per step, only the K most common transitions are
returned and the rest are summed into a single `(other)` target.


## Plan of Work

### M1: Start-anchored event paths

Add `paths` to the metrics route record with `from`, `to`, `start` (event name), `steps`,
`top`, `window` (seconds, max 7,776,000), `events` (optional comma allowlist), `exclude`
(optional comma list), `filter`, and `by` (`event` default). Implement
`buildPathsSQLAggregate`: per user, the sorted array of `(occurred_at, event_name)` within the
range and allowlist; find the first `start`; take the following events within `window` up to
`steps`; emit `(step_index, from, to)` pairs with `arrayZip` and `arrayJoin`; a sequence that
ends before `steps` emits a final pair to `(end)`. Aggregate `uniqExact(canonical_user)` per
triple, keep the top-K per step with `(other)` for the remainder, and order by step then value
descending then names. Points: `group = {step, from, to}`, `value = users`.

### M2: Page flows

With `by=route`, the sequence is `path(url)` of `page_view` events; consecutive identical
routes collapse. When `start` is omitted, sequences begin at each user's first page view in
the range, which gives an entry-page flow; `(end)` marks the last page. Exclude bot-flagged
rows when `is_bot` exists (`docs/plans/33-acquisition-and-device-enrichment-with-bot-flagging.md`).

### M3: End-anchored paths and contract

With `end=` instead of `start=`, reverse the window: take the `steps` events before the last
occurrence of `end` per user within the window. Regenerate OpenAPI and the client, document
the route in `docs/guides/query-metrics.md` ("Paths") with an event example and a page-flow
example, and add the paths ordering to ADR 9's closed list.


## Concrete Steps

```bash
nix develop -c cabal build all --enable-tests
nix develop -c python3 scripts/paths-acceptance.py
nix develop -c just openapi
nix develop -c just openapi-check
```

Example:

```bash
curl -s --get http://localhost:8080/metrics/paths -H "Authorization: Bearer $TOKEN" \
  --data-urlencode from=2026-07-01 --data-urlencode to=2026-08-01 \
  --data-urlencode start=signup_completed --data-urlencode steps=4 --data-urlencode top=5
```


## Validation and Acceptance

1. M1: a fixture with users following `signup_completed → onboarding_started →
   feature_used` and `signup_completed → (end)` returns two step-1 transitions with the right
   user counts; `top=1` folds the second into `(other)`; `exclude=page_view` removes page views
   from sequences; `steps=11` returns 400.
2. M2: page flows from `/pricing` list `/signup` and `(end)` with correct counts; identical
   consecutive routes collapse.
3. M3: end-anchored paths into `payment_completed` list the preceding steps in reverse order.
4. The shared 10001-row overflow witness remains in generated SQL; the stronger paths bounds are proved with a 210-point maximum fixture. Account isolation, native resource errors and problem codes hold.


## Idempotence and Recovery

New route only; no schema change.


## Interfaces and Dependencies

Hard dependency: `docs/plans/26-bound-analytics-query-inputs-and-result-cardinality.md`
Complete. Soft: `docs/plans/36-funnel-modes-and-experiment-exposure-diagnostics.md` (shared
array helpers), `docs/plans/31-metric-property-filters-and-dual-grouping.md` (filters),
`docs/plans/32-time-aware-identity-bindings-and-bounded-resolution-cost.md` (cost). Claims
`/metrics/paths` and the `(end)` and `(other)` node names.


Revision note (2026-10-16): Grounded the implementation in the completed funnel engine,
made reverse/collapse/folding behavior explicit, and added an owned native acceptance
runner that rejects missing storage and zero/pending examples. No schema changes.
