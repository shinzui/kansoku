---
type: Architecture Decision Record
title: Organisation aggregation and current membership
description: Aggregate account-scoped organisation timelines while preserving person selectors and attach governed current organisation traits and explicit membership fallback.
docId: ADR-21
status: Accepted
date: 2026-10-16
timestamp: 2026-10-16T12:55:33Z
generated:
  by: process:codex
  at: 2026-10-16T12:55:33Z
---

# Organisation aggregation and current membership

## Context

Events already carry organisation IDs, but the resolved projection omitted them and the
organisation route was a stub. B2B analytics need to count customers and combine actions
across members. [ADR-4](0004-queryable-event-properties-and-identity-resolved-projection.md)
owns the resolved projection; [ADR-16](0016-governed-current-user-traits-and-replay-safe-erasure.md)
owns the current-trait pattern and immutable acceptance eligibility.

## Decision

Append organization_id as column eight of events_resolved and its v3 backing projection.
Preserve the first seven column names, types and order. The rich resolved source already
carries event organisation IDs. All organisation populations use that same account/date
bounded, replay-safe identity source and inherit native budgets and complete point caps.

Users, funnels, retention, ordered signup conversion and feature adoption accept an explicit
organisation aggregation mode. The organisation route always uses it. Adapt the resolved
source's aggregation subject after attaching user traits; merge member event streams and
exclude empty organisation IDs. The existing engines retain their ordering, exclusions,
ratio and cohort rules. Person cohort selectors keep the original resolved user subject;
they select matching members before aggregation. User defaults and experiments retain their
existing populations. Organisation dimensions are event-level; whole-session/acquisition
sources reject them because no single session organisation attribution is defined.

Group v2 writes governed optional plan, industry and country strings and numeric seats.
Store typed values in argMax states ordered by occurred_at, received_at and event_id,
matching deterministic person-trait ordering rather than timestamps alone. First-acceptance
eligibility and schema/type checks prevent legacy or malformed writes from being promoted.
Version 1 stays context-only. Current org: dimensions join once per resolved source by
account and organisation; missing values remain null and seats compares numerically.

Group events with explicit nonempty user and organisation IDs record current membership.
Membership is an argMax state over the same total ordering. Event attribution is default;
user_organization attribution fills only missing event organisation IDs and joins only a
resolved user subject. Explicit event organisation IDs always win. Anonymous/user text
collisions and other accounts cannot establish membership. Neither traits nor membership
are event-time snapshots: changes intentionally reclassify historical reports.

The ordinary funnel already owns attribution for property selection. Preserve first_touch,
last_touch and step values; event and user_organization select organisation attribution
with first-touch property selection. Experiment funnels retain the original closed property
attribution API. User_organization is invalid without organisation aggregation.

The administrative canonical rebuild includes both new state tables so retention can remove
expired winners and reveal remaining retained state. Organisation erasure requires fencing
all producers/readers, cleaning replayable sources and acceptance dispositions, reserving
source IDs, deleting sources and clearing/rebuilding affected state. Deleting aggregate
rows alone permits replay resurrection. See the operational
[runbook](../runbooks/identity-data-deletion.md).

## Alternatives considered

Raw user identity rollups cannot represent merged organisation timelines. Inferring an
organisation from anonymous ID text violates subject namespaces. Applying current membership
to already stamped events loses historical explicit attribution. Timestamp-only state ordering
permits ties to depend on arrival/merge order. Replacing person cohort subquery subjects with
organisation keys would change cohort meaning. These alternatives were rejected.

## Consequences

Organisation moves and late group writes can change historical results. Omitted traits leave
state unchanged; no implicit ungroup/delete event is defined. Shared customer traits remain
analytics observations rather than authorization facts. Large organisation or trait populations
may return a permanent resource-limit error. Clients must send group v2 explicitly to write
traits; Haskell helpers choose it automatically. Existing group v1 producers still stamp event
context and establish explicit membership.
