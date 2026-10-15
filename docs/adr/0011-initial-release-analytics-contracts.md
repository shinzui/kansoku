---
type: Architecture Decision Record
title: Initial release analytics contracts
description: Establish coherent event identity, analytical populations and lifecycle boundaries before the first Kansoku deployment.
docId: ADR-11
status: Proposed
date: 2026-10-15
timestamp: 2026-10-15T15:38:35Z
generated:
  by: process:codex
  at: 2026-10-15T15:38:35Z
originatingPlan: docs/masterplans/5-act-on-rev-1-close-silent-loss-paths-add-metric-filters-and-enrich-web-analytics.md
---

# Initial release analytics contracts

## Context

Kansoku has not been deployed. A review of MasterPlan 5 found contradictory retry, identity,
session and query contracts that would otherwise become difficult to change after adoption.
ADRs 1–10 describe the current implementation; this proposal governs the planned initial release
and does not claim the runtime already implements it. Relevant existing boundaries are
[ingest](0001-sdk-grade-ingest-contract-boundaries.md),
[properties](0004-queryable-event-properties-and-identity-resolved-projection.md),
[identity](0005-evidence-based-multi-signal-identity-resolution.md),
[experiments](0006-exposure-based-experiment-analytics.md) and
[bounded execution](0009-bounded-complete-aggregate-responses.md).

## Decision

Treat account/event ID as an immutable logical event. PostgreSQL records acceptance and queue
send atomically; equal retries acknowledge without re-enqueue, changed content conflicts.
Canonical ClickHouse reads and replay-safe aggregate states prevent queue redelivery from
changing answers. Finite insert-block deduplication is an optimization, not this guarantee.
Normalization and enrichment occur once, before durable queueing. A versioned private envelope
carries derived fields independently of the public event schema.

Resolve explicit users first. Anonymous evidence must be unambiguous within a qualifying session
or signal; conflicts remain visible rather than assigned to the nearest future login. Distinguish
anonymous and user subject namespaces. Candidate events are time-bounded, while relevant evidence
may be outside the requested range. Preserve the public seven-column view and keep a richer
internal source for filters/enrichment. Exact HTTP user counts use the same resolved population
with and without filters; approximate raw sketches are named separately. Identity-only profile
updates do not constitute active-user activity.

Metric filters are repeated JSON objects with bounded typed operands and native SQL parameters.
Group keys retain dimension namespaces and nullable values; native transport is structural JSON.
Missing is distinct from empty string. Invalid/unsupported parameters fail explicitly. Result
bounds do not imply bounded scan cost; expensive histories and funnels also need database limits.

Sessions are keyed by account/source_service/session_id, attributed to their first observed
start, and assembled before date filtering. Attribution uses deterministic first touch.
Lifecycle and identity events do not create engagement; page_leave may extend observed duration
without changing bounce. Current traits segment the resolved user population, with first resolved
user attribution for sessions. Cohort lifetime means retained history, and immature retention
observations are omitted instead of reported as zero.

Funnels have one deterministic chain-selection contract, including repeated names and timestamp
ties; strict mode observes the full eligible timeline. Signup conversion counts ordered completions
among starters rather than dividing unrelated user sets. Experiment contamination counts and
exclusive first-assignment shares have distinct denominators. Current traits are typed and
schema-versioned, with latest set overriding initialization by earliest set-once. Both SDKs
send explicit identify v2/identify_once v1. Publicly reported traits are not authorization facts.

Retention and erasure include replayable inputs and derived state. Explicit fenced maintenance
jobs remain resumable across stores and verify mutations/rebuilds before reporting success.
Quarantine has automatic caps/expiry; manual purge supplements it. Beacon uses body write keys
only, shared admission and pre-side-effect origin enforcement; queued transport is not an
acknowledgement. SQL consumers get deliberate stable views and tested read-only grants.

The corresponding browser implementation is coordinated through
`mori://shinzui/kansoku-ts/plans/8-serve-kansoku-masterplan-5-sentat-beacon-exit-flush-bot-flag-and-identifyonce`.
Cross-origin identity needs explicit SDK storage/handoff, not merely a common account.

## Alternatives considered

Preserving every provisional API shape would add compatibility cost without deployed consumers.
Nearest-future identity guesses were rejected because logout boundaries are not recorded.
Block tokens alone were rejected because retries can be regrouped or outlive the dedup window.
Silently changing raw/exact populations through query optimization was rejected because filters
must not alter the definition of a user. Automatic initial deployment approval from document
review was rejected: native failure tests and SDK/consumer proofs remain required.

## Consequences

MasterPlan 5 has stronger foundational dependencies and additional work inside its existing
children. Storage/query performance must be measured before claiming readiness. Proposed status
remains until the implementation evidence passes and affected accepted ADRs are reconciled.
The first deployment can then freeze a coherent contract without transitional compatibility APIs.
