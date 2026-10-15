---
type: Review
title: Kansoku architecture and feature set against comparable analytics products
description: >-
  Compared as a single-tenant deployment with PostHog, Plausible, Umami, Mixpanel, Amplitude,
  Snowplow, Segment, RudderStack, Jitsu, OpenPanel, Rybbit, Aptabase and GrowthBook, the
  pipeline, contracts and governance hold up or lead the field, while two silent data-loss
  paths, missing ingest-rejection telemetry, and the absence of filters and web-analytics
  enrichment are the changes worth making before the feature set is called complete.
generated:
  by: process:claude-code
  at: "2026-10-15T14:30:00Z"
reviewId: REV-1
subject: mori://shinzui/kansoku
subjectKind: project
reviewedSha: 98c61c9d9de8f2c548e972873fe7b3bfc9ee2953
coverage: full
reviewedAt: "2026-10-15T05:06:42Z"
reviewerKind: model
reviewer: process:claude-code
provider: anthropic
model: claude-fable-5-1
effort: high
outcome: changes-requested
dimensions:
  - correctness
  - security
  - performance
  - design
  - documentation
  - operability
produced:
  - mori://shinzui/kansoku/masterplans/5-act-on-rev-1-close-silent-loss-paths-add-metric-filters-and-enrich-web-analytics
  - mori://shinzui/kansoku/plans/29-correct-client-timestamp-skew-and-count-ingest-rejections
  - mori://shinzui/kansoku/plans/30-pipeline-backpressure-and-storage-outage-resilience
  - mori://shinzui/kansoku/plans/31-metric-property-filters-and-dual-grouping
  - mori://shinzui/kansoku/plans/32-time-aware-identity-bindings-and-bounded-resolution-cost
  - mori://shinzui/kansoku/plans/33-acquisition-and-device-enrichment-with-bot-flagging
  - mori://shinzui/kansoku/plans/34-session-analytics-duration-bounce-entry-and-exit-pages
  - mori://shinzui/kansoku/plans/35-rolling-active-users-retention-modes-and-lifetime-cohorts
  - mori://shinzui/kansoku/plans/36-funnel-modes-and-experiment-exposure-diagnostics
  - mori://shinzui/kansoku/plans/37-administrative-executable-for-keys-erasure-retention-and-replay
  - mori://shinzui/kansoku/plans/38-single-tenant-consumption-guide-for-dashboards-and-experiments
  - mori://shinzui/kansoku/plans/39-beacon-ingest-route-for-page-exit-delivery
  - mori://shinzui/kansoku/plans/40-person-properties-set-and-set-once-user-traits
context: >-
  Read the README, every adopter guide, the product vision, ADR 1-9 (ADR 9 as an
  uncommitted proposal), all sixteen ClickHouse migrations, the generated event catalog and
  OpenAPI parameter surface, the metric SQL builders in Kansoku.Metrics.Query, the ingest
  handler and validation, the observability instruments, the writer batch handler, and
  MasterPlans 1-4 with their outcome sections. Read the sibling browser SDK repository
  (mori://shinzui/kansoku-ts) for delivery, session, attribution and context capture only;
  it is not the subject of this record. The working tree carried uncommitted EP-26
  (bounded queries) changes, which were read as the current state. Comparison facts come
  from three web-research passes run on 2026-10-14 against vendor documentation and source
  repositories; each is cited inline with its retrieval or publication date. Tests were
  not run. The local process-compose stack was started to run EXPLAIN against the migrated
  schema on ClickHouse 26.8.2.7 at fixture scale for the resolution-view finding; no load
  was generated, so that finding has a verified plan shape and an unmeasured cost. The lens throughout is a
  single-tenant, owner-operated deployment: multi-tenant SaaS concerns such as billing,
  quotas and organisation management were deliberately excluded from the comparison.
---

# Kansoku architecture and feature set against comparable analytics products

This record validates Kansoku's architecture and feature set against the products a
single-tenant adopter would otherwise run or buy. "Single-tenant" shapes every judgement
below: features whose only purpose is multi-tenant SaaS operation are not counted as gaps,
and the owner's direct access to ClickHouse is counted as an available surface. Findings are
tagged **by-design** when a documented decision explains the divergence and it holds up,
**covered-by-plan(ref)** when a plan or listed future scope already owns it, or **NEW**.
Severity is Blocker / Major / Medium / Minor. A Major here means silent data loss or an
operational trap in ordinary use, or a feature gap that blocks the product vision's own
stated goal. File references are point-in-time at commit `98c61c9d`.

---

## Part I — Synthesis

**Verdict.** The write path, the ingest contract, credential and account scoping, schema
governance and the operational surface are at or above the level of the self-hostable
field, and several choices (durable queue ahead of ClickHouse, partial batch acceptance with
per-index rejection, unbounded idempotency keys, versioned immutable schemas published to
producers, exposure-at-render experiments) are better reasoned than their nearest peers.
The metric layer is honest and bounded but narrow: it is roughly Plausible's breadth with
Amplitude's query discipline, and it lacks the filter, breakdown and web-analytics
enrichment that every product-analytics tool treats as table stakes. Two paths lose data
silently in ordinary operation and should be fixed first: rejection of any event whose
client clock runs ahead of the server, and auto-archiving of queued events after roughly
three to four minutes of ClickHouse unavailability with no Kansoku-visible signal. A third
operability gap compounds both: nothing counts rejected events server-side.

### 1. Where Kansoku matches or leads the field

- **Durable queue before the warehouse.** PostHog, Jitsu and Snowplow put Kafka or a cloud
  stream between capture and storage; Plausible buffers five seconds in process memory,
  Aptabase buffers ten seconds and discards on insert failure, OpenPanel stages in a Redis
  list, Umami writes directly. Kansoku's PGMQ queue is crash-safe like the Kafka group at
  the operational weight of the light group. The only precedent for a PostgreSQL-backed
  queue is RudderStack's JobsDB. The documented throughput ceiling is PostgreSQL, not
  ClickHouse (`docs/plans/4-…` decision log, 2026-07-01), with the Kafka adapter as the
  named escape hatch. This is the right trade for single-tenant volumes.
- **Ingest contract.** Partial acceptance with zero-based rejection indices on a 202 is the
  strongest pattern in the field (Mixpanel's `strict=1`, Umami's batch endpoint and
  Amplitude's per-index 400 are the peers; Segment and PostHog return 200 and drop
  silently). RFC 9457 problem documents with a stable `code` and `retryable` flag, 413 as a
  permanent split-the-batch signal, and 503 reserved for retryable outages give SDKs exactly
  the retry contract Segment and Amplitude document in prose. Limits of 500 events and
  5 MiB sit inside the 500 KB (Segment) to 20 MB (PostHog, Amplitude batch) range.
- **Idempotency.** Dedup windows elsewhere are bounded (Amplitude and RudderStack seven
  days, Segment at least 24 hours), and PostHog's own handbook rates relying on
  ReplacingMergeTree merges as a mistake. Kansoku keys the raw table by event id, then makes
  every served metric replay-proof anyway (`count(DISTINCT event_id)`, `uniqExact`,
  union-safe `uniqCombined` states) rather than trusting merges. That is more careful than
  any peer read.
- **Credentials and tenancy.** Plausible and Umami ingest with no credential at all;
  PostHog, Amplitude and Mixpanel use a public project token. Kansoku's hashed write keys
  and service tokens, type-level authentication on every protected route, server-stamped
  account identity and account predicates bound as native ClickHouse parameters are
  stronger than the field. In a single-tenant deployment the account dimension still earns
  its keep as environment separation (development, staging, production credentials).
- **Schema governance.** Only Snowplow validates events against a versioned registry;
  Segment Protocols, RudderStack tracking plans and Amplitude's "Reject" mode are hosted or
  paid features; PostHog and Mixpanel treat definitions as metadata. Kansoku's contiguous,
  immutable versions, "absent means version 1, never latest", the unauthenticated
  `/v1/schemas` catalog, the committed artifact with a golden test, and SDK version pinning
  are a Snowplow-grade contract at a fraction of the machinery.
- **Experiments.** Exposure at render rather than at assignment matches PostHog's
  `$feature_flag_called`, Mixpanel's `$experiment_started` and Amplitude's `$exposure`
  guidance. Labelling exposure counts as approximate pre-stitch and conversion as exact
  post-stitch, and refusing to compute significance without a stated statistical policy,
  is the honest shape.
- **Operations.** Ordered readiness checks with onset timestamps, seven pipeline
  instruments, opt-in OpenTelemetry, and access logs that never carry query strings,
  bodies or credentials exceed what Plausible, Umami, Rybbit, OpenPanel or Aptabase expose.
  One process plus PostgreSQL plus ClickHouse is the same footprint as Plausible CE and
  Aptabase, and far below PostHog's hobby compose file (Kafka, ZooKeeper, Redis, Valkey,
  Temporal, SeaweedFS and a dozen services).
- **Privacy by construction.** No IP is captured or stored, the browser SDK computes no
  fingerprint, fingerprint evidence carries a 180-day TTL, GPC and DNT are one option each,
  and erasure has a runbook. Plausible is the only peer with a comparably strict posture,
  and it achieves it by having no persistent identity at all.
- **Measured decisions.** The 10-million-row properties benchmark behind ADR 4 and the
  rollup-size evidence in EP-12 are the kind of evidence most open-source peers do not
  record.

### 2. Deliberate divergences that hold up under single-tenant use

- **No dashboard UI** (by-design; vision lists it as later scope). An owner-operator has
  ClickHouse. The missing piece is not a UI but a documented read path: a read-only
  ClickHouse role and a statement that `analytics.events_resolved` (seven-column contract,
  ADR 4) and the rollup tables are stable surfaces for Grafana or Metabase. See G1.
- **No SQL query API** (by-design). PostHog's HogQL exists because its users do not have
  the database. Kansoku's typed, bounded endpoints are the right product-embedding surface
  and already match the shape of PostHog's "Endpoints" feature for customer-facing
  analytics.
- **No statistics engine** (by-design, ADR 6). GrowthBook consumes a ClickHouse data source
  through an "experiment assignment query" returning identifier, timestamp, experiment id
  and variation id, and metrics from SQL fact tables. `experiment_viewed` in `events_raw`
  and `events_resolved` map onto that directly. Document it instead of building it. See E5.
- **No multi-tenant features.** Billing, quotas, organisation management and per-project
  retention windows are correctly absent.
- **PostgreSQL queue rather than Kafka** (by-design). Right for this scale; the ceiling
  should be measured and written down. See B3.

### 3. Divergences that do not hold up, ranked

1. **Future-dated events are rejected outright** (Major, correctness). Every peer that
   documents the case corrects or clamps; none rejects. A client clock one minute fast loses
   every event for that client, and the SDK correctly does not retry. See A1.
2. **A ClickHouse outage longer than the writer's retry budget archives events with no
   Kansoku-visible signal and readiness then reports healthy** (Major, operability). The
   budget is about three deliveries at a 60-second visibility timeout. ClickHouse upgrades
   and host reboots routinely exceed it. See B1.
3. **Nothing counts rejected events server-side** (Major, operability). A producer that
   starts violating a declared schema is visible only in its own `onDrop` hook. See A2.
4. **No web-analytics enrichment** (Major against the vision, otherwise Medium). Bot
   filtering, referrer and channel classification, country, browser and device parsing,
   bounce, duration and entry and exit pages are table stakes in Plausible, Umami, Matomo,
   PostHog and Rybbit. The vision says Kansoku "should replace the need for third-party web
   analytics where possible"; today it cannot. See E4.
5. **No property filters, no cohorts, no person properties** (Major for product-analytics
   parity). A single `groupBy` with no `filter` is below the floor of every product-analytics
   tool and is the first thing an embedding application needs. See E6.
6. **Identity resolution is not time-aware, and every exact metric query scans the
   account's anonymous events for all time** (Medium). The plan is verified; the cost at
   scale is not measured. See D1 and D2.
7. **Calendar rather than rolling active users** (Medium, documentation and semantics). See
   E3.

### 4. Recommended sequence

1. Fix the two silent-loss paths: skew correction and clamping for `occurredAt` (A1), and a
   writer pause on storage unavailability plus archive-size telemetry and a replay command
   (B1). Add ingest outcome counters at the same time (A2). All three are small.
2. Add `filter` to the standard metric routes using the existing declared-property
   compilation and native-parameter safety model (E6). This unlocks the embedding use case
   and most of the funnel and experiment breakdown asks without new storage.
3. Write the single-tenant consumption guide: read-only ClickHouse role, stable views,
   Grafana and GrowthBook recipes (G1, E5). This is documentation, not code, and it replaces
   a dashboard initiative.
4. Scope a web-analytics ExecPlan (E4): client-side bot list in the browser SDK,
   server-side user-agent parsing into typed columns, deterministic channel classification,
   optional country-only enrichment, session duration and bounce from `session_start` and
   `page_view` ordering.
5. Measure the two unmeasured things: sustained ingest throughput on reference hardware (B3)
   and resolution-view cost at ten million rows with a realistic anonymous share (D2), the
   same way EP-17 was done; the plan shape is already known, so the benchmark decides between
   the two fixes.
6. Semantics upgrades as demand appears: rolling WAU and MAU (E3), retention `on_or_after`
   and lifetime cohorts (E2), funnel strict mode and exclusions (E1), raw-event retention
   TTL (H1), admin CLI for revocation, erasure and replay (H3).

---

## Part II — Detailed findings

### A. Ingestion contract and SDK delivery

**A1 — Future `occurredAt` is rejected instead of corrected or clamped.** Major,
correctness, NEW.
`kansoku-api/src/Kansoku/Event/Validation.hs:48` fails validation when `receivedAt` precedes
`occurredAt`, returning `validation_failed`; the browser SDK's delivery guide
(`mori://shinzui/kansoku-ts`, `docs/guides/delivery-and-privacy.md`) says browsers whose
clocks run ahead "may receive timestamp rejections" and that the SDK reports them rather than
changing times. Peers: Segment and RudderStack compute
`timestamp = receivedAt − (sentAt − originalTimestamp)` from an SDK-stamped `sentAt`
(Segment Spec: Common, modified 2026-07-15; RudderStack common fields, undated); PostHog
applies the same correction and substitutes server time beyond 23 hours in the future
(PostHog timestamps doc, undated); Mixpanel's `/track` replaces a future `time` with ingestion
time (track-event reference, undated). No surveyed product rejects. Batching delays delivery
by up to five seconds, so only clocks more than a few seconds fast are affected, but for
those clients loss is total and permanent.
*Suggested improvement:* accept an optional `sentAt`; when present, correct `occurredAt` by
the observed skew. When absent, clamp an `occurredAt` within a tolerance (for example
24 hours, PostHog's figure) to `receivedAt` and record the original in `context` or an
ingestion-warning counter; reject only beyond the tolerance with a distinct code. Keep the
corrected value as the stored `occurred_at`. Regenerate the catalog and OpenAPI; the change
is additive on the wire.

**A2 — No server-side count of accepted or rejected events.** Major, operability, NEW.
`kansoku-core/src/Kansoku/Observability.hs:44-48` registers only writer-side instruments
(batches, events written, flush duration, insert failures, dead letters). The ingest handler
(`kansoku-core/src/Kansoku/Ingest/Handler.hs:80-83`) partitions accepted and rejected events
and returns the split to the client, then forgets it. Amplitude exposes a 24-hour Validation
Errors view (configure-schema, updated 2026-10-07); Segment records omissions in
`context.protocols`; Snowplow writes failed events to a separate table (failed events doc,
undated); PostHog keeps a dead-letter table with a four-week TTL. Kansoku's rejection is the
strictest of these and the only one with no server-side trace.
*Suggested improvement:* add `kansoku_ingest_events_total{outcome=accepted|rejected}` and
`kansoku_ingest_rejections_total{code}` to the Prometheus set, plus an accepted-event rate
in readiness diagnostics so the documented "mismatch between accepted traffic and
written-event rate" alert becomes computable. Optionally quarantine rejected declared-event
payloads in a bounded, TTL'd ClickHouse table keyed by account, code and received time so an
operator can diff a producer release against the catalog.

**A3 — Header-only credential precludes `sendBeacon` on page exit.** Minor, design,
by-design with a cost.
ADR 1 and ADR 3 put the write key in `Authorization` or `X-Api-Key`. Segment, Amplitude and
PostHog accept the public key in the body, which is what lets their SDKs fall back to
`navigator.sendBeacon` on `pagehide` (Amplitude browser-sdk-2, updated 2026-10-08; posthog-js
config, undated). The browser SDK therefore uses keepalive fetch capped at 60 KiB and mirrors
unsent events in `sessionStorage`; the delivery guide says tab closure can lose them.
posthog-js 1.400.0 (2026-07-14) hit the same keepalive quota and splits batches.
*Suggested improvement:* accept the write key in the JSON body for `POST /v1/batch` only, as
an alternative transport the SDK uses solely for the exit flush. Document it as beacon-only
so the header form stays canonical.

**A4 — No per-key rate limit or overflow lane.** Medium, security and operability, NEW.
The write key is public in browser bundles by design. Segment, Mixpanel and Amplitude answer
abuse with 429 and `Retry-After`; PostHog never rate-limits capture but routes a distinct id
above about 5,000 events per minute to an overflow pipeline (PostHog API overview, undated).
Kansoku accepts until `KANSOKU_READY_MAX_QUEUE_DEPTH` (100,000) trips readiness, at which
point the whole process, metrics reads included, is taken out of rotation. No code path
emits 429 (`grep` of `kansoku-core/src` finds none). The SDK already retries unknown
responses with backoff, so a 429 would be handled correctly today.
*Suggested improvement:* a per-key token bucket in front of `/v1/*` returning 429 with
`Retry-After` and the standard problem document, with limits in configuration. Consider
whether backlog-driven readiness should fail only the ingest surface rather than the
process; the shared-probe library may make that a route-level decision.

**A5 — Envelope and enrichment.** Minor, documentation, partly covered-by-plan(vision
"Later scope").
The SDK fills `context` with locale, timezone, screen, viewport, user agent and SDK version
(`mori://shinzui/kansoku-ts`, `packages/kansoku-js/src/context.ts`), and top-level
attribution with URL, referrer and the five UTM fields (`attribution.ts`). That matches the
Segment and RudderStack `context` conventions minus `page.title` and `campaign.*` naming.
Server-side, `context` is stored as a JSON string and is not materialized, so none of it is
queryable. See E4 for the enrichment gap.

### B. Durability, queue and writer

**B1 — Retry exhaustion archives events invisibly and readiness recovers.** Major,
operability and correctness, NEW (the mechanism is documented; the consequence is not
mitigated).
`kansoku-core/src/Kansoku/Writer/Batch.hs:89` answers an insert failure with
`AckRetry (RetryDelay 5)`; ADR 2 records that the pinned Shibuya PGMQ adapter's default
`maxRetries = 3` "auto-archives before handler invocation on delivery four", and the
operations guide says a long outage "can therefore require deliberate archive inspection and
replay". With `KANSOKU_WRITER_VT_SEC` at 60, a ClickHouse unavailability of roughly three to
four minutes is enough. Three consequences follow. The archive happens inside the adapter,
so `kansoku_writer_dead_letters_total` (decode failures only) does not move. The queue
length falls as messages are archived, so `queue_depth` and `writer_flush_stale` clear and
readiness returns to 200 while the data sits in the archive table. There is no replay
command; the guide asks the operator to verify event ids by hand. Snowplow's collector
buffers and backs off for the duration of an outage (collector configuration, undated);
PostHog's dead-letter table carries error, error location and raw payload with a four-week
TTL; RudderStack's JobsDB retries with backoff until a configurable abort. Kansoku's
behaviour is the only one surveyed where a routine maintenance window converts into manual
recovery work with a green health check.
*Suggested improvement:* (1) pause queue consumption while the writer's own ClickHouse
reachability is down, so deliveries are not burned during an outage; the readiness code
already evaluates `clickhouse_query_reachable` and the writer already discards and reopens its
connection, so this is a small circuit breaker. (2) Expose the adapter retry budget and a
growing visibility backoff in configuration. (3) Sample the PGMQ archive table size in the
existing poller and publish `kansoku_queue_archived_messages` so readiness or alerting can
see it. (4) Add a `replay-archive` administrative command that re-enqueues archived messages
by id range and relies on the event-id idempotency boundary.

**B2 — Count-state rollups are replay-sensitive.** Minor, correctness, by-design and
documented.
`db/clickhouse/migrations/0006_rollups_v2.sql` stores `AggregateFunction(count)` for
`page_views_by_route` and `daily_event_counts`; `Kansoku.Metrics.Query` notes that day-grain
page views are "replay-sensitive because count states cannot retract a replay later collapsed
by events_raw". Incremental materialized views see inserted blocks before merges, so a
retried insert that partially overlaps an earlier successful one overcounts; `uniqCombined`
states (DAU, WAU, exposures) are union-safe. The exposure is confined to insert-failure
retries.
*Suggested improvement:* set `non_replicated_deduplication_window` on `events_raw` and send
`insert_deduplication_token` derived from the sorted event ids of each batch, which makes an
exact replay of the same block idempotent before materialized views run (ClickHouse
"deduplicating inserts on retries", 2025-2026). It does not cover a recomposed batch; for
that, `uniqCombinedState(event_id)` for views trades about 0.8% error for replay safety.
Either is acceptable; record the choice in ADR 2 or a successor.

**B3 — The throughput ceiling is asserted, not measured.** Medium, performance and
documentation, NEW.
EP-4's decision log states PostgreSQL is the ceiling, with roughly 3x write amplification,
and names mitigations. No plan records a sustained events-per-second figure; the largest
recorded load is EP-12's 100,000-event fixture. Plausible CE and Umami publish sizing
guidance ("recommended for 1M+ events/day" for ClickHouse in Umami, v3 docs); PostHog
publishes hobby sizing (4 vCPU, 16 GB). An adopter cannot tell whether the queue is adequate
for them.
*Suggested improvement:* a recorded benchmark in the style of EP-17 — sustained `POST
/v1/batch` events per second at the default writer settings on named hardware, queue depth
and flush latency over time, and the point at which `oldest_message_age` grows — plus the
resulting guidance in the operations guide and a stated trigger for the Kafka adapter.

### C. ClickHouse storage, properties and rollups

**C1 — Sort key.** Minor, performance, by-design.
`db/clickhouse/migrations/0004_events_raw_v2.sql` orders `events_raw` by
`(account_id, event_name, occurred_at, event_id)` with monthly partitions. Peers put time
second: PostHog `(team_id, toDate(timestamp), event, cityHash64(distinct_id),
cityHash64(uuid))` (handbook, November 2022), Plausible `(site_id, toDate(timestamp), name,
user_id, timestamp)` (migration 2023-03-20), Aptabase `(app_id, timestamp, event_name)`,
OpenPanel `(project_id, toDate(created_at), created_at, name)` after removing `profile_id`
from the key in November 2025. Kansoku is the only one placing the low-cardinality event
name ahead of time, which ClickHouse's primary-key guidance (filter columns first, low
cardinality first) supports for the many metrics that filter by event name. The cost falls
on all-event scans (events, sessions, retention, exact active users), which traverse every
event-name run; granule pruning by `occurred_at` still applies inside each run. This is a
defensible choice, not a defect; it should be re-checked when B3 and D2 are measured.

**C2 — Dual property storage.** Minor, design and performance, by-design.
ADR 4 keeps the raw `properties` string and a server-side `MATERIALIZED JSON` column because
the pinned ClickHaskell driver cannot carry JSON on the wire. The JSON type has been
production-ready since ClickHouse 25.3 (release blog, 2025-03-27); Rybbit stores native JSON
directly, PostHog materializes individual columns from a string, OpenPanel uses `Map`. Two
cautions apply. The default `max_dynamic_paths` is 1,024; a single tenant with many event
types and free-form property names can exceed it, after which overflow paths move to a
shared, slower representation. Nothing in the migrations sets the limit or `SKIP`s
high-cardinality keys.
*Suggested improvement:* size `max_dynamic_paths` from the registry and monitor
`JSONDynamicPaths(properties_json)` in a periodic check; revisit the dual copy when the
driver gains JSON wire support, as ADR 4 already anticipates.

**C3 — Rollup set.** Minor, design, by-design.
Daily and weekly active users, daily page views by route, daily event counts and daily
experiment exposures as `AggregatingMergeTree` tables match Umami's hourly stats table,
Rybbit's hourly `uniqState` rollups and OpenPanel's `dau_mv`; PostHog and Plausible query
raw rows. Using `uniqCombined` over `String` identities avoids the 32-bit-hash caveat that
applies to numeric inputs. No change needed; see E3 for the semantics question.

### D. Identity

**D1 — Resolution is not time-aware; a later binding reassigns all history.** Medium,
correctness, NEW.
`db/clickhouse/migrations/0012_identity_signals.sql` resolves an anonymous event to
`argMax(user_id, (confidence, observed_at))` over every binding of any signal the event
carries, with no comparison between the binding's `observed_at` and the event's
`occurred_at`. ADR 5 states that policy is view-time so that "changing confidence later
re-scores all history". The consequence on a shared device: cookie C bound to user A in
July and to user B in September attributes every anonymous event ever carrying C, including
A's pre-login July events, to B. PostHog refuses to re-identify an already-identified
distinct id and expects the SDK to rotate the anonymous id on `reset()` (identify doc,
undated); Snowplow's dbt stitching writes a `stitched_user_id` per modelling run; Umami
explicitly does not merge sessions across distinct ids. Kansoku's SDK does rotate on
`reset()`, so the failure needs an application that omits `reset()` on logout, which is
common.
*Suggested improvement:* make cookie resolution interval-based: a binding for signal S to
user U covers anonymous events from the previous binding of S to a different user up to the
next one, so pre-login events attribute to the user who next identified, not the most
recent. Hashed email and device signals can keep recency ranking. At minimum, document that
`reset()` on logout is required for shared-device correctness and surface
`identity_conflicts` counts per account in a metric or diagnostic route.

**D2 — Every exact metric query scans the account's anonymous events for all time.**
Medium, performance, NEW; plan verified, cost unmeasured.
The `event_signal_users` CTE in `events_resolved_v3` selects anonymous events from
`events_raw`, array-joins their signals (re-running `JSONExtractKeysAndValues(identifiers)`
per row), joins `identity_bindings`, aggregates per event, and is left-joined on
`(account_id, event_id)` to the outer scan. `EXPLAIN PLAN indexes=1` on ClickHouse 26.8.2.7
for a two-step funnel over one month shows: the outer `events_raw` read is pruned by
partition, min-max and primary key on account, event name and time; the anonymous-side read
is pruned by account only, with the partition and min-max conditions reported as `true`,
and carries runtime join filters on account, signal kind and signal value built from
`identity_signals`. So the planner does push the account predicate through the join
condition, and the cross-account cliff does not exist; it does not push time or event
name, so the hash-join build side is every anonymous event the account has ever stored
whose signal values have a binding. In a single-tenant deployment that is the whole
pre-login history, and it is rebuilt for every funnel, retention, conversion,
feature-adoption, hourly or monthly users, and experiment conversion or funnel request.
EP-18 records no benchmark; EP-17's 10-million-row evidence covered properties only.
PostHog's persons-on-events design accepted a small overrides join precisely because the
join side is tiny, and squashes it into events periodically (person processing handbook,
undated).
*Suggested improvement:* either (1) have the metric builders inline the resolution join
with the query's time predicate applied to the anonymous side as well, keeping the view for
ad-hoc use, or (2) maintain an account-scoped `resolved_identity` table (anonymous event id
to canonical user) populated incrementally by a materialized view over `identity_signals`
and `events_raw`, which also removes the per-query JSON re-parse. Record a 10-million-row
measurement in the style of EP-17 either way, with the anonymous share of rows as a
parameter.

**D3 — Hashed email is an unsalted SHA-256.** Minor, security, NEW.
`email_sha256` follows the advertising-platform convention for match keys, but an unsalted
hash of a normalised email is reversible by dictionary for common addresses, and
`identity_signals` retains it indefinitely for the binding user. In a single-tenant
deployment every producer is first-party, so a keyed hash costs nothing.
*Suggested improvement:* document that producers should send HMAC-SHA-256 under an
account-level pepper rather than plain SHA-256, or add an `email_hmac` signal kind and
deprecate the plain one in a registry version. Note the limitation in the erasure runbook
until then.

**D4 — Signal vocabulary and limits.** Minor, design, approved.
A closed set of four kinds, 256-character values, confidence as view-time policy, and
visible conflicts compare favourably with PostHog's 200-character cap and illegal-id list and
with Snowplow's domain, network and business user ids. The 180-day fingerprint TTL is a
policy no surveyed peer states as explicitly.

### E. Metric semantics

**E1 — Funnels.** Medium, design, covered-by-plan(EP-26 bounds steps and window) and NEW
for modes.
`buildFunnelSQLAggregate` (`kansoku-core/src/Kansoku/Metrics/Query.hs`) is one
`windowFunnel` pass in default mode: steps in order, intervening events allowed, equal
timestamps may satisfy consecutive steps, window 1 second to 90 days defaulting to the range
length. That is PostHog's "sequential" default and Mixpanel's "specific order". Peers add
strict order (PostHog, Amplitude "Exact order"), any order, exclusion steps, first-time-only
steps, breakdown with first-touch, last-touch or per-step attribution, re-entry counting
(Mixpanel "Totals"), hold-property-constant, and time-to-convert distributions (PostHog
funnels doc, undated; Mixpanel funnels-advanced, undated; Amplitude funnel-analysis,
2026-09-08). Default windows differ: PostHog 14 days, Mixpanel 7 days, Amplitude UI 1 day
and API 30 days; Kansoku's range-length default should be stated in the OpenAPI description
as a deliberate choice.
*Suggested improvement:* `mode=strict` maps to `windowFunnel(..., 'strict_order')` and
`strict_deduplication` with no new storage; `exclude=<event>` can be a per-user check that no
excluded event falls between the first and last satisfied step; `groupBy=prop:` with
first-touch attribution reuses E6's filter compilation; time-to-convert needs per-user first
and last step timestamps, which `windowFunnel` does not return and would require a
`sequenceMatch` or array-based rewrite.

**E2 — Retention.** Medium, design, covered-by-plan(vision "lifetime-first-seen and richer
retention cohorts").
`buildRetentionSQLAggregate` defines the cohort as first activity inside the requested range
and counts a user at offset N only if active on exactly day N ("on" semantics). PostHog
offers first-time, recurring and first-ever-occurrence cohorts with "on" and "on or after"
returns and hour, day, week and month periods (retention doc, undated); Mixpanel defaults to
"On or After" with rolling and calendar modes; Amplitude defines new users by first-ever
event and offers N-day, unbounded and bracketed returns (retention-analysis, 2026-09-08).
Kansoku's guide is explicit that someone active before the range appears new again, which is
honest but surprising for an adopter used to the others. Rybbit and Plausible are the only
surveyed tools with less.
*Suggested improvement:* add `mode=on|on_or_after` (cumulative is a `max` over offsets in
the same query) and a `first_seen` rollup keyed by account and canonical user, enabling
lifetime cohorts and the lifecycle classification in E3. State the "on" semantics in the
OpenAPI description now.

**E3 — Active users are calendar, not rolling; no stickiness or lifecycle.** Medium,
documentation and design, NEW.
`dau` and `wau` roll up by calendar day and `toMonday` week, and the month grain resolves
exactly over the calendar month. PostHog, Mixpanel and Amplitude all define WAU and MAU as
trailing 7-day and 30-day windows evaluated per period (PostHog aggregations doc;
Mixpanel insights doc; Amplitude FAQ, all undated). An adopter reading `users` at
`timeGrain=week` as WAU gets a different number. Stickiness (DAU over MAU) and lifecycle
(new, returning, resurrecting, dormant) are absent; Plausible, Umami and Matomo also lack
them, so this is a product-analytics expectation rather than a web-analytics one.
*Suggested improvement:* state "calendar week" and "calendar month" in the guide and
OpenAPI. Add `window=rolling7|rolling30` as a query-time option over `events_resolved`
(bounded by EP-26's 366-day range), and derive stickiness as a ratio metric from the two.
Lifecycle follows from the E2 first-seen rollup.

**E4 — Web analytics has no enrichment layer.** Major against the vision, otherwise
Medium; covered-by-plan(vision, `/metrics/acquisition` stub) only in part.
Shipped: page views by URL path, sessions as distinct producer session ids, UTM and referrer
stored as columns, user agent stored inside `context` JSON. Absent: bot filtering at any
layer (posthog-js drops known user agents client-side by default and PostHog filters again at
ingestion and query time; Plausible drops datacenter IPs and bots server-side; both undated
docs), referrer and channel classification (PostHog's 20 channel types with custom rules;
Plausible channel grouping), country (Plausible DB-IP by default; PostHog GeoIP transformation
on by default), browser, OS and device (every web tool), bounce rate and visit duration
(Plausible, Umami, Matomo, Rybbit all define bounce as a single-event visit), scroll depth,
entry and exit pages, and the `acquisition` endpoint itself. The browser SDK's 30-minute
inactivity session matches PostHog, Plausible, Matomo, Mixpanel and Amplitude; it lacks
PostHog's 24-hour hard cap. Because no IP is captured, country enrichment would have to be
coarse and at ingest, which is exactly Plausible's model.
*Suggested improvement:* one ExecPlan with five additive parts. (1) A user-agent bot list in
`kansoku-js` mirroring posthog-js's default, with a `context.bot` flag rather than a drop so
the server can count it. (2) Server-side user-agent parsing at ingest into typed
`LowCardinality` columns (browser, OS, device class) and a materialized `context_json` so the
SDK's locale, timezone and viewport become `prop:`-style dimensions. (3) A deterministic
`channel` expression over referrer host and UTM fields, exposed as a `groupBy` dimension and
backing `/metrics/acquisition`. (4) Optional country-only resolution from the request IP at
ingest, storing the two-letter code and discarding the address, behind a configuration flag
defaulting off. (5) Session duration and bounce from `session_start` plus event ordering per
session id, as a `/metrics/sessions` extension rather than a new table.

**E5 — Experiments.** Medium, design, by-design with two gaps.
Exposure, conversion and funnel per variant match the GrowthBook substrate model; the
absence of statistics is stated. Two gaps relative to PostHog, Mixpanel and GrowthBook: a
user exposed to several variants counts in every variant (ADR 6) and the count of such users
is not surfaced, whereas PostHog excludes them by default and GrowthBook alerts above 1% and
removes them (GrowthBook troubleshooting, undated); and there is no sample-ratio check.
*Suggested improvement:* add a `multiple_exposure` point per experiment (users with more than
one variant) and a `variant_share` point so consumers can run a sample-ratio-mismatch test;
both are one query over `experiment_exposures`. Document GrowthBook as the analysis layer:
a read-only ClickHouse user, an assignment query over `events_raw WHERE event_name =
'experiment_viewed'` returning `canonical_user`, `occurred_at`, `experiment`, `variant`, and
fact tables over `events_resolved`. Keep significance out of Kansoku, as ADR 6 says.

**E6 — No filters, single breakdown, no cohorts, no person properties.** Major for
product-analytics parity, Medium for the single-tenant owner, NEW.
The OpenAPI surface exposes `from`, `to`, `timeGrain`, one `groupBy`, `steps`, `window`,
`days`, `experiment` and `event` and nothing else. PostHog filters with equals, contains,
regex, numeric and is-set operators and allows three breakdowns in trends; Mixpanel and
Amplitude compute behavioural cohorts at query time; Plausible's Stats API has `is`,
`is_not`, `contains`, `matches` with `and`, `or`, `not` and `has_done` (Stats API,
2026-09-29). Person properties with `$set` and `$set_once` semantics exist in PostHog,
Mixpanel and Amplitude; Kansoku's `identify` schema declares no properties and stores traits
only inside the event's JSON. For an application embedding metrics, "revenue by plan for
customers on the enterprise tier" needs one filter, and today it needs a new metric
definition in Haskell.
*Suggested improvement:* `filter=prop:<name>:<op>:<value>` repeated, with the operator set
`eq`, `neq`, `in`, `contains`, `gt`, `lt`, `set`, `unset`, compiled through the same
declared-property check and native-parameter binding as `groupBy=prop:` so the ADR 4 safety
argument carries over; allow filters on the built-in dimensions (`source`, `route`,
`event_name`) too. Permit two `groupBy` dimensions with the EP-26 point cap as the guard.
Defer person properties until a use case needs them; a `user_properties` `ReplacingMergeTree`
keyed by account and user with `argMax` semantics would be the natural shape.

**E7 — Session counting across buckets.** Minor, documentation, NEW.
`buildSessionsSQLAggregate` counts distinct session ids per bucket, so a session spanning
midnight counts in both days. Plausible, Umami and Matomo attribute a session to its start.
State this in the guide, or bucket by `min(occurred_at)` per session when E4 adds session
tables.

### F. Schema governance

**F1 — The model is sound; two events the SDKs emit are undeclared.** Minor, documentation
and correctness, NEW.
`docs/contracts/events.json` declares eight events. Both SDKs emit `alias` and `group`, which
are therefore accepted without property checks: an `alias` with no previous id or a `group`
with no organisation id passes. Declare both as version 1 with the required identifiers.

**F2 — Rejections are synchronous and discarded.** Covered by A2. Amplitude's Reject mode
and Segment's Block discard too; Snowplow quarantines. A2's quarantine table closes the gap
if wanted.

**F3 — The registry lives in Haskell source.** Minor, design, by-design.
Adding a declared event is a Kansoku release. Snowplow's Iglu server, Segment, RudderStack
and Amplitude let the data owner publish schemas without redeploying the pipeline. For a
single-tenant first-party deployment where the producers and the service are released
together this is acceptable; note it as a future boundary (a file-loaded registry under the
same immutability tests) rather than a current gap.

### G. Query interface and consumption

**G1 — No documented read path for dashboards or BI.** Medium, documentation, NEW.
Every peer ships a UI; Kansoku deliberately does not. The practical substitute for an
owner-operator is Grafana or Metabase over ClickHouse, which needs three things the docs do
not provide: a read-only ClickHouse role recipe, a statement of which objects are stable
(`events_resolved` and its seven-column contract from ADR 4, the four rollups, the
`identity_conflicts` view) versus internal, and two or three worked queries (DAU, funnel,
revenue by plan) that match the HTTP endpoints' semantics so dashboards and application
metrics agree. This is a short guide and it also serves E5.

**G2 — Typed API shape and bounds.** Approved, covered-by-plan(EP-26, ADR 9 proposal).
Complete-or-error answers with fixed bounds (366 days, 20 steps, 32 offsets, 10,000 points)
are the Amplitude Dashboard REST discipline (cost model, 1,000-row limit, 2026-10-08) and
stricter than Plausible's 10,000-row limit with pagination. The single thing missing is a
per-token request rate limit, which Plausible (600 per hour) and PostHog (240 per minute on
query) both publish; A4 covers it.

**G3 — No export path.** Minor, design, by-design for single-tenant.
Warehouse export (PostHog batch exports, Mixpanel Data Pipelines, Amplitude Export API,
Heap Connect) exists because customers lack the database. The owner has it; G1 is the
substitute.

### H. Operations, privacy and security

**H1 — No raw-event retention policy.** Medium, operability and privacy, NEW.
The operations guide says Kansoku "does not currently automate backups or tenant-specific
raw-event retention". Monthly partitions make a TTL or scheduled `DROP PARTITION` cheap.
PostHog self-hosted likewise keeps events until deleted; Aptabase stores a per-row TTL;
Amplitude and Mixpanel are query-window products. For a single tenant under GDPR's storage
limitation principle, a stated default matters more than a UI.
*Suggested improvement:* `KANSOKU_EVENTS_RETENTION_DAYS` applied as a ClickHouse `TTL
toDateTime(occurred_at) + INTERVAL n DAY` on `events_raw` through a migration, with the
rollups documented as surviving (they do not reference raw rows), and the same treatment for
`identity_signals` non-fingerprint kinds if desired.

**H2 — Erasure is a manual runbook of irreversible mutations.** Medium, operability, NEW.
PostHog exposes an asynchronous person-deletion API with status; Amplitude and Mixpanel run
batch deletion jobs over weeks. Kansoku's runbook is correct and careful, and its "never
omit the account predicate" warning is the kind of thing a command should enforce rather than
a document.
*Suggested improvement:* a `kansoku-admin erase-user --account --user` command that runs the
discovery query, writes its output to a file, prints the mutations it will submit, and
requires a confirmation flag; the same binary is the home for H3.

**H3 — Key revocation is a SQL statement.** Minor, operability, NEW.
Issuance is a command; revocation and listing are SQL against `kansoku.api_keys`. Amplitude
offers self-service rotation (release note, January 2026), PostHog scoped personal keys with
a ten-per-user cap, Plausible per-team keys. Add `list-keys`, `revoke-key <uuid>` and a
documented rotate sequence to the administrative executable.

**H4 — Probe and metrics routes are unauthenticated by design.** Approved. The guide tells
operators to restrict `/ready` and `/internal/metrics` at the network layer, which is the
Prometheus norm. No change.

**H5 — No container or compose distribution.** Minor for this adopter, Major for the
open-source ambition, covered-by-plan(vision "deployment/container examples").
Plausible CE, Aptabase, Umami, Rybbit and OpenPanel all install from a compose file;
PostHog's is the cautionary example. A three-service compose with the two migration steps as
init containers would make the "simple to self-host" claim checkable.

**H6 — Credential transport, CORS and TLS posture.** Approved. Mandatory authentication,
hash-only storage, exact-origin CORS, TLS at the proxy, and no authentication-off switch are
all at or above peer practice.

---

## Part III — Consolidated improvement list

| # | Improvement | Severity addressed | Finding | Size |
| --- | --- | --- | --- | --- |
| 1 | Accept `sentAt`, correct skew, clamp near-future `occurredAt`, reject only beyond tolerance | Major | A1 | Small |
| 2 | Pause writer consumption on storage unavailability; expose retry budget and backoff; publish archive size; add `replay-archive` | Major | B1 | Small to medium |
| 3 | Ingest outcome counters by code; optional TTL'd quarantine of rejected declared events | Major | A2, F2 | Small |
| 4 | `filter=` on standard routes via declared-property compilation; two `groupBy` dimensions | Major | E6 | Medium |
| 5 | Single-tenant consumption guide: read-only role, stable objects, Grafana and GrowthBook recipes | Medium | G1, E5 | Documentation |
| 6 | Web-analytics ExecPlan: SDK bot flag, UA parsing, channel expression, optional country, session duration and bounce, `acquisition` route | Major (vision) | E4, A5 | Large |
| 7 | Benchmark sustained ingest throughput and resolution-view cost; time-bound the anonymous side or add a `resolved_identity` table; publish sizing guidance | Medium | B3, D2 | Medium |
| 8 | Interval-based cookie resolution or documented `reset()` requirement; conflict counts surfaced | Medium | D1 | Medium |
| 9 | Document calendar semantics; add rolling 7 and 30-day windows and stickiness | Medium | E3 | Small |
| 10 | Retention `on_or_after` mode and `first_seen` rollup; lifecycle later | Medium | E2 | Medium |
| 11 | Funnel `mode=strict`, exclusions, first-touch breakdown | Medium | E1 | Medium |
| 12 | `multiple_exposure` and `variant_share` points per experiment | Medium | E5 | Small |
| 13 | Raw-event retention TTL in configuration | Medium | H1 | Small |
| 14 | Administrative executable: erase-user, list-keys, revoke-key, replay-archive | Medium | H2, H3, B1 | Medium |
| 15 | Per-key rate limit with 429 and `Retry-After` | Medium | A4 | Small |
| 16 | Declare `alias` and `group`; HMAC email signal; beacon-only key-in-body; insert dedup token; JSON path limits; session bucket note | Minor | F1, D3, A3, B2, C2, E7 | Small each |

These improvements are now planned: MasterPlan 5
(`docs/masterplans/5-act-on-rev-1-close-silent-loss-paths-add-metric-filters-and-enrich-web-analytics.md`)
coordinates ExecPlans 29 to 40, listed in this record's `produced` field. After discussion on
2026-10-15, A3 became EP-39, the quarantine became EP-29 M4 with purge in EP-37, and person
properties became EP-40; only H5 (compose distribution) remains excluded.

---

## Sources

Vendor documentation and repositories read on 2026-10-14 by the research passes; dates are
the page's own where shown, otherwise "undated".

- PostHog: capture API, API overview, timestamps, ingestion warnings, events and data
  management, identify, person processing handbook, `sharded_events` schema (November 2022),
  funnels, retention, trends aggregations, lifecycle, sessions, channel type, bot detection,
  experiments exposures and statistics, queries and Endpoints, self-host and
  `docker-compose.hobby.yml`, data storage and deletion, `dead_letter_queue.py`; posthog-js
  config and the 1.400.0 release (2026-07-14). https://posthog.com/docs
- Plausible: events API (2026-09-21), metrics definitions and funnel analysis (2026-09-24),
  Stats API (2026-09-29), data policy (September 2026), community-edition v3.2.1 README and
  compose, `ingestion/event.ex`, `write_buffer.ex`, `session/salts.ex`, `events_v2`
  migration (2023-03-20). https://plausible.io/docs, https://github.com/plausible
- Umami: sending stats, tracker configuration, distinct IDs, environment variables (v3.1.0),
  v3.4 release (2026-09-16), ClickHouse `schema.sql`, `crypto.ts`. https://docs.umami.is
- Mixpanel: track-event and import-events references, infrastructure, funnels-advanced,
  retention, insights, sessions, cohorts, user profiles, experiments, Lexicon, rate limits,
  GDPR end-user data management. https://docs.mixpanel.com
- Amplitude: HTTP V2 and Batch APIs (2026-09-15), browser-sdk-2 (2026-10-08), funnel
  analysis (2026-09-08 and 2026-09-22), retention analysis (2026-09-08), define cohort,
  account-level reporting, finalize statistical preferences (2026-10-14), configure schema
  (2026-10-07), Dashboard REST and Export API (2026-10-08), User Privacy API (2026-10-02),
  API key management release note (January 2026). https://amplitude.com/docs
- Segment: HTTP Tracking API (2026-02-24), Spec: Common (2026-07-15), duplicate data guide,
  client-side persistence, Protocols schema configuration (2026-06-26), Typewriter
  (2026-03-25). https://www.twilio.com/docs/segment
- RudderStack: HTTP API, deduplication, common fields, tracking plans, hosted versus open
  source, rudder-server repository. https://www.rudderstack.com/docs
- Snowplow: HTTP requests, canonical event, collector configuration, available enrichments,
  SchemaVer and schema versioning, failed events, Iglu Server, Snowtype, deduplication, identity
  stitching in dbt, self-hosted licence (2024-01-08). https://docs.snowplow.io
- Jitsu: HTTP sending, ClickHouse destination, self-hosting, bulker repository (archived
  2026-04-09). https://jitsu.com/docs
- OpenPanel: README, `event-buffer.ts`, `profile-backfill-buffer.ts`, code migrations
  `3-init-ch.ts` and `8-order-keys.ts` (November 2025), compose guide. https://openpanel.dev
- Rybbit: definitions, funnels, identify users, retention API, self-hosting manual,
  `schema/core.ts` and `liteDashboard.ts`. https://rybbit.com/docs
- Aptabase: `EventsController.cs`, `EventBackgroundWritter.cs`, `0001-events.sql`,
  `key_metrics__v2.liquid`, self-hosting compose. https://github.com/aptabase
- GrowthBook: statistics overview, data sources, fact tables, power, managed warehouse,
  troubleshooting experiments. https://docs.growthbook.io
- ClickHouse: JSON data type and 25.3 release (2025-03-27), use JSON where appropriate,
  choosing a primary key, choosing a partitioning key, ReplacingMergeTree engine and guide,
  deduplicating inserts on retries, selecting an insert strategy, `uniq` and `uniqCombined`
  references, materialized views best practice. https://clickhouse.com/docs
- Matomo, Countly, Databuddy, Swetrix, Heap and June: consulted for self-hosting shape and
  session or funnel definitions only; June shut down on 2025-08-08.
