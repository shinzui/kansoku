---
id: 34
slug: session-analytics-duration-bounce-entry-and-exit-pages
title: "Session analytics: duration, bounce, entry and exit pages"
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
---

# Session analytics: duration, bounce, entry and exit pages


## Purpose / Big Picture


Give sessions a single meaning across count, bounce, duration, acquisition and grouping.
A session belongs to its start bucket and counts once across midnight. Lifecycle telemetry
must improve duration without making every visit appear engaged.

## Progress


- [ ] M1: Replay-safe session aggregation matches canonical raw events across insert boundaries.
- [ ] M2: Count, bounce and duration measures with entry/exit dimensions pass HTTP fixtures.

## Surprises & Discoveries


An incremental materialized view sees only each inserted block. Its `any(channel)` is not
first-touch attribution, count states are not replay-safe, and appending a backfill doubles
counts. Automatic page_leave would make the old "nothing else" bounce definition report no
bounces. Filtering events to the requested dates before finding session start truncates sessions.

## Decision Log


On 2026-10-15 session identity is account/source_service/session_id; start is the earliest
observed event, not an assumed session_start event. A bounce is a session with exactly one
page view and no engagement events. session_start, page_leave, identify, identify_once, alias,
group and experiment_viewed are lifecycle/identity events, not engagement. Other application
events are engagement events. Zero-page sessions count but are not bounces.

## Outcomes & Retrospective


Planning reviewed; no session implementation yet.

## Context and Orientation


`buildSessionsSQLAggregate` in `kansoku-core/src/Kansoku/Metrics/Query.hs` currently counts
nonempty session IDs by event bucket. EP-30 establishes canonical events; EP-33 provides
attributes/bot fields. Read [ADR-9](../adr/0009-bounded-complete-aggregate-responses.md).
The browser SDK creates producer session IDs and rotates on inactivity/reset at
`mori://shinzui/kansoku-ts/packages/kansoku-js`; server events need explicit session IDs to join.

## Plan of Work


### M1: Session projection


Own `analytics.sessions` and its query helper. Build replay-idempotent aggregate states keyed
by `(account_id,source_service,session_id)` with min/max timestamps, distinct page-view event
IDs, distinct engagement event IDs, deterministic argMin/argMax URL attributes ordered by
`(occurred_at,event_id)`, first-attribution tuple from EP-33 and max bot flag. Choose page-view
entry/exit routes specifically; a session_start with empty URL must not become the entry.
Do not key logical state by each block's start_day. A session may span arbitrary inserts;
merge its complete retained state before applying `[from,to)` to its start time and bucketing.
If a materialized aggregate cannot retain all dimensions/trait filtering correctly, use a
canonical query-time projection for that request and prove agreement. Track late arrivals:
metrics may change as the true minimum/maximum is observed. Publish retained-history limits.

Backfill only into an empty replacement target under controlled writes, or prove that every
state is idempotent under repeated input; additive count/sum states cannot pass that proof.
Reuse this projection for acquisition, replacing EP-33's equivalent query-time implementation.

### M2: Measures


`/metrics/sessions` supports measure=count (default), bounce_rate (0..1), and
average_duration_seconds. Duration is last observed event minus first, including page_leave;
it is elapsed observed duration, not active reading time. Average includes every selected
session, with one-event duration zero. Bounce is independent of duration. Count denominator is
all selected sessions; grouped results are omitted for nonexistent groups, and an ungrouped
empty bucket has count/rates/duration zero. No legacy attribution=event parameter is needed.
Entry/exit/channel and EP-31/33 dimensions accept one or two keys. Apply dimension filters to
session attributes after aggregation; a user trait filter matches a session's first resolved
user (first event with a resolved user subject), and never creates one session per participant.
Default bot exclusion follows EP-33. Explicitly reject arbitrary prop filters on sessions:
a future event-based session-selection API would need its own semantics.

## Validation and Acceptance


Two batches across midnight produce one start-day session. Duplicate delivery and rebuilding
leave page-view and engagement counts unchanged. One page_view plus page_leave remains a bounce
with positive duration; two page views or a custom engagement event do not. Identify and
experiment exposure alone do not change bounce. A session beginning before from is excluded,
not reassigned to the first in-range event; late earlier events update its start. Distinguish
identical session IDs in two accounts and two source services, empty URL lifecycle events,
missing session IDs, same-time page views, bot sessions and multiple users. Acquisition and
session count agree for equivalent session filters. Validate point bounds and account joins.

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


A rollup rebuild uses an empty target with verification before swap. Never describe aggregate-state append as inherently idempotent. No production compatibility release is required.

## Interfaces and Dependencies


Required complete child artifacts: `docs/plans/26-bound-analytics-query-inputs-and-result-cardinality.md`, `docs/plans/30-pipeline-backpressure-and-storage-outage-resilience.md`, `docs/plans/33-acquisition-and-device-enrichment-with-bot-flagging.md`.

Hard dependencies: EP-26, EP-30 and EP-33 Complete. EP-33 is `docs/plans/33-acquisition-and-device-enrichment-with-bot-flagging.md`. Owns sessions projection; EP-37 handles retention/rebuild, EP-38 publishes its stable read semantics. EP-40 later supplies current traits under the session rule above.

Revision note (2026-10-15): reviewed against the current source and revised for first deployment.
[ADR-11](../adr/0011-initial-release-analytics-contracts.md) records the proposed cross-plan
contracts; implementation must supply the acceptance evidence before those contracts become
accepted runtime guarantees.
