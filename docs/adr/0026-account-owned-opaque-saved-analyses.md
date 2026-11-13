---
type: Architecture Decision Record
title: Account-owned opaque saved analyses
description: Persist bounded client analysis documents with account isolation, revision-checked editing, serialized quotas and current-read keyset pages.
docId: ADR-26
status: Accepted
date: 2026-11-13
timestamp: 2026-11-13T05:10:00Z
generated:
  by: codex-cli/gpt-6.1-sol
  at: 2026-11-13T05:10:00Z
originatingPlan: docs/plans/69-save-named-analyses-for-an-account.md
---

# Account-owned opaque saved analyses

## Context

Shared accounts need to reopen and edit named client analyses. Saved metric definitions
in [ADR-20](0020-custom-metric-definitions-and-bounded-or-filters.md) are executable
analytics contracts; cohorts in [ADR-19](0019-saved-query-time-cohorts-and-static-membership.md)
define populations. Neither owns arbitrary client state. The service-token and account
boundary in [ADR-3](0003-api-key-authentication-and-account-scoped-analytics.md) and the
problem media contract in [ADR-8](0008-rfc9457-problem-details-and-generated-client-media.md)
apply to this independent resource.

## Decision

`/analyses` stores a flat envelope with name, nullable description, a closed kind
(`trends`, `funnel`, `retention`), positive integral client documentVersion and an object
document. Kansoku never interprets or executes document content and does not validate
references inside it. Names are trimmed and bounded to 1..120 Unicode characters;
descriptions preserve whitespace and allow 500 characters. Metadata rejects zero
characters. Duplicate names are allowed and replacements can change kind.

PostgreSQL owns resource UUIDs, account predicates, positive bigint revisions and
microsecond timestamps. The compact Aeson UTF-8 document encoding is bounded to 32768
bytes and stored as text, never cast to JSONB. Transport parameters carry this encoding
as a string. Decoding on reads preserves JSON value equality, including escaped zero
characters and numbers outside PostgreSQL JSONB's range. Client documentVersion uses
Haskell Integer and a positive integral PostgreSQL numeric column.

Create, replace and delete use a dedicated PostgreSQL connection and an account-wide,
namespaced advisory transaction lock. Under READ COMMITTED the lock is acquired in a
separate statement before count or row reads, so a waiter observes its predecessor's
commit. Connection cleanup rolls back exceptions and cancellation. Every query and
mutation also binds account_id; lock hash collisions affect scheduling only.

POST starts revision 1. Full PUT requires the last read revision, increments even for
identical content, preserves createdAt, and advances updatedAt by at least one
microsecond. Increment exhaustion fails without wrapping. DELETE requires a positive
revision query parameter and returns JSON true. Missing or foreign IDs return 404;
stale mutations return non-retryable 409 analysis_revision_conflict. Mutation SQL also
retains the conditional revision predicate. Backend failures expose only retryable
503 analysis_store_unavailable.

The positive `KANSOKU_ANALYSES_MAX_PER_ACCOUNT` setting defaults to 1000 and must match
across replicas. Creates count and insert under the same lock; full accounts receive
non-retryable 409 analysis_limit_reached. Lowering the limit preserves existing data
and permits reads, replacement and deletion.

Pages use the existing Relay engine with default 20, maximum 100 and optional closed
kind. Canonical order is updated_at descending then UUID ascending in both directions.
The timestamp cursor codec preserves microseconds. Account and kind predicates apply
before page and pageInfo calculation. Cursors encode key values and survive deletion
or movement of their source row. They must be reused with the same filter. Pages are
current reads without a cross-request snapshot; editors refresh from the first page
after mutation. Pagination failures retain the existing Relay error exemption.

## Consequences

Clients own schema migration, rendering and execution of their document versions.
Revision conflicts require reading again before reconciling or replacing. A lost PUT
response is resolved by reading the ID; DELETE absence is confirmed by 404. POST has no
idempotency key and blind retries can create duplicates. No UI, default seed, name
search, snapshots, PATCH, or reference validation is introduced.
