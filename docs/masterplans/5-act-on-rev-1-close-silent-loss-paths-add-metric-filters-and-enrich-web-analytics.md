---
id: 5
slug: act-on-rev-1-close-silent-loss-paths-add-metric-filters-and-enrich-web-analytics
title: "Act on REV-1: close silent-loss paths, add metric filters, and enrich web analytics"
kind: master-plan
created_at: 2026-10-15T13:44:34Z
intention: "intention_01m4zwwdrjesytazp5tb39fe3n"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-15T13:44:34Z
  revisions:
    - model: "claude-fable-5-1"
      harness: "claude-code"
      at: 2026-10-15T14:24:22Z
      mode: "update"
      note: "Promote beacon route (EP-39), rejection quarantine (EP-29 M4, EP-37 M5) and person properties (EP-40) into scope after owner discussion."
---

# Act on REV-1: close silent-loss paths, add metric filters, and enrich web analytics

This MasterPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Vision & Scope

This initiative implements the improvements recommended by REV-1,
`docs/reviews/2026-10-15-architecture-and-feature-set-against-comparable-products.md`, the
review that validated Kansoku's architecture and feature set, as a single-tenant deployment,
against PostHog, Plausible, Umami, Mixpanel, Amplitude, Snowplow, Segment, RudderStack,
Jitsu, OpenPanel, Rybbit, Aptabase and GrowthBook. The review approved the write path, the
ingest contract, credential scoping, schema governance and the operational surface, and
requested changes in three groups: paths that lose data silently in ordinary operation, a
metric layer narrower than product-analytics table stakes, and a web-analytics layer that
the product vision promises but the service does not have.

After this initiative is complete: an event from a client whose clock runs ahead is
corrected or clamped rather than dropped; a ClickHouse outage of any realistic length drains
on its own once storage returns, with the archive visible as a gauge and a command to replay
it; rejected events and rate-limited clients are counted server-side; standard metric routes
accept property filters and two grouping dimensions; identity resolution attributes a shared
device's pre-login events to the right person and its cost is bounded by the query window;
page views, sessions and users can be broken down by channel, campaign, browser, device and
optionally country with bots excluded; sessions report duration, bounce rate and entry and
exit pages; active users have rolling windows and stickiness, retention has "on or after"
and lifetime cohorts, funnels have strict mode, exclusions, time to convert and a first-touch
breakdown, and experiments expose multiple-exposure and variant-share diagnostics; one
administrative executable handles keys, erasure, retention, archive replay and the rejection
quarantine; a guide tells an owner-operator how to build dashboards and run experiment
statistics directly on ClickHouse; the browser's `sendBeacon` can reach a dedicated ingest
route on page exit so the last events before a navigation or tab close are no longer the ones
most likely to be lost; rejected declared-event payloads are quarantined with their reasons
for a bounded time; and backend-known user traits ("set" and "set-once") can filter and group
browser traffic through a `user:<name>` dimension with current-value semantics. The sustained
ingest capacity of the default configuration is measured and written down.

Explicitly excluded: a dashboard UI and a statistics engine (REV-1 Part I section 2 judges
both as correctly absent for a single tenant; GrowthBook and Grafana are the documented
substitutes); container or compose distribution (REV-1 H5, deferred to the product vision's
later scope at the owner's request on 2026-10-15); snapshot-at-event-time person properties
(writing traits onto every event, deferred in favour of current-value semantics); and
multi-tenant features. The browser SDK's own bot list, `sentAt` support, beacon exit flush and
`identifyOnce` helper are work in `mori://shinzui/kansoku-ts` and are integration inputs, not
children here.


## Decomposition Strategy

Children are cut by functional concern so that each produces one independently verifiable
behaviour and most can run in parallel. The two silent-loss findings are separate children
because they live in different code (ingest validation versus the writer and adapter) and are
proven by different harnesses (HTTP integration tests versus a controlled outage). Rate
limiting joins the writer child rather than the ingest child because both answer "what
happens under stress" and share the outage and load harness. Filters are their own child
because every later metric child reuses their compile path, and they must wait for EP-26's
bounded execution to land. Identity is one child covering semantics and cost because both
change the same view and must be benchmarked together. Web analytics splits into enrichment
(ingest-time columns and the acquisition route) and session analytics (a new rollup and
measures) because they touch disjoint storage and verify independently. Cohort semantics and
funnel semantics are separate children because they extend different builders and different
routes. Administrative commands are one child because they share an executable and a
confirmation discipline. The consumption guide is documentation-only and can run first. The
beacon route is its own child because it is a contract change with a browser-side proof;
person properties are their own child because they add storage, a dimension prefix and two
declared events on top of the filter grammar; the rejection quarantine is a milestone of the
ingest child rather than a child, because it shares that child's handler path and PostgreSQL
boundary, with its purge command living in the administrative child.

Alternatives considered: one "web analytics" child for everything in REV-1 E4 was rejected as
unbalanced (it would be the largest child by far); folding the throughput benchmark into the
guide was rejected because the benchmark needs the writer child's load script and should
inform its sizing section; the original draft excluded the beacon route, the quarantine and
person properties pending decisions, which were taken the same day (see Decision Log).

ADR context read for this decomposition, by repository-relative path:
[ADR 1](../adr/0001-sdk-grade-ingest-contract-boundaries.md) (partial batches, limits, CORS;
EP-29 and EP-30 extend it with timestamp policy and 429),
[ADR 2](../adr/0002-pipeline-observability-readiness-and-writer-recovery.md) (instruments,
readiness, writer recovery; EP-29, EP-30 and EP-34 extend it),
[ADR 3](../adr/0003-api-key-authentication-and-account-scoped-analytics.md) (credentials and
account predicates; EP-37 and every query child preserve it),
[ADR 4](../adr/0004-queryable-event-properties-and-identity-resolved-projection.md) (property
compile boundary and the seven-column view; EP-31, EP-32, EP-33 and EP-38 extend or depend on
it), [ADR 5](../adr/0005-evidence-based-multi-signal-identity-resolution.md) (identity
evidence; EP-32 changes its resolution rule),
[ADR 6](../adr/0006-exposure-based-experiment-analytics.md) (exact and approximate semantics;
EP-35 and EP-36 extend its accuracy map),
[ADR 7](../adr/0007-versioned-event-schema-governance-and-publication.md) (catalog
versioning; EP-29 declares two events under it),
[ADR 8](../adr/0008-rfc9457-problem-details-and-generated-client-media.md) (problem documents;
new codes `rate_limited` and `invalid_filter` follow it), and the proposed
[ADR 9](../adr/0009-bounded-complete-aggregate-responses.md) (bounds and ordering; every
query child works inside it). Cross-repository context: the throttling precedent
`mori://shinzui/shomei/okf/capabilities/concepts/CAP-21` (pattern only), the adapter
configuration at `mori://shinzui/shibuya-pgmq-adapter/packages/shibuya-pgmq-adapter`, the
queue library at `mori://shinzui/pgmq-hs/packages/pgmq-effectful`, and the CLI guide
`mori://shinzui/haskell-jitsurei/docs/cli-overview`.


## Exec-Plan Registry

| # | Title | Path | Hard Deps | Soft Deps | Status |
|---|-------|------|-----------|-----------|--------|
| 29 | Correct client timestamp skew and count ingest rejections | docs/plans/29-correct-client-timestamp-skew-and-count-ingest-rejections.md | None | None | Not Started |
| 30 | Pipeline backpressure and storage-outage resilience | docs/plans/30-pipeline-backpressure-and-storage-outage-resilience.md | None | EP-29 | Not Started |
| 31 | Metric property filters and dual grouping | docs/plans/31-metric-property-filters-and-dual-grouping.md | External: EP-26 (MasterPlan 4) | None | Not Started |
| 32 | Time-aware identity bindings and bounded resolution cost | docs/plans/32-time-aware-identity-bindings-and-bounded-resolution-cost.md | None | EP-31 | Not Started |
| 33 | Acquisition and device enrichment with bot flagging | docs/plans/33-acquisition-and-device-enrichment-with-bot-flagging.md | External: EP-26 (MasterPlan 4) | EP-31 | Not Started |
| 34 | Session analytics: duration, bounce, entry and exit pages | docs/plans/34-session-analytics-duration-bounce-entry-and-exit-pages.md | External: EP-26 (MasterPlan 4) | EP-33 | Not Started |
| 35 | Rolling active users, retention modes, and lifetime cohorts | docs/plans/35-rolling-active-users-retention-modes-and-lifetime-cohorts.md | External: EP-26 (MasterPlan 4) | EP-31, EP-32 | Not Started |
| 36 | Funnel modes and experiment exposure diagnostics | docs/plans/36-funnel-modes-and-experiment-exposure-diagnostics.md | External: EP-26 (MasterPlan 4) | EP-31 | Not Started |
| 37 | Administrative executable for keys, erasure, retention, and replay | docs/plans/37-administrative-executable-for-keys-erasure-retention-and-replay.md | None | EP-30, EP-32 | Not Started |
| 38 | Single-tenant consumption guide for dashboards and experiments | docs/plans/38-single-tenant-consumption-guide-for-dashboards-and-experiments.md | None | EP-34, EP-35, EP-36 | Not Started |
| 39 | Beacon ingest route for page-exit delivery | docs/plans/39-beacon-ingest-route-for-page-exit-delivery.md | None | EP-29 | Not Started |
| 40 | Person properties: set and set-once user traits | docs/plans/40-person-properties-set-and-set-once-user-traits.md | External: EP-26 (MasterPlan 4); EP-31 | EP-29, EP-32, EP-37 | Not Started |

Status values: Not Started, In Progress, Complete, Cancelled. Hard Deps and Soft Deps
reference rows by their # prefix. "External: EP-26 (MasterPlan 4)" means
`docs/plans/26-bound-analytics-query-inputs-and-result-cardinality.md` must be Complete in
`docs/masterplans/4-align-kansoku-with-relevant-haskell-jitsurei-practices.md`; it was In
Progress when this MasterPlan was written.

Phases (implementation waves):

- Phase 1 — Fixes and documentation, parallel, no prerequisites: EP-29, EP-30, EP-37, EP-38,
  EP-39.
- Phase 2 — Query layer, after EP-26 is Complete: EP-31 first, then EP-32, EP-35, EP-36 and
  EP-40 in parallel.
- Phase 3 — Web analytics: EP-33, then EP-34.


## Dependency Graph

EP-29 and EP-30 have no prerequisites and are the first to run; EP-30 soft-depends on EP-29
only because both add fields to the `PipelineMetrics` record and the later one rebases.
EP-37 can start immediately for keys, erasure and retention; its replay command is more useful
once EP-30's archive gauge exists, and its erasure discovery must include EP-32's `email_hmac`
kind once that lands, so both are soft. EP-38 is documentation and can run at any time; its
semantic sentences are later refined by EP-34, EP-35 and EP-36, each of which owns its own
documentation update.

EP-31, EP-33, EP-34, EP-35 and EP-36 hard-depend on EP-26 being Complete because they add
predicates, dimensions, routes or measures inside the bounded complete-or-error execution path
and its stable problem codes; starting them earlier would mean building on a moving query
executor. Within Phase 2, EP-31 goes first because EP-35 and EP-36 reuse its property compile
helpers for breakdowns and EP-33 reuses its filter grammar for new dimensions; those are soft
because each later child can ship its route without filters and add them when EP-31 lands.
EP-32 is independent of EP-31 in code but shares `Query.hs`, so sequence their merges.
EP-34 soft-depends on EP-33 for the `channel` and `is_bot` columns and degrades gracefully
without them. EP-35 soft-depends on EP-32 because lifetime cohorts and rolling windows scan
the resolved view over long ranges and are only comfortable after its cost is bounded.

EP-39 has no prerequisite; it soft-depends on EP-29 only for the `transport` label on the
ingest counters and otherwise adds its own counter. EP-40 hard-depends on EP-31 because the
`user:` prefix is an extension of the filter and group-by grammar EP-31 defines, and on EP-26
for the same reason as the other query children; it soft-depends on EP-29 (trait ordering uses
the corrected event time), EP-32 (join cost on the resolved path) and EP-37 (erasure of trait
rows). EP-37's rejection commands read the table EP-29 M4 creates, so EP-37 M5 should follow
EP-29 M4; the rest of EP-37 does not wait.

No interleaved milestone sequence is needed; whole-child ordering suffices.


## Integration Points

`PipelineMetrics` and `registerPipelineMetrics` in `kansoku-core/src/Kansoku/Observability.hs`
— EP-29 adds three ingest instruments, EP-30 adds the archive gauge and the rate-limit
counter. EP-29 defines the extension pattern (labelled vectors); EP-30 follows it. Both update
the Prometheus list in `docs/guides/operations.md` and ADR 2.

`AnalyticsEvent` wire type in `kansoku-api/src/Kansoku/Event/Types.hs` — EP-29 claims the
optional `sentAt` field; EP-32 claims the `email_hmac` identifier kind; EP-33 claims no wire
field (its enrichment reads `context`). Future additive fields are claimed in this paragraph
first. Every wire change regenerates OpenAPI and the catalog and moves `kansoku-client` in the
same commit, per the idiom established by MasterPlans 2 and 3.

`analytics.events_raw` columns and ClickHouse migrations under `db/clickhouse/migrations/` —
EP-30 adds the deduplication-window setting, EP-33 adds `browser_family`, `os_family`,
`device_class`, `is_bot`, `channel`, `country_code` and `context_json`, EP-34 adds the
`sessions` table and its view, EP-32 may add `resolved_identity`, and EP-37 alters the TTL
outside the ledger by explicit command. Migration numbers in plan prose are illustrative;
each child takes the next unclaimed number when it lands. The seven-column
`events_resolved` contract (ADR 4) is preserved by all of them.

Metric query compilation in `kansoku-core/src/Kansoku/Metrics/Query.hs`,
`Query/Validate.hs` and the route records in `kansoku-api/src/Kansoku/Metrics/Api.hs` —
EP-31 owns the `filter` grammar, the `Kansoku.Metrics.Filter` module, the `invalid_filter`
code and the composite two-dimension `group` encoding; EP-33, EP-35 and EP-36 add dimensions,
measures and routes using those helpers and must keep the account-predicate completeness test
passing and the EP-26 point cap and ordering rules intact.

Problem code catalog in `kansoku-api/src/Kansoku/Api/Response.hs` — EP-30 adds
`rate_limited` (429, retryable) and EP-31 adds `invalid_filter` (400); both extend the shared
MultiVerb error tail and regenerate OpenAPI (ADR 8).

Administrative executable `kansoku-admin` — owned by EP-37; EP-30's replay need and EP-29's
quarantine purge are satisfied there, not by second tools, and its `erase-user` command grows
to cover EP-40's trait tables.

PostgreSQL schema (`kansoku-core/src/Kansoku/Migrations.hs`) — EP-29 M4 adds
`kansoku.ingest_rejections`; EP-37 reads and purges it. The ingest path's dependency set
(PostgreSQL only) is preserved.

Credential transport (ADR 3) — EP-39 claims `/v1/beacon`, the `BeaconEnvelope` wire type and
the one documented exception where a write key travels in the body; service tokens are refused
there. Every other route keeps header-only credentials.

Event registry (`kansoku-api/src/Kansoku/Event/Registry.hs`) — EP-29 declares `alias` and
`group` version 1; EP-40 declares `identify` version 2 and `identify_once` version 1 with the
initial trait set. Both regenerate the catalog under ADR 7.

Filter and group-by grammar — EP-31 owns the grammar; EP-40 adds the `user:` prefix and the
trait join, and must leave `prop:` compilation untouched.

User trait storage — EP-40 owns `analytics.user_properties`, `user_properties_once` and the
`user_traits` view; EP-37's erasure and the runbook delete from them.

Browser SDK (`mori://shinzui/kansoku-ts`) — EP-29's `sentAt` and EP-33's `context.bot` are
optional inputs the server accepts; SDK work is tracked in that repository's own plans and is
not a dependency here.

Early representative checks: EP-30's controlled outage (the writer side of the pipeline under
real ClickHouse unavailability) and EP-32's benchmark are the two uncertain interactions and
are scheduled as first milestones of their children. Cross-plan decisions that should become
ADRs: the ingest timestamp policy and 429 contract (extend ADR 1), the breaker and delivery
budget (extend ADR 2), the filter contract and the stable read surface (extend ADR 4), the
interval resolution rule (extend ADR 5), a new enrichment ADR (EP-33: derived columns, bot
flag, no-address rule), and a new administrative-boundary ADR (EP-37).


## Progress

No child plan started. EP-26 of MasterPlan 4 is In Progress and gates Phase 2. Phase 1
children (EP-29, EP-30, EP-37, EP-38, EP-39) are ready. Twelve children in total after the
2026-10-15 scope decision.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Split REV-1's sixteen improvements into ten children along the lines above, with
  three deliberate exclusions (beacon credential transport, quarantine table, person
  properties) recorded in Vision & Scope.
  Rationale: Each child is one verifiable behaviour with its own harness; the exclusions each
  need a decision this initiative should not make implicitly.
  Date: 2026-10-15
- Decision: Gate the query-layer children on EP-26 Complete rather than on a milestone.
  Rationale: EP-26 rewrites the execution path those children extend; a milestone-level
  dependency would invite building on an unfinished executor.
  Date: 2026-10-15
- Decision: Promote three of the four original exclusions into scope after discussion with the
  owner: the beacon route as EP-39 (dedicated `/v1/beacon`, JSON envelope, `text/plain`, write
  keys only), the rejection quarantine as EP-29 M4 with purge in EP-37 M5, and person properties
  as EP-40 with current-value semantics and set-once via a second declared event. Compose
  distribution stays excluded.
  Rationale: The use cases were judged worth the trade-offs: page-exit events are the ones
  attribution and conversion most need; the quarantine is what a producer release diff needs
  once counters say something is wrong; and only backend-known traits let browser traffic be
  segmented. Snapshot-at-event-time traits remain deferred as a much larger change.
  Date: 2026-10-15

- Decision: EP-31 also adds `source_service` and `host` as built-in filter and grouping
  dimensions, and documents the one-account-several-properties pattern.
  Rationale: The marketing site and the application must share an account for identity
  stitching to link them, and without these dimensions their same-path pages merge in every
  query. No storage change is involved, so it belongs in the filter child rather than a new one.
  Date: 2026-10-15

Revision note (2026-10-15): the registry grew from ten to twelve children and EP-29 gained a
fourth milestone; Vision & Scope, Dependency Graph and Integration Points were updated to
match. No child plan had started.


## Outcomes & Retrospective

(To be filled during and after implementation.)
