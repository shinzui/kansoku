---
type: Architecture Decision Record
title: Closed-day exact activity and retained-history cohorts
description: Use exact canonical activity populations across rolling users, stickiness, retention and lifecycle with closed UTC observation days and explicit retained-history limits.
docId: ADR-14
status: Proposed
date: 2026-10-15
timestamp: 2026-10-15T23:17:08Z
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
stays positive and at most 366 days. Calendar users retain their exact hour/day/week/month
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

Retention defaults to mode=on and cohort=window. Window cohort means first matching activity
inside the observed range. Lifetime cohort means first matching activity in retained history;
only cohorts starting in the requested range are returned. Offset zero always gives cohort
size. On counts activity on exactly cohort+N, emitting only offsets whose full target UTC day
has closed by `to`. On-or-after counts any activity from cohort+N through cohort+largest
requested offset, including unrequested intermediate days. Its nonzero offsets are emitted
only when the entire maximum horizon has closed. Mature missing activity emits zero; immature
observation is omitted. Historical scans apply the same filters and current identity policy.

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
work and returns a complete error rather than partial sequences or counts. Native functional,
public packaged, pinned consumer and large retained-history performance acceptance are required
before Proposed status becomes Accepted.
