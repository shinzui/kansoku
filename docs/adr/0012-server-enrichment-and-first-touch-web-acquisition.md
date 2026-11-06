---
type: Architecture Decision Record
title: Server enrichment and first-touch web acquisition
description: Preserve categorical request enrichment in a private versioned queue envelope and assemble complete retained web sessions before acquisition selection.
docId: ADR-12
status: Accepted
date: 2026-10-15
timestamp: 2026-11-06T13:13:28Z
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

Private queue version 2 wraps the validated public event and categorical enrichment with its
rule version and independent trait eligibility. Envelope versions 1 and 2 remain readable. New events are enriched before durable publication; equal acceptance retries
retain the first values. Native rows store browser family, OS family, device class, bot flag,
channel, country code and enrichment version, plus bounded materialized context JSON. Every
new queue producer emits the envelope. Earlier development messages remain readable with
unknown/version-zero enrichment; replay preserves accepted values. A rule/database update is
not an implicit historical reclassification or aggregate backfill.

Use a conservative ordered, versioned user-agent parser and explicit bot signature list.
Boolean context.bot=true is ORed with server signatures; false cannot clear a match.
Channel classification applies email before paid social, paid search, remaining campaign,
AI assistant, organic search/social, external referral and direct/other. Complete host/suffix boundaries and
self-referral suppression prevent substring attribution mistakes. Channel/enrichment version 2 recognizes the bounded assistant hosts and exact source aliases,
using each nonblank explicit source/medium/campaign field before the first nonblank matching
HTTP(S) URL query parameter. This fallback never mutates the public event. Browser/device/OS
and bot algorithms remain version 1; queue envelope numbering is independent. Stored versions
0 and 1 remain readable, while `ai_assistant` is valid only at version 2. Accepted historical
channels are never recomputed: old Gemini organic-search records coexist with new assistant
records. Upgraded consumers must precede version-2 producers; rollback must retain compatible
readers. The exact host/alias lists, ordered rules and limitations live in [web enrichment](../guides/web-enrichment.md).

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

Acquisition converted_users and conversion_rate select one first session per nonempty
canonical subject across the full requested range, after whole-session filters, current traits,
cohorts and any-bot selection. Choose the minimum (session_start_at,source_service,session_id)
and carry the complete attribution row before grouping or bucketing. This means first selected
touch in this range, not lifetime first visit. Legacy users retains distinct subjects within
each bucket/group and may count a person in several groups; it is not the new rate's denominator.

A required bounded conversionEvents list selects canonical resolved facts from any supported
source in the same account and half-open occurrence range, with no session-ID requirement.
Session filters do not restrict conversion attributes or source service. Reduce to one latest
eligible timestamp per canonical subject with an explicit match marker before a left join.
A person converts when that timestamp is at or after their chosen session start. This avoids
join-default timestamps, replay inflation and repeated conversion multiplication. Counts and
rates use the same first-session population; zero-conversion groups survive. Individually bot
conversion events are excluded by default; includeBots restores those and any-bot sessions.
Both branches share retained-history identity resolution, native limits and complete result bounds.
All supported grains, including explicit none with null buckets, assign output to the chosen
session start; whole-range rates are computed directly rather than averaged from buckets.

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
derived state under fenced maintenance. Canonical query-time acquisition remains the identity-aware/finite-property reference.
[ADR-13](0013-whole-retained-replay-safe-web-sessions.md) now supplies the accepted equivalent
materialized session state for ordinary session counts and acquisition.
Packaged runtime, pinned generated consumer and country observability acceptance pass for
the whole enrichment child. The final MasterPlan gate still owns joint SDK/browser adoption
and the enlarged pipeline capacity regression.
