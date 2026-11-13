---
type: Architecture Decision Record
title: Identified user resources and safe event projection
description: Serve current identified-user resources from retained resolved facts and project history properties through exact schema versions with identifier exclusions.
docId: ADR-25
status: Accepted
date: 2026-11-13
timestamp: 2026-11-13T14:55:39Z
generated:
  by: process:codex
  at: 2026-11-13T00:59:03Z
originatingPlan: docs/plans/67-read-identified-users-profiles-and-event-history.md
---

# Identified user resources and safe event projection

## Context

Consumers need an identified-user directory, current profile, resolved event history and exact
identified/anonymous activity split. Aggregate grouping cannot provide nullable activity
extrema or profile provenance. [ADR-5](0005-evidence-based-multi-signal-identity-resolution.md)
owns conservative stitching; [ADR-16](0016-governed-current-user-traits-and-replay-safe-erasure.md)
owns governed observations; [ADR-19](0019-saved-query-time-cohorts-and-static-membership.md)
owns saved selection and current-read pagination.

## Decision

Expose service-token `/users`, `/users/activity-counts`, `/users/{userId}`,
`/users/{userId}/events` and `/users/{userId}/hosts` under principal-derived account scope
and the administrative maintenance fence. Existence requires retained resolved user facts; a static cohort ID
alone does not establish a user. Whole-retained-history queries discover actual canonical
date bounds and prepare evidence on their physical query connection. Date selection never
clips directory activity extrema. Identity/profile-only users have null extrema.

Activity excludes identify, identify_once, alias and group, and bots by default. Profile
retainedEventCount includes all retained event kinds and bots; its extrema use default
activity. Counts use exact distinct subjects independently of directory filters. Profile
trait provenance reduces eligible canonical observations with set precedence and the
stored occurrence/receipt/event-ID order. Evidence returns only distinct binding counts,
including conflicted bindings, with query-time fingerprint expiry. Original anonymous
subjects count only events without explicit user IDs that resolve to this person.

Directory and history use complete keyset cursors in both directions. Reads do not promise
a cross-request snapshot: identity changes, new facts, retention and traits can alter
results. Profile component queries share one owned connection and deadline but remain
eventually consistent across tables. Exhaustion returns an error without partial output.

History constructs a fresh public object. Properties must be present, compatible declared
string/number/Boolean scalars at the event's exact stored schema version. Unknown versions,
PTAny, null, objects, arrays and nonfinite numeric conversions yield no property. Identifier
property names remain excluded even when declared; alias payloads are entirely omitted.
Identify properties require governed user-trait names and group properties governed
organisation-trait names. Private raw property extraction stays inside bounded query
handling and is never returned or included in exception text. Session ID is an explicit
public envelope field, not permission to expose other identifiers or context.

History accepts at most one event_name eq/in term and one host eq/in term, ANDed. Host values must
be canonical lowercase domains of 1..253 characters without scheme, port, path, whitespace
or trailing dot; in accepts 1..100 raw values before deduplication. Null hosts never match.
One canonical-domain expression supplies node projection, filtering and facet grouping.
ClickHouse's `domain()` rejects trailing-dot authorities, so the helper strips authority
trailing dots before parsing, preserving ports and path/query text. This corrects query-time
metric host grouping too; it does not rewrite URLs or recompute stored enrichment.
The hosts facet shares history's retained source, existence check, date predicates, bot
policy and event-name selection; it rejects host filters. Each entry has a required nullable
host, exact eventCount and lastOccurredAt. Non-null entries sort by count descending then
host ascending, with null last. Zero-count entries are omitted. Exactly 1000 entries including
null succeed; a 1001st witness returns user_hosts_too_large 400 without partial output,
following [ADR-9](0009-bounded-complete-aggregate-responses.md). Native failure or deadline
remains clickhouse_unavailable 503.

Totals come from summing selected facet entries, including null for all sites, rather than
adding a counting scan and totalCount to every shared Relay page. Counts equal the paged
history size for identical selection on settled data; neither endpoint promises a shared
snapshot across requests. An existing user with an empty selection returns an empty facet;
existence is checked against retained resolved facts before selection.

## Alternatives considered

Raw user-ID reads lose pre-login stitching. Fixed history cutoffs silently lose extrema.
Raw event serialization discloses undeclared properties and context. Registry declaration
alone permits alias identifiers. These approaches do not meet the resource contract.
Generated schemas require explicit overrides at this boundary: generic Maybe fields are
otherwise optional non-null strings, while these wire objects always include nullable
extrema, host/path and organisation. The shared Relay schema allows zero, while users
require at least one. Tests pin both the nullable required fields and page minimum, and
public acceptance compares served and committed OpenAPI before exercising the routes.

Using `/metrics/events?groupBy=host` as a history facet was rejected: metrics require paired
dates spanning at most 366 days, do not offer history's bot selection, and return an empty
result for unknown users. They cannot supply exact totals for the full history contract.

No additional persistent projection or migration is required. Administrative identity
unlinking intentionally retains explicit user facts and therefore can retain a profile;
`erase-user --delete-events` removes those facts and makes the user disappear. Resource
existence must not reinterpret unlinking as event deletion.

## Consequences

Analytical identity and current traits are inference, never authorization facts. Retention
and fenced erasure rebuild shared state and affect these resources immediately after the
maintenance fence releases. Large retained populations can exceed existing query budgets;
input truncation is not a recovery strategy. Consumers must refresh and deduplicate after
concurrent changes and keep selection parameters fixed during pagination.
