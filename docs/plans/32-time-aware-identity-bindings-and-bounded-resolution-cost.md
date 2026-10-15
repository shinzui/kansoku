---
id: 32
slug: time-aware-identity-bindings-and-bounded-resolution-cost
title: "Time-aware identity bindings and bounded resolution cost"
kind: exec-plan
created_at: 2026-10-15T13:44:34Z
intention: "intention_01m4zwwdrjesytazp5tb39fe3n"
master_plan: "docs/masterplans/5-act-on-rev-1-close-silent-loss-paths-add-metric-filters-and-enrich-web-analytics.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-15T13:44:34Z
---

# Time-aware identity bindings and bounded resolution cost

This ExecPlan is a living document. Update its living sections and durable ADRs as work
proceeds. It is a child of
`docs/masterplans/5-act-on-rev-1-close-silent-loss-paths-add-metric-filters-and-enrich-web-analytics.md`
and acts on findings D1, D2 and D3 of
`docs/reviews/2026-10-15-architecture-and-feature-set-against-comparable-products.md`.


## Purpose / Big Picture

Two people sharing one browser will stop being merged into whoever logged in last: a cookie
observed with user A in July and user B in September will attribute July's anonymous events
to A, not B. Exact metrics (funnels, retention, conversion, feature adoption, experiment
conversion) will stop rebuilding a hash table of every anonymous event the account has ever
stored on each request; the cost of identity resolution will be measured at ten million rows
and bounded by the request's time window. Producers will be able to send a keyed email hash
instead of a plain SHA-256.


## Progress

- [ ] M1: A reproducible ten-million-row benchmark with a configurable anonymous share records latency, read bytes and peak memory of the funnel, retention and conversion queries against the current view, and the same against both candidate designs.
- [ ] M2: The chosen design is implemented; the benchmark shows the resolved-path cost growing with the query window rather than with account history, with every existing identity test battery green.
- [ ] M3: Interval-based cookie resolution is live: the shared-device fixture attributes pre-login events to the next identifying user; conflicts remain visible.
- [ ] M4: `email_hmac` is an accepted identifier kind with documented pepper guidance, and `email_sha256` is marked discouraged in the catalog and guides.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Decide between an inline time-bounded resolution join and a refreshed
  `analytics.resolved_identity` table by benchmark, not by preference. Promotion criterion:
  the chosen design must keep the two-step funnel over one month under twice the cost of the
  same query without resolution at ten million rows with a 70 percent anonymous share, and must
  not change any count in the existing EP-18 batteries.
  Rationale: EP-17 chose property storage by measurement and the result held; the resolution
  path deserves the same evidence.
  Date: 2026-10-15
- Decision: Cookie bindings resolve by interval: an anonymous event takes the earliest cookie
  binding observed at or after the event, else the latest before it. Hashed email and device
  bindings keep confidence-then-recency ranking. Fingerprints keep their 0.50 confidence and TTL.
  Rationale: The whole purpose of cookie stitching is retroactive attribution of pre-login
  events to the user who then logged in; "most recent wins" reassigns another person's history
  on a shared device. PostHog avoids the problem by refusing re-identification; the interval
  rule keeps Kansoku's evidence model and fixes the attribution.
  Date: 2026-10-15


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Identity evidence is stored in `analytics.identity_signals` and resolved at query time by the
view `analytics.events_resolved` (currently `events_resolved_v3`), both created by
`db/clickhouse/migrations/0012_identity_signals.sql`. The view's `event_signal_users` common
table expression selects every anonymous event (`user_id = ''`), array-joins its cookie and
mapped identifiers, inner-joins `analytics.identity_bindings` (a view assigning confidence
0.95 to `email_sha256`, 0.90 to `cookie`, 0.80 to `device`, 0.50 to `fingerprint`), and picks
`argMax(user_id, (confidence, observed_at))` per event. The outer query then left-joins that
result to `events_raw` on account and event id. `EXPLAIN PLAN indexes=1` on ClickHouse 26.8.2.7
(recorded in REV-1 finding D2) shows the account predicate pushed into the anonymous side but
no time or event-name pruning there, so the build side is the account's whole anonymous
history, and `JSONExtractKeysAndValues(identifiers)` is re-evaluated per row per query.

The view's seven-column output (`event_id, event_name, occurred_at, url, account_id,
canonical_user, properties_json`) is a frozen contract consumed by every exact metric in
`kansoku-core/src/Kansoku/Metrics/Query.hs`; see
[ADR 4](../adr/0004-queryable-event-properties-and-identity-resolved-projection.md) and
[ADR 5](../adr/0005-evidence-based-multi-signal-identity-resolution.md), which this plan
updates. The identifier vocabulary is the closed `IdentifierKind` type in
`kansoku-api/src/Kansoku/Event/Types.hs` with validation in
`kansoku-api/src/Kansoku/Event/Validation.hs`. EP-17's benchmark protocol (scratch table,
five runs, median of `--time`) is recorded in
`docs/plans/17-queryable-event-properties-typed-storage-and-property-based-grouping.md` and is
the model for M1. The erasure runbook is `docs/runbooks/identity-data-deletion.md`.

A "refreshable materialized view" is a ClickHouse view that recomputes its whole result on a
schedule rather than per insert; it exists so a join whose inputs arrive out of order (bindings
after events) can still be precomputed. The browser SDK (`mori://shinzui/kansoku-ts`) rotates
the anonymous id on `reset()`, which applications are expected to call on logout.


## Plan of Work

### M1: Benchmark

Create `scripts/identity-bench.py` that fills a scratch table `analytics.identity_bench_raw`
(same DDL as `events_raw`) with ten million events for one account, a configurable anonymous
share (default 70 percent), a configurable share of anonymous cookies that later identify
(default 40 percent), and matching `identity_signals` rows. Run the funnel, retention and
experiment conversion SQL from `Query.hs` against (a) the current view, (b) an inline join
where the anonymous side is also filtered by the query's account and time window, and (c) a
`resolved_identity` table precomputed by a refreshable materialized view. Record median
latency, `read_bytes` and `memory_usage` from `system.query_log` for each. Capture the three
tables in this plan.

### M2: Bounded resolution

Implement the winner. For (b): the builders in `Query.hs` gain a `resolvedSource` helper that
emits the resolution join inline with the window predicate on both sides, and the view stays
for ad-hoc use. For (c): a migration creates `analytics.resolved_identity`
(`account_id, event_id, canonical_user, resolved_at`) as a refreshable materialized view
(`REFRESH EVERY 5 MINUTE`) over anonymous events and bindings, `events_resolved` becomes a
left join to it, and the operations guide documents the refresh lag as the freshness bound for
exact metrics. Either way, re-run the EP-18 batteries (`QueryIntegrationSpec` identity cases)
and the account-predicate completeness test.

### M3: Interval semantics

Change the resolution expression so that for `cookie` signals the chosen binding is the one
with the smallest `observed_at >= occurred_at`, falling back to the largest `observed_at`,
while other kinds keep `argMax` by `(confidence, observed_at)`, and higher-confidence kinds still
win over cookies. Add a fixture with two users identifying on one cookie and events in between.
Keep `analytics.identity_conflicts` unchanged. Update ADR 5 and `docs/guides/send-events.md`
("Identity") with the rule and with the `reset()` expectation.

### M4: Keyed email signal

Add `EmailHmac` to `IdentifierKind` (`email_hmac`), confidence 0.95, same value rules, and
document in `send-events.md` that producers compute HMAC-SHA-256 over the normalised address
under a deployment pepper they keep in their own secret store; Kansoku never sees the pepper.
Mark `email_sha256` as discouraged in the guide and catalog descriptions without removing it.
Extend the erasure runbook's discovery query with the new kind.


## Concrete Steps

Inside `nix develop` with the stack running:

```bash
python3 scripts/identity-bench.py --rows 10000000 --anonymous 0.7 --identified-cookies 0.4
cabal test kansoku-core --test-options='--match "Identity"'
cabal test kansoku-core --test-options='--match "QueryIntegration"'
just openapi && just contracts && just openapi-check && just contracts-check
```

The benchmark prints one row per (design, query) with median seconds; paste it into M1's
evidence. Drop the scratch table afterwards:

```sql
DROP TABLE IF EXISTS analytics.identity_bench_raw
```


## Validation and Acceptance

1. M1 evidence table present with all three designs.
2. M2: the promotion criterion in the Decision Log holds; `QueryIntegrationSpec` identity and
   experiment cases pass unchanged; `EXPLAIN PLAN indexes=1` for the funnel shows the time
   condition applied on the anonymous side, or the resolved table read instead.
3. M3 fixture: user A identifies on cookie C at day 10, user B at day 40; an anonymous event
   with C on day 5 resolves to A, on day 20 to B, on day 50 to B; an `email_sha256` binding
   still outranks a cookie.
4. M4: an event with `identifiers.email_hmac` is accepted and bound; an unknown kind still
   lists both email kinds in its error.
5. Fingerprint TTL and the erasure runbook still cover every kind.


## Idempotence and Recovery

The benchmark uses a scratch table and is droppable. The migration for design (c) is additive;
rollback is dropping the refreshable view and restoring the previous `events_resolved`
definition, which is kept in the migration file as a comment. Interval semantics are a view
change with no data mutation; reverting is re-creating the previous view.


## Interfaces and Dependencies

No hard dependency on other children; soft dependency on
`docs/plans/31-metric-property-filters-and-dual-grouping.md` only in that both edit
`Query.hs`, so rebase carefully. The seven-column `events_resolved` contract is preserved. The
`email_hmac` identifier kind is claimed here. Libraries: ClickHouse 26.x refreshable
materialized views (verify support on the deployed version before choosing design (c)),
`clickhouse-client` for the benchmark, Python 3 standard library for the script.
