---
id: 35
slug: rolling-active-users-retention-modes-and-lifetime-cohorts
title: "Rolling active users, retention modes, and lifetime cohorts"
kind: exec-plan
created_at: 2026-10-15T13:44:34Z
intention: "intention_01m4zwwdrjesytazp5tb39fe3n"
master_plan: "docs/masterplans/5-act-on-rev-1-close-silent-loss-paths-add-metric-filters-and-enrich-web-analytics.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-15T13:44:34Z
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-15T15:43:15Z
      verdict: "changes-requested"
      note: "Original draft review found correctness gaps; findings corrected by the accompanying update, with native acceptance still required."
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-15T15:43:15Z
      mode: "update"
      note: "Reconcile first-release APIs, domain semantics, dependencies and acceptance with the source-validated MP-5 review."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-15T23:02:27Z
      mode: "implement"
      note: "Begin exact rolling users, closed-day retention modes and retained-history lifecycle after EP-34 whole-child acceptance."
---

# Rolling active users, retention modes, and lifetime cohorts


## Purpose / Big Picture


Expose exact rolling users, stickiness, retention and lifecycle with precise calendar boundaries
and honest history limits. Prevent recent cohorts and expired history from masquerading as zero
retention or newly acquired users.

## Progress


- [x] M1: Rolling7/rolling30 and stickiness use exact identities and half-open UTC windows.
- [x] M2: On/on-or-after retention distinguishes immature offsets and retained-history cohorts.
- [x] M3: Lifecycle counts reconcile to daily actives with bounded execution.

## Surprises & Discoveries


The old fixture claimed days 1,3,9 produce three rolling7 users on day 9; day 1 is outside
that window. A 366-day response range does not bound a lifetime-first-activity scan.
Raw retention also prevents any truthful claim of first activity "ever" once older facts expire.

## Decision Log


On 2026-10-15 define lifetime as first activity in retained account history and publish that
qualification. Use exact canonical users across all HTTP user metrics. Missing observation time
is not zero retention.

Capture the request-start UTC date and reject an exclusive `to` after it on users, stickiness,
retention and lifecycle. This is the plan's chosen equivalent to response as-of metadata.
User filters and up to two group dimensions define the same population throughout historical
lookback; each group has its own first matching retained activity. Reserved measure/status/
cohort/offset labels are metadata alongside those nullable groups. Ungrouped rolling/daily
measure series fill closed-day zeroes; absent dimension groups remain absent. Calendar users
retain the existing exact grain semantics. Lifetime scans remain native-budgeted work.
The expanded `scripts/identity-bench.py --activity` gate measures all seven compiler query
families with their actual extended/retained cache scopes, including valid empty lifetime
results after older history is appended. Per-query database time/memory limits complement the final point cap.

## Outcomes & Retrospective


All three milestones are Complete. The first focused owned run passes six examples: two no-storage
observation/grain validations and four native families covering all three milestones, hand
counts, current exact subjects, historical filters, retained deletion, maturity, metadata,
point boundaries and native memory exhaustion on every family. Final source `just check` also passes 345 deterministic core, 17 client and four probe
examples, generated/OpenAPI checks, all fourteen strict ADR records and telemetry/lifecycle
modes. Packaged acceptance now passes on server candidate `c37cc06`:
`.dev/acceptance/run-rk0e6ksi/sanitized` (394 core, 18 live-client examples, four probes,
63 executed Hurl requests, recovery/limits/replay/identity, geography startup/privacy/defaults
and all three telemetry modes). The actual ordinary-producer workflow proves rolling and
stickiness counts, mature/cumulative retained-history retention, lifecycle and closed-day
validation through real asynchronous publication and public HTTP.

Consumer `mori://shinzui/kansoku-ts` commit `3501e45` pins `c37cc06`; generated activity
window/mode/cohort and shared controls type-check, with 62 unit examples, two SSR examples
and post-commit `just check` including contract drift, package validation and unchanged bundle
budgets. Seven unconfigured live SDK cases remain EP-38's joint obligation. M3's partition/cap/resource and large-history performance acceptance now passes as well.

The owned `--activity` benchmark passes all 28 five-run-median comparisons over three million
recent facts plus seven million older facts, with the actual public/extended/history evidence
scopes checked against compiler SQL. Private report:
`.dev/acceptance/identity-bench-zyat93dw/report.json`. Apple M1 Max, 64 GiB, native 26.8.2.7,
four database threads: all resolved/raw ratios are 1.09–1.54 (below 2×); the largest resolved
native median is 589 ms and largest recorded cold native duration 1291 ms. Peak native memory
is 449500257 bytes warm and 450115541 cold, below the 536870912-byte default query budget.
Lifetime/lifecycle cost increases with retained history: grown day lifecycle is 291/399 ms
raw/resolved and lifetime retention 291/360; grown month is 337/441 and 397/589. These are
workload measurements, not constant-cost or unrestricted-history guarantees. Required empty
lifetime results after older history are measured rather than treated as missing tests.

ADR-14 is Accepted. EP-40 must preserve the same current-trait population throughout lookback;
EP-37 retention/erasure can move retained first-seen; EP-38 must rerun this expanded performance
gate alongside final SDK/browser and capacity acceptance. No permanent first-seen state or
future-day zeroes are introduced.

## Context and Orientation


`Query.hs` contains user, retention and conversion builders; `Metrics/Api.hs` owns parameters.
EP-26/ADR-9 caps output, not database work. EP-32 supplies the rich resolved source; EP-31
supplies filter/group contracts. Read [ADR-6](../adr/0006-exposure-based-experiment-analytics.md)
and [ADR-9](../adr/0009-bounded-complete-aggregate-responses.md).

## Plan of Work


### M1: Rolling and stickiness


Users accepts window=calendar|rolling7|rolling30; rolling requires day grain (default day).
For UTC bucket day d and N=7 or 30, count distinct canonical subjects with activity in
`[d-(N-1) days,d+1 day)`. Extend scan by N-1 days, not N, and return only requested buckets.
Calendar counts also use the exact identity path and activity-event population from EP-31;
identify/identify_once/alias/group do not constitute activity. Cohorts and lifecycle use the
same exclusion even during historical lookback, so profile updates cannot create or retain users. Stickiness uses exact daily
active divided by rolling30 active for each day, zero when denominator zero; publish separate
points with group.measure=daily_active, rolling30_active, ratio, rather than storing numerical
measures in dimension labels. Apply filters identically to both populations. No percentage scale.

### M2: Retention


Retention accepts mode=on|on_or_after and cohort=window|lifetime. from/to bounds the observed
activity interval; cohort days fall within it. Window cohort is first matching activity inside
that range. Lifetime cohort is first matching activity over retained history for that same
metric population; historical scans must apply identical event filters and current trait filters.
For on, count users active on day cohort+N; for on_or_after, count those active on any day
from cohort+N through cohort+largest-requested-offset, including unrequested intermediate days.
Do not filter to the requested offsets before computing the cumulative result.

Only emit on offsets whose full UTC day ends by to; on_or_after requires the full maximum
offset horizon for that cohort, otherwise omit its nonzero offsets. Offset zero always gives
cohort size. Document the omission as immature observation, distinct from a mature zero.
Use a request-start as-of time to avoid treating future days as observed, and return the actual
observation cutoff as response metadata or enforce an equivalent documented date validation.
Choose one approach in the API type before implementation, and use it across lifecycle/users:
for this initial version reject to later than the current UTC day, so all included days are closed.

Lifetime may scan all retained evidence. Enforce EP-31's 30-second/512-MiB default per-query native limits, preserve cancellation, and
report resource exhaustion as 400 query_resource_limit with no partial result. Do not claim EP-32 eliminates this scan.
Document first-seen shifts after retention/erasure; there is no permanent first_seen guarantee.

### M3: Lifecycle


Per complete UTC day, new means first retained matching activity that day; returning means
active that day and previous day; resurrecting means active that day after an inactive previous
day with earlier retained activity; dormant means active previous day and inactive today.
Emit nonnegative counts with group.status; any negative plotting convention belongs to the UI.
New+returning+resurrecting equals exact daily actives. Read one predecessor day plus retained
history for first-seen. Validate date/offset limits before checking out a connection.

## Validation and Acceptance


Three distinct users active on days 1,3,9 produce rolling7=2 on days 7 and 9. Test exact lower
and upper UTC boundaries, zero denominator, stitched identities and filters. For offsets 1,7,
a user returning only on day 5 counts for cumulative offset 1 but not 7. Recent cohorts omit
immature results; mature missing activity emits zero. A user predating the request is excluded
from a lifetime cohort and included in window mode. Retention deletion changes the documented
retained-history first-seen result. Test lifecycle partition sums and positive dormant count.
Resource exhaustion and 10001-point overflow return complete-or-error problems; no pending
native tests may count as acceptance.

## Concrete Steps


Run commands from the repository root inside `nix develop`. Use the private databases owned
by `scripts/acceptance.sh` and `Kansoku.ClickHouseTestSupport`, not an ambient development
stack: native fixtures mutate tables. Extend that harness for the scenarios in this plan.

```bash
cabal build all --enable-tests
just openapi
just contracts
just check
just acceptance
```

Use focused Hspec examples while developing. Before marking Complete, require nonzero example
counts, no pending required integration tests, regenerated contract checks, and the packaged
executable acceptance above. Record only the relevant evidence here. This follows
[ADR-10](../adr/0010-owned-executable-acceptance-environments.md).

## Idempotence and Recovery


Additive routes/parameters, with deliberate pre-release correction to exact user populations. No permanent first-seen state is introduced; retention affects available historical facts.

## Interfaces and Dependencies


Required complete child artifacts: `docs/plans/26-bound-analytics-query-inputs-and-result-cardinality.md`, `docs/plans/31-metric-property-filters-and-dual-grouping.md`, `docs/plans/32-time-aware-identity-bindings-and-bounded-resolution-cost.md`.

Hard dependencies: EP-26, EP-31 and EP-32 Complete. See `docs/plans/31-metric-property-filters-and-dual-grouping.md` and `docs/plans/32-time-aware-identity-bindings-and-bounded-resolution-cost.md`. EP-37 retention and EP-38 guides must preserve the retained-history qualification.

Revision note (2026-10-15): reviewed against the current source and revised for first deployment.
[ADR-11](../adr/0011-initial-release-analytics-contracts.md) records the proposed cross-plan
contracts; implementation must supply the acceptance evidence before those contracts become
accepted runtime guarantees.
