---
type: Architecture Decision Record
title: Queryable event properties and identity-resolved projection
description: Store event properties as native ClickHouse JSON and expose them for metric grouping only after registry declaration.
timestamp: 2026-10-15T17:23:33Z
generated:
  by: human:kansoku-maintainers
  at: 2026-07-19T00:00:00Z
docId: ADR-4
status: Accepted
date: 2026-07-19
---

# ADR 0004: Queryable event properties and identity-resolved projection

- Deciders: Kansoku maintainers

## Context

Kansoku stores every event's `properties` object as a JSON-encoded ClickHouse `String`.
That preserves arbitrary producer data but forces each property query to parse the full
string. The metrics compiler also had no safe grammar for property dimensions, and
Sum/Average metrics hardcoded the `amount` property. Unique-user metrics read
`analytics.events_resolved`, whose original six-column projection omitted event properties.

The pinned ClickHaskell driver has no native-protocol `JSON` or `Map` type. Any typed
representation must therefore remain inside ClickHouse and expose only primitive query
results to Haskell. Property names supplied by callers also require a registry membership
gate before they can become SQL identifiers.

## Decision

`analytics.events_raw` has a server-computed
`properties_json JSON MATERIALIZED CAST(properties, 'JSON')` column. A 10-million-row
benchmark selected native JSON over raw `JSONExtract*`, per-property materialized columns,
and a `Map(String, String)` shadow: its grouped aggregate median was 0.043 seconds versus
0.272 seconds for raw extraction, and its compressed size was 34% of the raw properties
column. Per-property columns were faster but would require a migration for each registry
change; the map failed the benchmark thresholds.

The metric query boundary accepts properties only after every event schema queried by the
metric declares the name in `defaultRegistry`. HTTP grouping uses `prop:<name>` so property
names cannot collide with built-in dimensions. Metric definitions name default property
groups without the prefix and declare Sum/Average inputs through
`aggregationProperty`. SQL reads group strings with
`toString(getSubcolumn(properties_json, '<name>'))` and numeric values with
`CAST(getSubcolumn(properties_json, '<name>'), 'Float64')`; it never applies
`JSONExtract*` to the raw column. `getSubcolumn` is used instead of direct dot syntax so
the same compiled expression works when `properties_json` crosses the
`analytics.events_resolved` view boundary. The existing `revenue` builtin is exposed
through the additive `GET /metrics/revenue` route so this contract is available through
the public metrics API.

`analytics.events_resolved` extends its stable projection with a seventh,
server-only `properties_json` column. This lets unique-user property metrics keep canonical
identity stitching instead of falling back to raw `user_id` or `anonymous_id` values.

## Alternatives considered

- Query-time `JSONExtract*` was rejected because it was 6.3 times slower in the benchmark
  and repeats parsing for every query.
- Registry-driven typed columns were not selected even though they were fastest, because
  adding or versioning a declared property would require ClickHouse DDL and backfill work.
- A `Map(String, String)` column was rejected because it erased types and exceeded both the
  latency and storage thresholds.
- Reading unique-user property metrics from `events_raw` was rejected because it would
  bypass canonical identity resolution and change metric meaning.
- A second identity-resolved view was rejected because it would duplicate the stitching
  query and allow the two projections to drift.

## Consequences

The raw `properties` string remains the source of truth and the ClickHaskell insert block is
unchanged. New registry declarations become queryable without a ClickHouse migration.
Property names remain limited to a conservative identifier charset and must be declared for
every event in a metric.

Future migrations that recreate `analytics.events_resolved`, including multi-signal
identity work, must preserve the ordered seven-column contract: `event_id`, `event_name`,
`occurred_at`, `url`, `account_id`, `canonical_user`, `properties_json`. Experiment
rollups consume the same native JSON expressions. If ClickHaskell later gains JSON wire
support, changing the insert or result protocol remains a separate measured decision.

## Canonical replay source

`analytics.events_canonical` is the internal source for query-time aggregation and identity
joins. Its current implementation reads immutable accepted rows from `events_raw FINAL` and
explicitly includes `properties_json`, since ClickHouse's default asterisk excludes materialized
columns. Identity evidence projections also apply FINAL before observations are joined/counted.
The ordered seven-column public resolved view remains unchanged.

Daily event/page-view rollups union `uniqExact` event-ID states. Sums and averages read canonical
rows; additive materialized-view count states cannot retract a duplicate insert. Correctness
holds before background merges, across regrouped retries and after restart, independently of
any finite insert-block deduplication window. These guarantees require the immutable acceptance
boundary in [ADR-1](0001-sdk-grade-ingest-contract-boundaries.md). Administrative rebuilds keep
the writer stopped and replace states from canonical data; interrupted rebuilds can restart.
The earlier JSON representation benchmark does not establish the cost of FINAL; the deployment
capacity measurement must include this canonical source.
