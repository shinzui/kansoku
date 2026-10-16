---
type: Architecture Decision Record
title: Governed current user traits and replay-safe erasure
description: Persist first-acceptance schema eligibility for typed current traits, join only resolved users, attribute whole sessions before segmentation, and reserve erased source IDs before rebuilding state.
docId: ADR-16
status: Accepted
date: 2026-10-16
timestamp: 2026-10-16T12:55:33Z
generated:
  by: process:codex
  at: 2026-10-16T01:01:59Z
---

# Governed current user traits and replay-safe erasure

## Context

Current person attributes must apply consistently to pre-login activity after conservative
identity resolution. Anonymous IDs and user IDs can contain identical text. String JSON
values must not compare as quoted literals, and numeric traits need numeric ordering. Late
observations and first-accepted receipt times need deterministic ordering. Existing profile
v1 events were not governed trait writes. [ADR-5](0005-evidence-based-multi-signal-identity-resolution.md)
owns resolved subjects, [ADR-7](0007-versioned-event-schema-governance-and-publication.md)
owns immutable schema versions, and [ADR-13](0013-whole-retained-replay-safe-web-sessions.md)
owns whole-session attribution.

## Decision

A shared Haskell catalog declares optional string traits plan, signup_source, initial_plan,
country and role, plus numeric company_size. Company size must be a finite nonnegative
integer before Float64 conversion. Null/deletion is rejected for declared traits; omitted
keys leave values unchanged. Extra event properties are not promoted. Identify v2 sets traits;
identify_once v1 initializes them. Both require a nonempty top-level userId. Identify v1 stays
identity-only. Helpers explicitly select governed versions, preserving explicit version APIs.
Changing a governed trait type requires a storage migration and schema decision.

Persist server-owned eligibility from the first accepted envelope. Private queue v2 carries
traitsEligible; legacy public/v0 and private v1 envelopes decode as ineligible, even if a v1
payload supplies that field. The writer revalidates flagged operations before setting raw
`governed_traits_valid`. Old raw rows default false. Actual stored schema_version and guarded
native scalar types remain required. Native JSON/Float64 extraction can round away invalid
fractions or underflow; it cannot establish original decimal integrality. Public event JSON
cannot set the marker. First acceptance keeps eligibility immutable across retries and upgrades.

Per account/user/trait, set states use argMax and set-once states use argMin over the total
stored order (occurred_at milliseconds, received_at milliseconds, event_id). State values are
(type, decoded String, Float64) tuples; presence is separate from empty string or numeric zero.
Any latest set overrides set-once, regardless of relative time; otherwise earliest set-once
wins. Duplicate immutable events cannot change the winner. No ungoverned legacy backfill is
performed. Current values intentionally reclassify historical queries.

Only catalog names establish user: dimensions. Pivot referenced traits once per resolved
source and join by account plus user subject kind/ID, never anonymous fallback text. Missing
traits stay null and inherit typed set/unset/comparison semantics. Event/page/user/revenue
queries resolve subjects when trait selection needs it. Ratios use the same current population
on both sides; cohorts/lifecycle use it across lookback. Funnels select participant traits;
strict current-user filters retain complete timelines, while strict event filters remain
errors under [ADR-15](0015-deterministic-selected-funnel-chains-and-exclusive-exposure-diagnostics.md).

Sessions and acquisition assemble complete retained sessions, choose the first resolved user,
then apply that user's current traits. A later user or attribute filter cannot remove earlier
session events. Identity-aware canonical assembly replaces the materialized fast path only
when required. Query identity scopes include the complete retained session/history scope.

Experiment selection supports user dimensions only. Segmented exposure counts use exact
resolved subjects; unsegmented default exposure counts retain the explicit raw-identity sketch.
Conversion, funnel and diagnostics retain their exposure gating and assignment denominators
within each selected trait population. Organisation aggregation and current membership are defined separately in
[ADR-21](0021-organization-aggregation-and-current-membership.md).
All metric paths inherit native memory/time budgets, outer cancellation and complete point caps.

Fenced lifecycle primitives reserve account/event-ID tombstones before deleting or scrubbing
governed source writes, clear both aggregate states, then rebuild eligible retained facts.
Original raw replay cannot restore erased trait state; new immutable IDs may initialize traits.
The caller must fence ingest, writer and metric readers. EP-37 additionally cleans replayable
queue/archive/acceptance inputs and persists resumable maintenance progress before releasing
its fence; these primitives alone are not an atomic public administrative API.

## Alternatives considered

Quoted scalar JSON, anonymous-ID fallback joins, event-time trait snapshots, set-once values
that override explicit sets, and null as implicit deletion were rejected. Inferring eligibility
solely from native numeric types was rejected after precision-loss counterexamples. Deleting
only the latest state without reserving source IDs permits replay resurrection and was rejected.

## Consequences

Current trait and identity changes can alter historical answers. Large retained-session or
trait populations can exhaust query budgets and return complete errors. Public write keys may
report traits: role and other business attributes are analytics observations, never authorization
facts. Trusted business reporting requires service-owned producers. Native, public packaged,
pinned SDK/helper and lifecycle acceptance pass. The expanded 28-case, 10M-fact cost gate
also remains below 2× and the shared memory budget. EP-37 must establish the persisted fence
and coordinate cross-store lifecycle cleanup before exposing these primitives administratively.
