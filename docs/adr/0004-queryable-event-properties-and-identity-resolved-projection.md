---
type: Architecture Decision Record
title: Queryable event properties and identity-resolved projection
description: Store event properties as native ClickHouse JSON and expose them for metric grouping only after registry declaration.
timestamp: 2026-10-16T12:10:52Z
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

The query boundary accepts event properties only after establishing a finite registered event
scope and compatible scalar declarations across its retained schema versions. A positive
event_name eq/in filter can scope the all-event metric. PTAny, objects/arrays and conflicting
scalar declarations do not establish a scalar dimension. Missing declarations in older
versions produce missing values. Native JSON extraction uses dynamicElement for String/Bool
and guarded finite Float64 conversion for numeric variants; historical incompatible values
become NULL instead of raising conversion errors. No query parses the raw properties string.

HTTP uses repeatable bounded JSON filters with native operand parameters, including explicit
UTF-8 ByteString conversion rather than the driver's Char8 String instance. Operators are eq,
neq, in, contains, gt, lt, set and unset. Missing/null/type-incompatible values are unset; every
comparison including neq is false for unset. An empty property string remains present.

One or two distinct dimensions retain their complete names, including prop:<name>. group values
are nullable strings; null, empty string and literal other remain distinct. Native group_key is
a JSON array of nullable strings, decoded structurally with arity validation. Separate scalar
sort columns preserve numeric/Boolean/string ordering independently of JSON serialization.
Funnel property attribution is an explicit exception: missing/null/unreached values use
`other` and merge with literal `other` strings. Its selected-step or compatible finite-scope
declaration rules and retained typed sorting are defined in
[ADR-15](0015-deterministic-selected-funnel-chains-and-exclusive-exposure-diagnostics.md).
Funnel, retention and experiment metadata use the same structural transport. Property default
groups in internal definitions omit the prop: prefix; the wire always includes it. Sum/Average
inputs use aggregationProperty and exclude missing/incompatible values before aggregation.

Unsupported, duplicate or missing query parameters are validated after authentication, before
Servant could ignore them. The route matrix is explicit in the query guide and generated API.
The HTTP users route always counts exact resolved activity, excluding identify, identify_once,
alias and group events, with the same population under filtering. Page views/counts read
canonical facts consistently; raw identity sketches remain an explicit SQL/experiment policy.

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
- Independent public identity policies are rejected because their populations could drift.
  The rich private source and stable seven-column projection share the conservative policy
  and native conformance fixtures described in ADR-5.

## Consequences

The raw `properties` string remains the source of truth and the ClickHaskell insert block is
unchanged. New registry declarations become queryable without a ClickHouse migration.
Property names remain limited to a conservative identifier charset and must be declared for
every event in a metric, except for the explicit funnel attribution scope in ADR-15.

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

HTTP identity queries use the parameterized `resolvedSource` helper, with candidate account/date
bounds and server-owned temporary evidence snapshots. The public seven columns remain stable;
new filter/session/enrichment fields belong to the rich private relation. Cached and direct
native relations must agree for every identity fixture. Raw approximate user/exposure sketches
now prefix user/anonymous namespaces too; they still do not promise query-time stitching.

Current person attributes use the separate governed `user:` namespace described in
[ADR-16](0016-governed-current-user-traits-and-replay-safe-erasure.md). Their eligibility is
preserved from first acceptance and their current values join only resolved user subjects.
The generic `prop:` declaration mechanism does not establish governed trait eligibility.
Whole-session current-trait selection joins after retained session assembly; account/user text
without the resolved user kind must never match a trait row.
