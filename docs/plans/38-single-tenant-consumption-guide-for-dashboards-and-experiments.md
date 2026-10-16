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
- [x] M3: Final API documentation and cross-repository release conformance pass without skips.

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

Complete on 2026-10-16. The stable seven-column resolved projection is preserved; migration
0023 adds events_analytics_v1 and explicit definer security, and the constrained reader grants
only the three supported views. All three executable SQL recipes match HTTP on physical
retries, canonical anonymous/user identity, bots, missing/empty/incompatible properties and
applied retention. Direct SQL maintenance and downstream-copy boundaries are explicit.

Final packaged acceptance is `.dev/acceptance/run-e73nvh9u/sanitized`: 426 core examples,
20 live-configured Haskell client examples, four probes and 58 actual Hurl requests (43 safe,
14 stateful and one disabled-metrics request). Native recovery/limits/replay/identity, all public
analytics workflows and privacy/correlation pass in legacy/http/http-dup modes. All seven
administrative families pass, including backend/native write draining, resumable failure,
explicit deletion, fingerprint policy, old replay and retained projection agreement.

The required consumer is mori://shinzui/kansoku-ts/packages/kansoku-js at code/test commit
f26f74358d2931a94b40c1a7077f6b7630edd01a. Its built JavaScript SHA256 is
f4a20924a5f97eb4774cd3ed2cf0a369efb93e045bfb561de1957cd36e460f56.
Required checks pass nine live cases (including actual queued-clock correction, duplicate
retry, email_hmac, versions and trait queries), three real beacon/rate-limit protocol cases,
two real-server vanilla/React examples, eight multi-origin identity/bot Chromium families and
six beacon/origin/quota/BFCache Chromium cases, all with zero feature skips. A separate trait
case also passes in each telemetry mode. SDK source checks pass 85 unit and two explicit SSR
cases plus types/lint/format/generated contracts/package validation; JavaScript/React gzip
sizes are 8565/1550 bytes inside their unchanged budgets. The accepted wire pin contains server
candidate e0eb782; the final metadata pin is recorded at mori://shinzui/kansoku-ts with
project-relative path contracts/KANSOKU_COMMIT (artifact-level URI pending) after the
documentation completion commit.

The reader gate uses the exact upstream GrowthBook 5.1.0 commit and unmodified Node/tsconfig
adapter for four connection/query-editor/schema/data/denial cases. Grafana OSS 13.2.4 with the
hash-verified official ClickHouse plugin 4.22.1 passes three datasource/import/panel cases.
These pass again through packaged acceptance; reproduction and pinned artifact hashes are
in docs/guides/consumer-conformance.md and docs/examples/consumer-versions.json. Optional
Metabase remains an example, and no experiment statistics engine or causal claim is added.

The ordinary workflow passes four non-skipped cases in
`.dev/acceptance/first-use-gd1o3eze/summary.json`: clean local clone at b0a548c, shipped shellHook
and just up/migrate/ch-migrate/issue-key/run, repeated migrations, actual capture with the
previously accepted SDK revision 0a4eea715b5f34fad8593e3dfd123ce407976c95, immutable retry,
storage loss, durable queue preservation, full stack restart and exact recovered count. The
SDK's own Nix shell supplies every Bun invocation. No SQL seed substitutes for these product
steps. The source reference is mori://shinzui/kansoku-ts/packages/kansoku-js. The shipped
process-control port defaults to 8081, preserving Kansoku's default 8080 and an explicit
PC_PORT_NUM override.

The final mixed queue-v2 outage proof in `.dev/acceptance/outage-ni1sty8k/report.json`
preserves 120000 events at 200/s for 600.004 seconds through writer restart: first recovered
write 4.651 seconds, full drain 40.822 seconds against a 362.834-second calibrated bound,
zero valid archives. All 120000 facts retain nonempty sessions and authoritative enrichment;
the workload includes 12000 governed trait operations. Database growth is 212238336 bytes,
generated WAL 547020800 bytes. The finite 10-GiB/50%-headroom/200-sample budget is about
1.18 hours, extrapolated from the tested ten-minute outage with input stopped at recovery.
The updated capacity guide replaces the earlier small-payload measurement.

Final cost evidence `.dev/acceptance/identity-bench-wm32m0ts/report.json` passes all 28
five-run-median comparisons over 3M recent +7M older facts, seven production query families
and day/month windows. Identity ratios are 1.0355–1.3119, below 2x; maximum resolved median
469 ms, cold native total 946 ms, warm peak 451288707 bytes and cold peak 448542781 bytes,
below the unchanged 536870912-byte budget. Neither accepted measurement overlaps task-owned
build/test load. Source just check passes 364 core, 19 client, four probes, 18 strict ADRs,
seven telemetry cases in each mode and four lifecycle checks.

ADR-11 and ADR-18 accept the durable contracts after this integration evidence; the other
cross-plan decisions remain in their owning accepted ADRs. Results establish source and local
Nix-packaged executable behavior. No globally installed executable was used or changed;
neither executable was found in the initial PATH. No package, container, hosted endpoint or
deployment is published. All implementation and required acceptance work is complete.

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


Documentation follows accepted behavior. Repeated migrations and immutable retries are exercised by the ordinary workflow. Regeneration and the consumer pin are checked together; publication and deployment remain separate operator actions.

## Interfaces and Dependencies


Required complete child artifacts: `docs/plans/31-metric-property-filters-and-dual-grouping.md`, `docs/plans/33-acquisition-and-device-enrichment-with-bot-flagging.md`, `docs/plans/34-session-analytics-duration-bounce-entry-and-exit-pages.md`, `docs/plans/35-rolling-active-users-retention-modes-and-lifetime-cohorts.md`, `docs/plans/36-funnel-modes-and-experiment-exposure-diagnostics.md`, `docs/plans/37-administrative-executable-for-keys-erasure-retention-and-replay.md`, `docs/plans/39-beacon-ingest-route-for-page-exit-delivery.md`, `docs/plans/40-person-properties-set-and-set-once-user-traits.md`.

Hard dependencies: EP-31, EP-33, EP-34, EP-35, EP-36, EP-37, EP-39 and EP-40 Complete. This child owns the final release contract gate and stable SQL grants. Draft prose can be prepared earlier but the child cannot complete on interim semantics.

Revision note (2026-10-15): reviewed against the current source and revised for first deployment.
[ADR-11](../adr/0011-initial-release-analytics-contracts.md) records the accepted cross-plan
contracts after the final implementation and acceptance evidence recorded above.
