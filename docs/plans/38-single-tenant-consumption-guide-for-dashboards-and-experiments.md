---
id: 38
slug: single-tenant-consumption-guide-for-dashboards-and-experiments
title: "Single-tenant consumption guide for dashboards and experiments"
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
      at: 2026-10-15T15:43:16Z
      verdict: "changes-requested"
      note: "Original draft review found correctness gaps; findings corrected by the accompanying update, with native acceptance still required."
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-15T15:43:16Z
      mode: "update"
      note: "Reconcile first-release APIs, domain semantics, dependencies and acceptance with the source-validated MP-5 review."
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-16T04:03:34Z
      mode: "implement"
      note: "Finalize stable reader SQL, real dashboard/experiment consumer checks, remaining SDK browser contracts and measured first-release adoption/recovery acceptance after all eleven prerequisite children passed."
---

# Single-tenant consumption guide for dashboards and experiments


## Purpose / Big Picture


Publish the initial supported HTTP and SQL consumption surface and prove that a read-only
consumer can reproduce metric answers. Grafana/Metabase/GrowthBook remain optional external
consumers; the first release has no dashboard or experiment statistics engine.

## Progress


- [x] M1: A versioned stable SQL surface and working read-only role reproduce HTTP fixtures.
- [x] M2: GrowthBook assignment/fact queries pass a real consumer check.
- [ ] M3: Final API documentation and cross-repository release conformance pass without skips.

## Surprises & Discoveries


The original guide granted stable views but queried internal events_raw, and froze raw sketches
while other children changed identity/bot semantics. EP-26 and ADR-9 are already Complete/Accepted.
Documentation cannot finalize before the metric and retention contracts it promises.

Real-consumer execution caught two integration errors that SQL inspection missed: native JSON
properties require guarded Dynamic subcolumns, and Grafana's Go driver derives a server timeout
from its context deadline plus five seconds. The accepted recipe uses a 25-second deadline
inside the unchanged 30-second reader ceiling. GrowthBook runs with its upstream Node/tsconfig
semantics; Bun class-field initialization would clear constructor-populated adapter params.

First-use command inspection found both process-compose and Kansoku defaulting to TCP 8080.
The shipped `just up` now defaults its control API to 8081 while honoring PC_PORT_NUM, leaving
the product API at 8080. The ordinary fresh-clone gate must execute that shipped recipe.

## Decision Log


On 2026-10-15 stabilize deliberate SQL projections, not every incidental rollup or identity
view. Direct SQL access is a trusted single-tenant operator surface; account literals in a
query are not an access-control mechanism for an untrusted dashboard viewer.

## Outcomes & Retrospective


M1/M2 accepted on 2026-10-16: `.dev/acceptance/reader-smoke-sizfm0g4/reader`
executes the constrained role, denies excluded reads/writes and disabled limits, matches all
three SQL recipes to HTTP before/after applied retention, and verifies the actual GrowthBook
5.1.0 adapter (four cases) and Grafana 13.2.4/plugin 4.22.1 (three cases), all with zero skips.
The strengthened fixture with incompatible historical JSON also passes in
`.dev/acceptance/identity-validation/ep38-reader-r14-basic.log`. Native result caps are checked
at block boundaries, while HTTP retains its strict complete-or-error point cap. Required SDK
source evidence passes nine live cases, three real beacon/rate-limit protocol cases and eight
multi-origin Chromium identity/bot cases. Final packaged acceptance, consumer pin, ordinary
fresh-clone reuse/recovery and refreshed performance/capacity evidence remain pending.

The final mixed queue-v2 outage proof passes in `.dev/acceptance/outage-ni1sty8k/report.json`:
120000 events at 200/s for 600.004 seconds, writer restart while storage remains blocked,
4.651-second first recovered write and 40.822-second full drain, against a 362.834-second
calibrated bound. All 120000 facts retain nonempty sessions and authoritative enrichment;
12000 governed trait operations exercise current projections. Zero valid events are archived.
Database growth is 212238336 bytes and generated WAL 547020800 bytes. The revised finite
10-GiB/50%-headroom/200-sample budget is about 1.18 hours, extrapolated from a tested ten-minute
outage with input stopped at recovery. `docs/guides/capacity.md` replaces the older small-payload
measurement. No task-owned build/test load overlapped the accepted measurement.

## Context and Orientation


`docs/README.md` indexes guides; `Metrics/Api.hs` publishes OpenAPI descriptions;
`Query.hs` implements metric semantics. ADRs 3, 4, 6, 9 and 10 govern accounts, properties,
accuracy, bounded results and owned acceptance. Generated artifacts live at
`docs/api/openapi.json` and `docs/contracts/events.json`.

## Plan of Work


### M1: Stable read contract


Write `docs/guides/consume-clickhouse.md` after the metric children land. Freeze the ordered
seven-column events_resolved view with EP-32 canonical subject semantics and named explicit
views for any additional session/enrichment fields a supported recipe needs. Keep internal
storage, identity evidence and raw sketches changeable; do not promise all tables stable.
Document view freshness, retained-history bounds, bot policy, exactness and group semantics.
Create a read-only SQL role with SELECT on just these views, finite execution/memory settings
and appropriate SQL SECURITY behavior on the packaged ClickHouse. Test with that actual role:
it can execute the recipes and cannot read excluded base tables or mutate data. A view that
requires unauthorized underlying reads is not accepted. Use grants supported by native SQL,
not an assumed comma-separated multi-table GRANT syntax.

Worked examples: exact daily users, a two-step funnel and revenue by prop:plan, with the same
account/time/filter/identity/deduplication/bot semantics as HTTP. Label separate raw approximate
sketch examples explicitly. Add a Grafana datasource/panel recipe verified for its chosen plugin
version. Treat optional Metabase instructions as examples, not an unverified support guarantee.

### M2: GrowthBook


Use the stable resolved event projection for both exposures and fact events. Assignment output
columns are user_id (configured identifier), timestamp, experiment_id, variation_id; map arbitrary
Kansoku variant names through an explicit documented mapping when the consumer requires it.
Return every distinct exposure event, including re-exposures, with canonical user identity and
account predicate. Fact rows use the same subject convention, timestamp and validated amount.
This matches [GrowthBook datasource documentation](https://docs.growthbook.io/app/datasources).
Validate SQL with the reader role and import the configuration into a pinned local GrowthBook
instance or an equivalent real consumer integration test. Record version, commands and output;
no available instance means M2 stays pending, not approved by inspection.

Explain multiple exposures and first-assignment shares from EP-36; aggregate conversion counts
are not sufficient statistics for every experiment method. Do not publish a significance claim
from sketch counts or contaminated variant populations.

### M3: First-release contract gate


Publish a route/parameter support matrix with examples and error codes; unimplemented
organizations/custom routes remain explicitly excluded from the first-version supported surface.
Document that revenue is an analytical sum of payment_completed.amount in one declared
account currency/unit; it does not perform FX conversion, refunds/net-revenue accounting or
provide an exact monetary ledger. Producers must normalize amounts to that unit. Do not describe
feature-adoption distinct-user counts as a percentage without a defined eligible denominator.
State UTC closed-day requirements for rolling/cohort routes, session-start attribution, bounce
lifecycle exclusions, current-value traits, filter JSON, null groups, retained-history lifetime,
and exact versus explicitly approximate measures. Cross-origin attribution requires SDK handoff,
not merely putting sites in one account.

Run SDK conformance from
`mori://shinzui/kansoku-ts/plans/8-serve-kansoku-masterplan-5-sentat-beacon-exit-flush-bot-flag-and-identifyonce`
against the final packaged server; contract pin, generated types and all required features must
match and tests must not skip on feature detection. Required cases include skew, duplicate retry,
beacon limits/429, bot exclusion, email_hmac, identify v2/identify_once v1 and a user-trait metric
query. Browser demo ownership stays in that SDK plan. Update documentation references to the
actual final schema, not an earlier interim implementation.

## Validation and Acceptance


All three SQL recipes match HTTP on adversarial fixtures with duplicate events, anonymous-to-user
resolution, bots and retention. Reader privileges pass positive and negative tests. GrowthBook
accepts assignment and fact queries on the pinned version. Final `just check`, `just acceptance`
and the SDK required conformance gate pass with zero skipped/pending features. Review feature
exclusions and latency/capacity limits as part of the first deployment runbook.

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


Documentation follows accepted behavior. Regeneration and SDK pin refresh are reviewed together. No runtime implementation or deployment is authorized merely by completing this planning review.

## Interfaces and Dependencies


Required complete child artifacts: `docs/plans/31-metric-property-filters-and-dual-grouping.md`, `docs/plans/33-acquisition-and-device-enrichment-with-bot-flagging.md`, `docs/plans/34-session-analytics-duration-bounce-entry-and-exit-pages.md`, `docs/plans/35-rolling-active-users-retention-modes-and-lifetime-cohorts.md`, `docs/plans/36-funnel-modes-and-experiment-exposure-diagnostics.md`, `docs/plans/37-administrative-executable-for-keys-erasure-retention-and-replay.md`, `docs/plans/39-beacon-ingest-route-for-page-exit-delivery.md`, `docs/plans/40-person-properties-set-and-set-once-user-traits.md`.

Hard dependencies: EP-31, EP-33, EP-34, EP-35, EP-36, EP-37, EP-39 and EP-40 Complete. This child owns the final release contract gate and stable SQL grants. Draft prose can be prepared earlier but the child cannot complete on interim semantics.

Revision note (2026-10-15): reviewed against the current source and revised for first deployment.
[ADR-11](../adr/0011-initial-release-analytics-contracts.md) records the proposed cross-plan
contracts; implementation must supply the acceptance evidence before those contracts become
accepted runtime guarantees.
