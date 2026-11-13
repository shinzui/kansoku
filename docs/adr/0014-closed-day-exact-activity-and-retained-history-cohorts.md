---
type: Architecture Decision Record
title: Closed-day exact activity and retained-history cohorts
description: Use exact canonical activity populations across rolling users, stickiness, retention and lifecycle with closed UTC observation days and explicit retained-history limits.
docId: ADR-14
status: Accepted
date: 2026-10-15
timestamp: 2026-11-13T14:03:22Z
generated:
  by: process:codex
  at: 2026-10-15T23:17:08Z
---

# Closed-day exact activity and retained-history cohorts

## Context

A window beginning before the requested output range can change rolling activity. Lifetime
first activity becomes unknowable after raw history expires. Emitting zero for an immature
retention offset hides missing observation time. Identity/profile-only updates cannot create,
retain or resurrect active users. [ADR-4](0004-queryable-event-properties-and-identity-resolved-projection.md)
owns exact resolved subjects and declared dimensions; [ADR-9](0009-bounded-complete-aggregate-responses.md)
owns complete bounded answers and query work limits.

## Decision

Users, stickiness, retention and lifecycle capture the UTC date at request start and reject
an exclusive `to` later than that date with permanent `unclosed_observation_window`. All
included days are complete; no separate as-of response metadata is required. The public range
stays positive and at most 366 days. Calendar users support exact hour/day/week/month buckets and explicit whole-range `none`
semantics. Rolling users, stickiness, retention and lifecycle require day grain.

Use current exact canonical subjects, excluding empty subjects and identify, identify_once,
alias and group events throughout every lookback. Individual bot rows are excluded unless
includeBots=true. Filters and up to two nullable group dimensions define the same matching
population at every historical boundary; each group is its own population. Later current-trait
filtering must apply identically across that population. Reserved measure/status/cohort/offset
keys are metadata alongside dimension labels, with typed ordering independent of JSON transport.

For UTC day d, rolling N counts distinct matching subjects in [d-(N-1),d+1), for N=7 or 30.
Extend candidate reads and the exact identity snapshot by N-1 days. Stickiness emits three
numeric points per group/day: daily_active, rolling30_active and ratio, with ratio zero for
an empty denominator and otherwise daily/rolling30. Do not encode numbers in dimension labels.
Ungrouped rolling/daily measure series include zero days; nonexistent attribute groups are omitted.

Retention defaults to period=day, mode=on and cohort=window. Separate startEvent and
returnEvent each independently default to any matching activity. Shared filters apply to both
populations; repeatable startFilter and returnFilter apply only to their side, with distinct
native parameter prefixes and event/property scopes. A single eight-filter/16384-byte budget
covers all three lists. Side filters accept event dimensions, organization IDs and governed
properties; subject selectors (cohort membership, current user/organization traits, user_id)
and session attributes are rejected with invalid_retention_filter, also inside OR groups.
Shared traits and membership preserve their existing selection contract; user_id and sessions
remain unsupported on retention. Saved membership stays anchored to original exclusive to.

Window cohort means first matching start inside the observed range. Lifetime means first
matching start in retained history, with the same start selection; unrelated earlier activity
does not move a signup cohort. Prepare one identity scope covering both populations and cohort
lookbacks. Return rows need only the observed range. No persisted first-seen state is added.

Period is independent of timeGrain: retention still accepts only omitted/day output grain.
Weeks begin UTC Monday, months use calendar month arithmetic. Require aligned from (Monday or
month day one), returning invalid_retention_period rather than moving it. Exclusive to can be
unaligned but must satisfy closed-day observation. Cohort labels are the period first day as
YYYY-MM-DD. A partial final cohort contributes its observed starters. Offset zero always gives
cohort size regardless of returns. Start events supply group values; independently grouped
returns count only when subject and nullable group key both match. A subject may enter several
dimension groups; these populations need not be disjoint. Grouping by event_name with distinct
start/return names therefore yields mature zero returns. Organization timelines can combine a
start by one member with a return by another under the existing attribution policy.

On counts exact subjects with a selected return in [advance(C,N),advance(C,N+1)), emitting only
when the target period is fully closed by to. Advance uses actual days/weeks/months, never
30-day approximations. On-or-after counts once in [advance(C,N),advance(C,H+1)) for maximum
requested offset H, including unrequested intermediate periods; all nonzero offsets wait for
that full horizon to close. Mature missing returns are zero; immature offsets are absent.
Multiple returns on different days cannot multiply a subject count. The old daily functions
remain wrappers, while the typed HTTP/client route appends new arguments and requires callers
to supply Nothing/empty lists for old behavior.

Lifecycle new means first retained matching activity today; returning means active today and
yesterday; resurrecting means active today after an inactive yesterday with earlier retained
activity; dormant means active yesterday and inactive today. Emit nonnegative counts in
`group.status`. New+returning+resurrecting reconciles to exact daily actives. Profile-only
history and updates cannot affect these statuses. Read retained history for first-seen and
one predecessor day for daily membership; do not persist permanent first_seen state.

All paths use the same pool, native execution/memory budgets, outer request deadline and
10000-point complete-or-error boundary. Lifetime lookback can scan every retained matching
fact: a bounded response range is not a scan-cost bound. Resident identity snapshots retain
their separate fail-closed footprint limits. Benchmarks must prepare each query's actual
extended/history scope rather than a smaller public window.

## Alternatives considered

Using raw identity sketches, treating profile updates as activity, dropping unrequested return
days before cumulative retention, recording first ever after expiry, negative dormant counts,
or emitting premature zeros were rejected because they change the advertised populations.
Response as-of metadata was considered; the initial release instead rejects unclosed days as
specified by the activity contract.

## Consequences

Retention, erasure or historical correction can move first retained activity and cohort/status
answers. Group membership and current identity/trait changes can also change historical results.
There is no permanent acquisition-history guarantee. Resource exhaustion asks clients to narrow
work and returns a complete error rather than partial sequences or counts. Native functional, public packaged, pinned consumer and ten-million-event retained-history
performance acceptance pass. The final MasterPlan gate must repeat the expanded performance
workload with later identity/trait/funnel changes and joint SDK/browser adoption.

## Whole-range temporal grouping

Calendar users also accept explicit `timeGrain=none`: exact resolved subjects are counted once per group across the whole selected range and returned with bucket null. Closed-day observation, activity selection and bot rules remain unchanged. Rolling users, stickiness, lifecycle and retention reject this explicit grain.
