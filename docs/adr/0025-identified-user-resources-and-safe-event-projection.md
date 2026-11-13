---
type: Architecture Decision Record
title: Identified user resources and safe event projection
description: Serve current identified-user resources from retained resolved facts and project history properties through exact schema versions with identifier exclusions.
docId: ADR-25
status: Accepted
date: 2026-11-13
timestamp: 2026-11-13T01:12:31Z
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

Expose service-token `/users`, `/users/activity-counts`, `/users/{userId}` and
`/users/{userId}/events` under principal-derived account scope and the administrative
maintenance fence. Existence requires retained resolved user facts; a static cohort ID
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

## Alternatives considered

Raw user-ID reads lose pre-login stitching. Fixed history cutoffs silently lose extrema.
Raw event serialization discloses undeclared properties and context. Registry declaration
alone permits alias identifiers. These approaches do not meet the resource contract.
Generated schemas require explicit overrides at this boundary: generic Maybe fields are
otherwise optional non-null strings, while these wire objects always include nullable
extrema, host/path and organisation. The shared Relay schema allows zero, while users
require at least one. Tests pin both the nullable required fields and page minimum, and
public acceptance compares served and committed OpenAPI before exercising the routes.

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
