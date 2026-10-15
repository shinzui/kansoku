---
type: Architecture Decision Record
title: Whole retained replay-safe web sessions
description: Merge idempotent session state before date and attribute selection so counts, bounce, duration and acquisition share one retained population.
docId: ADR-13
status: Proposed
date: 2026-10-15
timestamp: 2026-10-15T22:46:52Z
generated:
  by: process:codex
  at: 2026-10-15T22:46:52Z
---

# Whole retained replay-safe web sessions

## Context

Incremental ClickHouse materialized views see individual insert blocks. Grouping each block by
its minimum day splits cross-midnight sessions; additive counts double on replay. Date filtering
before session assembly changes start, attribution, bounce and observed duration. Automatic
page-exit and identity events cannot all mean engagement. [ADR-9](0009-bounded-complete-aggregate-responses.md)
owns complete bounded answers; [ADR-12](0012-server-enrichment-and-first-touch-web-acquisition.md)
owns immutable accepted enrichment and first-touch acquisition.

## Decision

A session is the complete retained set of canonical web events sharing account, source service
and a nonempty session ID. `analytics.sessions` stores mergeable minimum/maximum event times,
exact distinct page-view and engagement event IDs, deterministic first-event/first-page/last-page
attributes ordered by (occurred_at,event_id), and maximum bot flag. The storage key contains no
block-specific day. Queries merge all retained states for the account before selecting the
session's minimum timestamp in the public half-open date range and assigning its UTC bucket.

Every state is idempotent for the immutable acceptance contract: set union, minimum, maximum
and argmin/argmax with a unique event ordering key. Rebatching identical facts or rebuilding
from canonical data does not increase counts. Rebuild into an empty replacement target while
writers are stopped, then atomically exchange the table and recreate its insert view. Event
retention, erasure and historical corrections require rebuilding affected derived state under
the maintenance fence; raw-row mutation does not update incremental views.

Attribution remains the first page_view, otherwise earliest web event. Entry/exit routes come
specifically from the first/last page_view. Lifecycle events with an empty URL cannot replace
those routes. Session filters apply to complete session attributes. Entry/exit dimension names
are scoped to session/acquisition queries. Arbitrary event-property filters/grouping are rejected
on sessions because selecting constituent events would require a separate population contract.
Acquisition may use the equivalent canonical projection for finite property selection, and
its users measure uses current exact resolution over retained facts to select one primary
subject per session. Current user traits will use that same first resolved user boundary.

Count includes zero-page sessions. A bounce has exactly one distinct page_view and zero
engagement events; zero-page sessions are not bounces. session_start, page_leave, identify,
identify_once, alias, group and experiment_viewed are lifecycle/identity events. Other events,
excluding page_view itself, are engagement. Observed duration is maximum minus minimum event
time, including page_leave, in seconds with millisecond precision. Average includes one-event
sessions with zero duration; it does not measure active reading time. Bounce rate divides
bounces by all selected sessions. Any bot event excludes the whole session by default;
includeBots=true opts in. Ungrouped requested UTC buckets return zero for every measure when
empty; nonexistent attribute groups are omitted.

Both acquisition session counts and session metrics use this state. Identity-aware acquisition
uses the canonical reference because resolution may change without new session events. Apply
account predicates before assembly and retain native execution/memory limits, deadline and
10000-point complete-or-error bounds after final grouping.

## Alternatives considered

Per-block start days, sum/count states, arbitrary event filtering before assembly and first
nonempty lifecycle URLs were rejected because they change the logical session. Permanently
materializing a resolved user was rejected because later identity evidence can change it.

## Consequences

Late earlier/later events can move the start bucket or extend observed duration. Results cover
retained history only: expiry or erasure can change a session's true retained minimum and
attribution. There is no timeout-based server splitting or inferred stitching of missing IDs.
The browser SDK supplies its inactivity rotation; other producers must supply a session ID.
Proposed status remains until native, public packaged and pinned consumer acceptance passes.
