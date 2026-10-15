---
id: 33
slug: acquisition-and-device-enrichment-with-bot-flagging
title: "Acquisition and device enrichment with bot flagging"
kind: exec-plan
created_at: 2026-10-15T13:44:34Z
intention: "intention_01m4zwwdrjesytazp5tb39fe3n"
master_plan: "docs/masterplans/5-act-on-rev-1-close-silent-loss-paths-add-metric-filters-and-enrich-web-analytics.md"
provenance:
  created_by:
    model: "claude-fable-5-1"
    harness: "claude-code"
    at: 2026-10-15T13:44:34Z
  reviews:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-15T15:43:15Z
      verdict: "changes-requested"
      note: "Original draft review found correctness gaps; findings corrected by the accompanying update, with native acceptance still required."
  revisions:
    - model: "gpt-6-astra"
      harness: "codex-cli"
      at: 2026-10-15T15:43:15Z
      mode: "update"
      note: "Reconcile first-release APIs, domain semantics, dependencies and acceptance with the source-validated MP-5 review."
---

# Acquisition and device enrichment with bot flagging


## Purpose / Big Picture


Make acquisition and device analysis useful without storing request IP addresses. Classification
is a deterministic, documented approximation; session attribution and bot exclusion must not
change depending on query fast paths.

## Progress


- [ ] M1: Internal ingest enrichment survives the queue and writer unchanged.
- [ ] M2: Device, bot and channel fixtures pass with documented classification precedence.
- [ ] M3: Acquisition and web metric dimensions use consistent session attribution and filters.
- [ ] M4: Optional country lookup trusts only an explicitly configured proxy boundary.

## Surprises & Discoveries


The current Servant ingest handler does not receive a WAI Request. Derived fields do not exist
in AnalyticsEvent or its queue encoding. A configured header name alone does not establish
trust. The original channel rule classified Facebook paid traffic as paid search before reaching
its paid-social branch.

## Decision Log


On 2026-10-15 separate the public AnalyticsEvent from a versioned internal queued envelope.
Country enrichment requires trusted peer verification and a maintained MMDB reader; do not
write a new binary database parser as a fallback. Acquisition is session-first attribution.

## Outcomes & Retrospective


Planning reviewed; parser selection and native country lookup remain implementation proofs.

## Context and Orientation


`Ingest/Handler.hs` handles decoded events, `Ingest/Queue.hs` serializes them and
`ClickHouse/EventRow.hs` writes native rows. Context is currently a stored JSON string.
`Server.hs` owns WAI middleware. `Metrics/Api.hs` has an acquisition stub.
Read [ADR-3](../adr/0003-api-key-authentication-and-account-scoped-analytics.md),
[ADR-4](../adr/0004-queryable-event-properties-and-identity-resolved-projection.md) and proposed
[ADR-11](../adr/0011-initial-release-analytics-contracts.md).

## Plan of Work


### M1: Carry server enrichment


Define a versioned QueuedEvent containing the validated public event plus derived fields.
Make `Ingest/Queue.hs`, writer decoding, replay and EventRow consume it. Support decoding the
existing queue format during development migration. Producer-supplied context remains input;
server-derived fields are never authoritative from request JSON. EP-30 duplicate acceptance
must retain the first enrichment, not recalculate on retry. Add typed browser_family, os_family,
device_class, is_bot, channel and country_code columns and materialized context_json with a
bounded dynamic-path count; validate DDL on the packaged engine.

### M2: Classify


Use a conservative ordered parser in `Ingest/UserAgent.hs` or a maintained dependency verified
against Mori, Hackage and upstream tags before selecting it. Mori currently has no ua-parser
entry; Hackage reports 0.7.7.0, but this review has not proved GHC compatibility or maintenance.
Cover overlapping Edge/Chrome, iOS/Safari, Android/Linux and tablet strings. Record accuracy on
at least 100 diverse licensed/synthetic fixtures. Flag bots from a versioned server list OR a
Boolean context.bot; false cannot override a server match. Non-web traffic is not implicitly
classified as a browser. Unknown values use documented unknown/missing representations.

In `Ingest/Channel.hs`, canonicalize referrer and event hosts, ignore self-referrals, and apply
this precedence: explicit email medium; paid social medium/campaign on known social source;
paid search with gclid/msclkid or search CPC/PPC; explicit remaining campaign medium; known
search referrer; known social referrer; external referral; direct when no external referrer
or campaign; otherwise other. fbclid alone identifies social referral, not paid traffic.
Use complete host/suffix boundaries, not substring matches. Commit the exact rule table and
version. Derive old test data from the same implementation; no mandatory production backfill
exists because the service has never been deployed.

### M3: Query attribution


Define the common session projection consumed by EP-34: group canonical web events by
`(account_id,source_service,session_id)`, with nonempty session IDs; choose the first page_view,
else earliest web event, ordered by `(occurred_at,event_id)`. Attribution dimensions (channel,
UTMs, referrer host, device, country) come from that event. Session filters select whole sessions
by these attributes, never remove events before computing duration. EP-34 owns the reusable
session state; until it lands, acquisition may use this canonical query-time projection.
`/metrics/acquisition` defaults to distinct sessions and groupBy=channel; measure=users counts
distinct primary canonical subjects among selected sessions: first resolved user, else earliest
anonymous subject, excluding empty identity (a subject can occur in multiple channels).
Accept one/two common or acquisition dimensions, JSON filters from EP-31 and includeBots=false.
Page-views and users apply row-level bot exclusion; session/acquisition excludes sessions with
any bot event. Bypass old rollups unless they encode the same policy. Extend the internal rich
resolved source, not the public seven-column view. Regenerate route records and clients.

### M4: Country


Thread a minimal server-derived request context into ingest via an explicit Servant combinator
or WAI Vault bridge; do not pretend ordinary handlers see the request. Enable lookup only with
KANSOKU_INGEST_GEOIP_DB and KANSOKU_INGEST_TRUSTED_PROXY_CIDRS. Inspect the socket peer first;
ignore forwarded headers from an untrusted peer. For trusted peers walk X-Forwarded-For right
to left past trusted hops, select the first untrusted address, and fail closed on malformed
chains. Do not select the first valid address supplied by a caller. Return ISO country code
or missing; never enqueue/log/trace the address. Use a maintained reader or binding to
libmaxminddb after checking current releases and a GHC/native build spike. Unsupported/corrupt
database is a clear startup failure when configured. Cover IPv4, IPv6 and proxy spoofing.

## Validation and Acceptance


Prove derived fields survive actual enqueue/write/replay; header/body spoofing cannot override
server enrichment. Compare acquisition to hand-counted multi-page, cross-midnight, multi-host
sessions, including changed campaign midway and missing session IDs. Bot defaults apply on
day-grain paths as well as grouped paths. Test Google organic, gclid, Facebook paid,
fbclid-only, email, self-referral, referral and direct. Geo tests use an owned local test DB;
assert absence of test addresses in exported spans, logs and queued bodies. All new query
builders enforce account isolation and the final point cap.

## Concrete Steps


Run commands from the repository root inside `nix develop`. Use the private databases owned
by `scripts/acceptance.sh` and `Kansoku.ClickHouseTestSupport`, not an ambient development
stack: native fixtures mutate tables. Extend that harness for the scenarios in this plan.

```bash
cabal build all --enable-tests
just openapi
just contracts
just check
just acceptance
```

Use focused Hspec examples while developing. Before marking Complete, require nonzero example
counts, no pending required integration tests, regenerated contract checks, and the packaged
executable acceptance above. Record only the relevant evidence here. This follows
[ADR-10](../adr/0010-owned-executable-acceptance-environments.md).

## Idempotence and Recovery


Schema additions have explicit defaults. Reclassification requires rebuilding affected aggregates from canonical data; changing raw rows does not update materialized views. Geo remains off by default.

## Interfaces and Dependencies


Required complete child artifacts: `docs/plans/26-bound-analytics-query-inputs-and-result-cardinality.md`, `docs/plans/31-metric-property-filters-and-dual-grouping.md`.

Hard dependencies: EP-26 and EP-31 Complete. EP-31 path: `docs/plans/31-metric-property-filters-and-dual-grouping.md`. Owns queued enrichment and attribution rules; EP-34 owns session aggregation, and EP-37 consumes the envelope for erasure/replay. SDK input is `mori://shinzui/kansoku-ts/plans/8-serve-kansoku-masterplan-5-sentat-beacon-exit-flush-bot-flag-and-identifyonce`.

Revision note (2026-10-15): reviewed against the current source and revised for first deployment.
[ADR-11](../adr/0011-initial-release-analytics-contracts.md) records the proposed cross-plan
contracts; implementation must supply the acceptance evidence before those contracts become
accepted runtime guarantees.
