---
type: Architecture Decision Record
title: Versioned event schema governance and publication
description: Govern event schemas as immutable, contiguous versions authored in the Haskell registry, with accepted events recording the schema version they matched.
timestamp: 2026-07-19T00:00:00Z
generated:
  by: human:kansoku-maintainers
  at: 2026-07-19T00:00:00Z
docId: ADR-7
status: Accepted
date: 2026-07-19
---

# ADR 0007: Versioned event schema governance and publication

- Deciders: Kansoku maintainers

## Context

Kansoku's in-source registry originally mapped an event name to one mutable property shape.
Producers had no stable version to pin, accepted rows did not record which shape they used,
and other kikan services could only copy declarations from Haskell source. EP17 and EP19 also
made the registry operationally significant: metrics require declared properties, and
`experiment_viewed` has a validation pattern that producers must know.

ADR 0001 requires server, client, and published API contracts to move together. ADR 0004
makes registry declarations a query-compilation boundary. ADR 0006 makes the experiment
property pattern part of the exposure contract. Schema governance must preserve all three
boundaries without introducing a separately deployed registry service.

## Decision

The Haskell registry remains the authoring source of truth. It maps each `EventName` to a
non-empty ascending list of `EventSchema` values. Versions are contiguous from 1, and every
released version is immutable. Any change—including a new optional property, description,
pattern, type, or requiredness—creates the next version with a changelog note. All eight
schemas present when EP20 started became version 1 without changing their validation
semantics.

`AnalyticsEvent.schemaVersion` is optional. Absence means version 1, never latest. A known
event name is validated against the exact requested version; an unavailable version is
rejected with the known-version list. Values outside `1..65535` are invalid. Unknown event
names remain permissive so registry declaration is an opt-in enforcement boundary. Accepted
events persist their effective version in `analytics.events_raw.schema_version UInt16`; old
rows and versionless events read as 1.

The pure `schemaCatalog defaultRegistry` value is published in two forms: public
`GET /v1/schemas` and deterministic `docs/contracts/events.json`. The catalog includes event
versions, changelog notes, property types, requiredness, descriptions, and validation
patterns. Its top-level `catalogVersion` versions the document shape independently from event
versions. The endpoint is unauthenticated and supports the existing `/v1` browser CORS policy.
The Haskell SDK exposes both explicit version pinning and catalog fetching.

The artifact generator sorts object keys and emits no timestamp. A golden test compares the
committed JSON value with the registry-derived catalog; invariant tests require contiguous
versions, matching event names, non-empty notes, and unique property names. Registry and
artifact changes are reviewed and committed together. Property metric compilation uses the
latest declared schema; querying metrics by event schema version remains future scope.

## Alternatives considered

- An external schema service or configuration DSL was rejected because it would add parsing,
  loading, deployment, and drift surfaces before any consumer needs out-of-repository
  authorship.
- Treating an absent version as latest was rejected because every schema bump would silently
  reinterpret legacy producer traffic.
- Allowing optional additions within a released version was rejected because one version
  would then describe multiple shapes and the persisted version would lose evidentiary value.
- Rejecting undeclared event names was rejected because Kansoku deliberately permits organic
  event adoption before governance is added.
- Publishing only a live endpoint was rejected because code review and offline portfolio
  tooling need a deterministic artifact; publishing only the artifact was rejected because
  running producers and CI benefit from discovering the served contract.

## Consequences

Producers can pin an immutable contract, discover it without credentials, and correlate
stored events with the schema era that accepted them. Reviewers get a readable artifact diff
and CI catches unregenerated registry changes. Older producers remain compatible by default.

Every released change consumes a version and duplicates the full property list, which is
intentional clarity. Removing support for an old version requires an explicit future policy;
this ADR does not authorize deletion. The in-source registry still requires a Kansoku code
change, and property metrics do not yet distinguish multiple schema versions of one event.
