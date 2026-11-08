---
type: Architecture Decision Record
title: Whole retained replay-safe web sessions
description: Merge idempotent session state before date and attribute selection so counts, bounce, duration and acquisition share one retained population.
docId: ADR-13
status: Accepted
date: 2026-10-15
timestamp: 2026-11-08T06:55:25Z
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
those routes. Session filters apply to complete session attributes. Unprefixed entry/exit dimension names
are scoped to session/acquisition queries. Arbitrary event-property filters/grouping are rejected
on sessions because selecting constituent events would require a separate population contract.
Acquisition may use the equivalent canonical projection for finite property selection, and
its users measure uses current exact resolution over retained facts to select one primary
subject per session. Current user traits will use that same first resolved user boundary.

Count includes zero-page sessions. A bounce has exactly one distinct page_view and zero
engagement events; zero-page sessions are not bounces. session_start, page_leave, identify,
identify_once, alias, group and experiment_viewed are lifecycle/identity events. The diagnostic
names client_error and web_vital are also non-engagement for all stored versions, including
versionless and future-version rows. Other events, excluding page_view itself, are engagement. Observed duration is maximum minus minimum event
time, including page_leave, client_error and web_vital, in seconds with millisecond precision. Average includes one-event
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
Native canonical-state equality, repeated replay/rebuilds, packaged public workflow in three
telemetry modes and the pinned generated SDK consumer all pass. The final MasterPlan gate
still owns joint browser adoption and capacity regression with the enlarged derived schema.

## Whole-range temporal grouping

Explicit `timeGrain=none` computes every session measure over the selected complete sessions in one null bucket. The ungrouped empty calendar has one zero point; grouped empty sessions remain absent. Rates and durations are never combined from daily results.

## Session attributes attached to events

Page views, calendar/rolling users and custom metrics opt into a closed `session:` namespace.
Attach the finalized materialized projection once to the existing raw/resolved canonical event
relation by account, source service and nonempty session ID, requiring event source web. An
explicit presence marker and nullable attribute columns make left-join misses independent of
join_use_nulls. The right relation merges all retained states to one row per key before joining;
no event date or bot predicate narrows session assembly. This prevents insert-block multiplication
and preserves first-page/first-event ordering and replay safety without a migration or backfill.

Event timestamps, property samples, canonical people and organization options keep their existing
meaning. Rolling users restrict activity lookback, not session history. Clean page/user events
remain eligible even if another session event is a bot; session:is_bot still reports the maximum
retained flag. Custom metrics retain their existing bot policy. Missing/non-web sessions yield
null groups and never satisfy session predicates, even unset/neq. Real missing attributes can
satisfy unset. Presence guards belong inside each OR term so event alternatives remain valid.
The unprefixed event and whole-session resolvers remain restricted to their existing callers;
entry_page/exit_page suffixes require pages and session:route uses the attribution event URL.

## Correcting retained diagnostic engagement

The exact-ID engagement sets cannot subtract diagnostic IDs that earlier views counted.
Migration `0026_diagnostic_session_engagement` is appended to both immutable native histories:
replace only the view predicate, clear sessions, replay canonical facts under the applied cutoff,
and compare every finalized session field before finishing maintenance. Rebuild inserts disable
block and dependent-view deduplication so a prior replay cannot suppress replacement rows.
The migration coordinator synchronizes schema/sources/target before replay on all configured
replicas, then synchronizes and independently checks every expected UUID at completion and again
before fence release. No unrelated derived population is replayed. Deploy the matching application
binary in that same window. Expired or discarded raw history cannot be reconstructed; installations
without the migration retain the prior aggregate classification. Diagnostics still extend duration.

The qualified Altinity candidate's sequential read mode can hide synchronized historical rows
written without quorum, including a later retention revision. The native toolkit protects that
read policy, so migration SQL retains it and the upgrade fixture uses the supported full-quorum
writer contract. Independent complete-history verification uses `select_sequential_consistency=0`
after all-replica synchronization and refuses fence release if native reconstruction omitted
canonical facts. Nonquorum history outside the supported acknowledgement contract requires
operator diagnosis under the retained fence. Ledger admission and ordinary runtime settings
keep their existing policy. Complete result limits and throwing overflow are explicit on replay
and assertion statements.
