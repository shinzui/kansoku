---
type: Architecture Decision Record
title: Saved query-time cohorts and static membership
description: Keep account-scoped definitions in PostgreSQL and compute identified-user membership from bounded resolved events or versioned static ClickHouse facts.
docId: ADR-19
status: Accepted
date: 2026-10-16
timestamp: 2026-10-16T18:24:00Z
generated:
  by: process:codex
  at: 2026-10-16T18:24:00Z
---

# Saved query-time cohorts and static membership

## Context

Operators need reusable populations across event, user, session, retention, funnel and
experiment metrics. [ADR-5](0005-evidence-based-multi-signal-identity-resolution.md)
owns resolved identities, [ADR-9](0009-bounded-complete-aggregate-responses.md) owns
complete metric answers, and [ADR-16](0016-governed-current-user-traits-and-replay-safe-erasure.md)
owns current traits. Static cohorts also contain personal identifiers and must participate
in the fenced user-erasure protocol in [ADR-17](0017-fenced-resumable-administration-and-applied-retention.md).

## Decision

PostgreSQL `kansoku.cohorts` owns account-scoped definition CRUD, UUIDs, unique names and
timestamps. Kind is immutable. A behavioural cohort ANDs at most four event conditions and
optional governed current traits. Event windows are `[to - withinDays,to)`, with 1..365 days,
anchored once on the original request's exclusive `to` before metric scopes widen for
retention, lifecycle or whole sessions. Count distinct immutable event IDs. `didNot`
complements the complete frequency condition; upper-bound-only conditions include zero
occurrences. Unknown event names are queryable, while property types remain governed.
Sequences, first-ever occurrence and stopped-doing criteria are deferred.

Event-condition filters accept governed current organization traits, including numeric
seats and traits referenced only inside OR alternatives. Attach the typed nullable trait
source separately to each condition that needs it, joining by account and that resolved
event's stamped organization ID, as defined by [ADR-21](0021-organization-aggregation-and-current-membership.md).
Missing traits fail comparisons; set/unset test presence. Current retained trait updates
can reclassify old events. Outer organization aggregation or current-membership fallback
must not change the saved condition's event attribution or identified-user population.
Governed user traits remain in the separate cohort-level traits field.

Cohorts target identified users. Resolved pre-login events contribute to their user's
behaviour. Anonymous-only subjects remain outside, so the member API and explicit static
user IDs describe the same kind of subject. Positive membership is an account-scoped
subquery; negative membership complements it. Definitions and every operand are bound as
native parameters. Internal identity snapshots cover both the metric source and cohort
lookback, including trait-only populations. Cohorts force identity-aware event paths and
whole-session fallback, and preserve strict funnel timelines and experiment denominators.
Membership is current at query time; there is no refresh job or historical trait snapshot.

Static uploads replace at most 50,000 explicit IDs. ClickHouse `analytics.cohort_members`
uses ReplacingMergeTree over account/cohort/user, with millisecond version and present flag.
A single insert writes present/absent facts, using a version greater than prior cohort
versions. Membership uses argMax(present,version), independent of background merge timing.
A PostgreSQL transaction advisory lock keyed by account/cohort serializes replacement,
update and deletion across processes. Failure releases the lock; retrying a full upload is
safe. Deleting the definition hides leftover member facts. Fenced user erasure removes
static facts and verifies their absence. Retention does not expire manually uploaded lists.

`filter` uses dimension `cohort`, operators eq/neq and a UUID operand; the plan's shorthand
is accepted too. Grouping uses `cohort:<uuid>` and labels in/out, under existing dimension
and point caps. Resource exhaustion returns a complete error. Definition lists use the
released `mori://shinzui/relay-pagination` PostgreSQL keyset engine; member lists use the same cursor/sort contract
with native ClickHouse keysets. Both directions preserve canonical order. Member lists
for behavioural cohorts use the identified population observed in the supplied from/to
window; static lists are independent of event history. Pages are current reads, with no
cross-request snapshot. Pagination 400s follow the Relay wire error exemption from
[ADR-8](0008-rfc9457-problem-details-and-generated-client-media.md).

## Alternatives considered

Scheduled materialization adds stale membership and refresh infrastructure. Storing all
membership in PostgreSQL makes analytics joins cross-store. Mutating ClickHouse tables
for every full replacement depends on mutation completion and loses simple retry semantics.
Raw IDs without a subject namespace can confuse an anonymous cookie with an identified
user. These alternatives were rejected.

## Consequences

Current identity, trait and definition changes can alter historical results. Expensive
membership predicates consume the existing query budgets. Missing/deleted/foreign cohort
references return cohort_not_found without revealing account ownership. Native public
roundtrips cover replay, negative/trait membership, every metric family, account isolation,
full replacement, and bidirectional cursor walks. Definitions and membership are not
updated as one cross-store transaction; uploads are one atomic ClickHouse statement under
a cross-process lock. Definition deletion may leave inaccessible rows until user erasure
or future administrative cleanup.
