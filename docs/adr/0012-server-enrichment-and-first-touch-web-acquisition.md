---
type: Architecture Decision Record
title: Server enrichment and first-touch web acquisition
description: Preserve categorical request enrichment in a private versioned queue envelope and assemble complete retained web sessions before acquisition selection.
docId: ADR-12
status: Accepted
date: 2026-10-15
timestamp: 2026-10-15T22:39:48Z
generated:
  by: process:codex
  at: 2026-10-15T22:09:28Z
---

# Server enrichment and first-touch web acquisition

## Context

The public event carries producer context, but server-derived categories need independent
ownership and stable retry semantics. Enrichment must survive durable queueing, writer retries
and administrative replay. Ordinary Servant ingest handlers do not receive WAI Requests.
ClickHouse aggregate views and date-filtered event scans can silently change bot and session
populations. [ADR-1](0001-sdk-grade-ingest-contract-boundaries.md),
[ADR-3](0003-api-key-authentication-and-account-scoped-analytics.md),
[ADR-4](0004-queryable-event-properties-and-identity-resolved-projection.md) and
[ADR-11](0011-initial-release-analytics-contracts.md) establish the related boundaries.

## Decision

Use the existing request-aware ingest AuthProtect handler to produce minimal typed request
context alongside the authenticated principal. The public event and HTTP client shape do not
acquire internal request-metadata fields. Tenancy still comes solely from the principal.
Classification uses the bounded request user-agent, explicit Boolean producer bot input and
validated public event URL/attribution inputs. Producer categorical claims cannot choose the
authoritative stored columns. Non-web traffic keeps unknown browser/OS/device categories.

Private queue version 1 wraps the validated public event and categorical enrichment with its
rule version. New events are enriched before durable publication; equal acceptance retries
retain the first values. Native rows store browser family, OS family, device class, bot flag,
channel, country code and enrichment version, plus bounded materialized context JSON. Every
new queue producer emits the envelope. Earlier development messages remain readable with
unknown/version-zero enrichment; replay preserves accepted values. A rule/database update is
not an implicit historical reclassification or aggregate backfill.

Use a conservative ordered, versioned user-agent parser and explicit bot signature list.
Boolean context.bot=true is ORed with server signatures; false cannot clear a match.
Channel classification applies email before paid social, paid search, remaining campaign,
organic search/social, external referral and direct/other. Complete host/suffix boundaries and
self-referral suppression prevent substring attribution mistakes. The exact version-one rules
and limitations live in [web enrichment](../guides/web-enrichment.md).

Country is optional and off by default. Enabling it requires both an MMDB path and explicit
trusted proxy CIDRs. Use the maintained released `mori://maxmind/libmaxminddb` reader through
a small country-only binding, rather than a new binary database decoder. Inspect the socket
peer before forwarding headers: ignore those headers from untrusted peers, and for trusted
peers walk a fully valid bounded chain right to left to the first untrusted hop. Ambiguous,
malformed or all-trusted chains yield missing country. Only the two-letter country result
leaves this boundary; request addresses are not copied to queues, event rows, logs or spans.
Invalid configured reader/database state fails startup rather than disabling collection silently.

Acquisition sessions are keyed by account/source_service/session_id over canonical web facts,
excluding empty IDs. Assemble the full retained session before filtering its start date or
attributes. Attribute it to the first page_view, otherwise earliest web event, with
(occurred_at,event_id) ordering. Session filters select whole sessions. The sessions measure
counts keys; users counts each selected session's first canonical user subject, otherwise its
earliest anonymous subject, excluding empty identity. A subject may occur in multiple channels.
The exact users measure shares the bounded identity snapshot and query limits from ADR-4/9.

Page-view and active-user routes exclude individual bot rows by default; acquisition excludes
any session containing a bot event. Their explicit includeBots option controls this policy
at every grain. Other metric routes retain their defined populations. Old rollups are bypassed
when they cannot preserve deduplication, dimensions or bot policy. EP-34 owns the materialized
session state and must preserve this equivalent canonical query-time projection.

## Alternatives considered

Trusting producer browser/country categories would erase server ownership. Re-enriching queue
retries would change immutable accepted facts. Inferring proxy trust from a header name would
let callers choose location. Expanding a nearest-future identity guess or filtering event dates
before finding session start would change analytical populations. All were rejected.

## Consequences

The locked Nix shell/server closure includes the maintained reader, while runtime geography
remains optional. Classification is approximate and versioned, not an authorization fact.
Historical corrections and erasure must include queued envelopes, materialized context and
derived state under fenced maintenance. Canonical query-time acquisition is the initial
reference implementation; the later session projection must prove agreement before replacing it.
Packaged runtime, pinned generated consumer and country observability acceptance pass for
the whole enrichment child. The final MasterPlan gate still owns joint SDK/browser adoption
and the enlarged pipeline capacity regression.
