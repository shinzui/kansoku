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
    - model: "gpt-6.1-sol"
      harness: "codex-cli"
      at: 2026-10-15T21:31:48Z
      mode: "implement"
      note: "Begin versioned queued enrichment, deterministic web classification and attribution, and trusted optional country lookup after EP-31 acceptance."
---

# Acquisition and device enrichment with bot flagging


## Purpose / Big Picture


Make acquisition and device analysis useful without storing request IP addresses. Classification
is a deterministic, documented approximation; session attribution and bot exclusion must not
change depending on query fast paths.

## Developer Workflow Acceptance

Starting state: a developer has the previously supported server/SDK, an account write key
and service token, and ordinary web page capture with nonempty session IDs. The outcome is
session-first channel/device/country analysis without changing event JSON, naming internal
queue versions, generating contracts manually or adding classification flags to producers.
After the normal database migration/start workflow, the ordinary reporting command is:

```bash
curl --get "$KANSOKU_URL/metrics/acquisition" \
  --header "Authorization: Bearer $KANSOKU_SERVICE_TOKEN" \
  --data-urlencode "from=2026-07-01" --data-urlencode "to=2026-07-03"
```

This defaults to sessions grouped by channel with bots excluded. Adding
`--data-urlencode "groupBy=channel,browser_family"` is the only change needed for a device
breakdown. Repeating the query and retrying the producer preserve the same answer. Existing
queued development messages remain readable. No enrichment-specific SDK update or manual
row backfill is required. GeoIP is optional and silent when off; opting in requires obtaining
a licensed country/city MMDB and setting the two documented database/trusted-CIDR values.
The trust boundary cannot safely be inferred. Invalid configured databases fail startup
with a clear next action, never an unexplained missing native dependency.

The existing fresh-clone quickstart currently requires three terminals, entering the Nix
shell, starting stores, applying two migration commands, issuing two keys and starting the
server. Count those steps rather than hiding them in test fixtures. The MasterPlan's final
EP-38 consumption guide records and proves the supported setup/reuse/recovery workflow;
this child's acceptance must prove an actual pre-change producer reaches the new reporting
outcome through public commands and HTTP, with normal defaults and no direct analytics inserts.
Source-built Nix artifacts are not a published release or proof of the user's installed version.

## Progress


- [x] M1: Internal ingest enrichment survives the queue and writer unchanged.
- [x] M2: Device, bot and channel fixtures pass with documented classification precedence.
- [ ] M3: Acquisition and web metric dimensions use consistent session attribution and filters.
- [x] M4: Optional country lookup trusts only an explicitly configured proxy boundary.

## Surprises & Discoveries


At implementation start, ordinary Servant ingest handlers did not receive a WAI Request and
queue records had no derived fields. AnalyticsEvent remains public; the private QueuedEvent now
carries enrichment independently. A configured header name alone does not establish
trust. The original channel rule classified Facebook paid traffic as paid search before reaching
its paid-social branch.

Implementation evidence (2026-10-15): GHC 9.12.4 and the Nix package build accept released
`mori://maxmind/libmaxminddb` 1.14.1 (tag `4a3d17a621c0ebcb81498fd34d313f67fd940ab5`).
The pinned Nix package was 1.13.3; the release override adds its newly required pkg-config
build tool. Seven native reader/proxy tests pass against owned synthetic MIT-licensed
`mori://maxmind/MaxMind-DB` country data. Missing/corrupt DBs, strict CIDRs, IPv4/IPv6,
spoofed, malformed, duplicate and all-trusted forwarding chains are covered. Full ingest
and observability country acceptance remains open.

M1's actual HTTP→PGMQ→writer→ClickHouse replay fixture passes on the packaged 26.8.2.7
engine: producer-derived-field spoofing is ignored, first Edge/Windows/GB/paid-social values
survive changed retry headers, no request addresses or credential enter the queue, canonical
replay stays unique, and the rich resolver returns those same fields. Migration 0019 applies
and retains the public seven-column projection. The old queue form decodes with explicit
unknown/version-zero enrichment; new acceptance stores the version-one private envelope.
The 142 distinct synthetic user-agent fixtures plus channel/queue/bot tests now pass all
146 examples. They caught an Opera Mini mobile/tablet precedence error; explicit mobile
signatures now precede Android's tablet heuristic. This records synthetic label agreement,
not empirical classification accuracy. Four actual compiler/native acquisition cases pass:
cross-midnight first touch, source-service/account isolation, first resolved-user and anonymous
namespaces, row versus session bot populations, nullable dual grouping and 10000/10001
complete-or-error bounds. See `docs/guides/web-enrichment.md` for the versioned rule table.
Full packaged acceptance and legacy-message regressions are still required before this
whole child is Complete.

## Decision Log


On 2026-10-15 separate the public AnalyticsEvent from a versioned internal queued envelope.
Country enrichment requires trusted peer verification and a maintained MMDB reader; do not
write a new binary database parser as a fallback. Acquisition is session-first attribution.
Reuse the existing request-aware Servant AuthProtect boundary: its ingest result carries only
bounded header user-agent text and a country code into the shared ingest service. The ordinary
handler never receives or fabricates a WAI Request, and public route/client types need no new
request-metadata argument. Producer context remains raw input, while authoritative browser,
OS/device, bot, channel and country columns come from the private envelope. Header user-agent
wins over producer categorical claims; unknown or oversized (>2048 byte) agents are unknown.
An explicit Boolean context.bot=true is ORed with the versioned bot signatures; false cannot
clear a match. Non-web traffic retains unknown browser/OS/device categories.

Dependency lookup found no Mori entries for these native/network readers. The authoritative
Hackage registry and upstream tags agree on `mori://kazu-yamamoto/iproute` 1.7.15 and
nondeprecated `mori://haskell/network-uri`
2.6.4.2 (2.7.0.0 is deprecated). Their sources were read directly before use. Native reader
APIs come from `mori://maxmind/libmaxminddb`, project-relative `doc/libmaxminddb.md`
(artifact-level URI pending), and the binding implements no MMDB decoder.

## Outcomes & Retrospective


M1, M2 and M4 pass native and packaged acceptance. The corrected full native run passes
384 examples, with zero failures or pending required cases; `just check` passes 343 deterministic
core examples, 17 client examples, four probes, generated contracts, OpenAPI lint, strict
validation of all twelve ADRs and every telemetry/lifecycle mode. Private packaged evidence:
`.dev/acceptance/run-20n0yu1x/sanitized` (384 core, 18 live-client examples, four probes,
51 Hurl requests and native recovery/limits/replay/identity proofs).

The packaged public workflow sends ordinary event JSON through the real asynchronous writer,
retries with changed headers, then queries first-touch device/country/session/user results.
It passes in legacy/http/http-dup telemetry modes with neither test request address in complete
logs/spans. Configured missing, corrupt and unsupported databases fail startup clearly; a
separate packaged run verifies geography off and missing country despite spoofed body/header
claims. M3 remains open for the pinned SDK contract checks and final packaging verification.

A source-archive check caught Cabal's rejection of an extensionless fixture glob. Explicit
fixture paths fix it, and `cabal sdist kansoku-core` now includes the binding, both MMDBs,
their license/attribution and the synthetic user-agent corpus. The functional packaged run
above preceded this metadata-only fix; rebuild the final package before whole-child acceptance.

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
