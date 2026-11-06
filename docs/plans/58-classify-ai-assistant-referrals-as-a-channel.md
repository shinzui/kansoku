---
id: 58
slug: classify-ai-assistant-referrals-as-a-channel
title: "Classify AI assistant referrals as a channel"
kind: exec-plan
created_at: 2026-11-06T03:42:14Z
intention: "intention_01m6qf4v4kecvs88yevjp67k8x"
provenance:
  created_by:
    model: "gpt-6-astra"
    harness: "codex-cli"
    at: 2026-11-06T03:42:14Z
---

# Classify AI assistant referrals as a channel

This ExecPlan is a living document. Keep Progress, Surprises & Discoveries, Decision Log,
and Outcomes & Retrospective current during implementation. Follow
`agents/skills/exec-plan/PLANS.md`, `agents/skills/exec-plan/ADR.md`, and
`agents/skills/exec-plan/FRICTION.md` for plan maintenance, durable decisions, and implementation
friction. This plan implements [IR-6](../improvement-requests/classify-ai-assistant-referrals-as-a-channel.md).


## Purpose / Big Picture

Site owners will see human visits originating from known AI assistants grouped under
`ai_assistant` in acquisition reports. Today Gemini referrals look like organic search,
most other assistant referrals look like generic referrals, and assistant source tags without
a medium fall through to `other`. Channel rule version 2 will recognize these signals after
the existing explicit email, paid, and campaign-medium rules and before organic search.

Newly accepted events will record enrichment version 2. Already accepted events retain their
stored channel and version through queue decoding, writer retry, and replay. A packaged
acceptance scenario will ingest assistant referrals and a URL-only source tag, then read the
new channel from `/metrics/acquisition`; a native writer scenario will replay an old Gemini
record and still read `organic_search` with version 1.


## Progress

- [ ] Milestone 1: Version 2 classification and queue compatibility pass deterministic cases for assistant signals, precedence, host boundaries, and preserved older enrichment.
- [ ] Milestone 2: Native replay preserves version 1 channels, and packaged HTTP ingestion/reporting exposes new assistant sessions as `ai_assistant`.
- [ ] Milestone 3: The guide and ADR describe the exact versioned contract, and the deterministic and owned acceptance gates pass for the final implementation.


## Surprises & Discoveries

(None yet.)


## Decision Log

2026-11-06: Version the classification result through the existing `Enrichment.ruleVersion`
field and advance `channelRuleVersion` to 2. Keep the queue envelope at version 2, continue
reading envelope versions 1 and 2, and preserve bare legacy events as unknown/version 0.
The queue shape has not changed; the meaning of a newly computed classification has.
Browser, device, OS, and bot algorithms remain version 1. Retaining old classifier code is
unnecessary because replay consumes stored enrichment instead of running classification.

2026-11-06: Adopt an explicit bounded host and source-alias list, specified below, as Kansoku's
version 2 policy. These are recognized input signals, not a claim that every assistant always
sends a referrer or source tag. Unknown or stripped attribution stays subject to the ordinary
rules. Broad domains such as `google.com`, `microsoft.com`, and `openai.com` are not AI hosts.

2026-11-06: Support the request's URL-only source-tag case within classification. For each
of source, medium, and campaign, prefer a nonblank explicit event field, otherwise use the
first nonblank matching URL query parameter. This keeps a URL's `utm_medium=email` or `cpc`
ahead of its assistant source. Do not rewrite accepted event fields or expand producer schemas.
The fallback is part of version 2 and applies consistently to the ordered channel rules;
tests must also cover a non-AI URL campaign so this effect is explicit.


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

Kansoku accepts public `AnalyticsEvent` values, publishes a private JSON queue record in
PostgreSQL, and writes accepted records to ClickHouse for reports. A channel is a categorical
description of how a visit arrived. UTM tags are campaign query parameters such as
`utm_source=chatgpt.com`; the public event also has explicit `utmSource`, `utmMedium`, and
`utmCampaign` fields. A referrer is the previous page URL supplied on the event. An external
referrer has a different canonical host from the destination URL. First-touch acquisition
attributes a retained web session to its first page view, or earliest web event when it has
no page view. Use one distinct, nonempty session ID per classification fixture in reports.

`kansoku-core/src/Kansoku/Ingest/Channel.hs` owns `classifyChannel`, `canonicalHost`,
`referrerHost`, and the currently unused version constant `channelRuleVersion = 1`.
`canonicalHost` accepts HTTP(S) URLs, lowercases their hosts and removes trailing dots;
the URI parser separates user information and ports. `referrerHost` suppresses exact
same-host referrals. `matchesAny` matches a complete hostname or a dot-delimited suffix.
Current precedence is email, paid social, paid search, other campaign, organic search,
organic social, referral, other, direct. Gemini matches the `google.com` search suffix.
Explicit UTM fields are trimmed/lowercased; URL parsing currently checks only click IDs
`gclid`, `msclkid`, and `fbclid`, not UTM parameters.

`kansoku-core/src/Kansoku/Ingest/Enrichment.hs` calculates the categorical fields and
hard-codes new `ruleVersion = 1`. Its JSON decoder accepts only versions 0 and 1 and an
explicit channel list without `ai_assistant`. Both restrictions must change for the writer
to consume new output. Non-web events keep channel `unknown`.
`kansoku-core/src/Kansoku/Ingest/QueuedEvent.hs` emits `queueVersion = 2`, decodes envelope
versions 1 and 2, and treats bare historical events as legacy/version-zero enrichment.
Envelope version 2 also records `traitsEligible`, which is independent of channel rules.

`kansoku-core/src/Kansoku/Ingest/Service.hs` computes enrichment only on new acceptance.
The immutable acceptance ledger prevents an equal retry from publishing another event.
`kansoku-core/src/Kansoku/Writer/Batch.hs` decodes stored queue JSON before writing, and
`kansoku-core/src/Kansoku/ClickHouse/EventRow.hs` copies the stored channel and rule version
into `channel` and `enrichment_version`. These storage columns already admit strings and
an unsigned integer, so this change needs no database migration. The writer must never
call the new classifier to refresh an accepted record.

`kansoku-core/test/Kansoku/Ingest/EnrichmentSpec.hs` contains pure channel and envelope
tests. `kansoku-core/test/Kansoku/Ingest/EnrichmentIntegrationSpec.hs` already exercises
HTTP acceptance, duplicate delivery, queue JSON, the real writer, canonical rows, and the
rich identity-resolved query relation. It currently expects version 1 for freshly accepted
data. `scripts/enrichment_acceptance.py` verifies the packaged HTTP acquisition workflow;
`scripts/acceptance.py` runs it and the native Haskell tests in owned disposable stores.
`scripts/deterministic-tests.py` deliberately excludes native families and rejects pending
or zero-example runs through `scripts/test_support.py`.

[ADR-12](../adr/0012-server-enrichment-and-first-touch-web-acquisition.md) requires server-owned,
versioned enrichment, exact host boundaries, preserved accepted values, and whole-session
first-touch reporting. [ADR-1](../adr/0001-sdk-grade-ingest-contract-boundaries.md) establishes
immutable acceptance and retry behavior. [ADR-4](../adr/0004-queryable-event-properties-and-identity-resolved-projection.md)
requires canonical replay-safe reads and stable public projections. [ADR-10](../adr/0010-owned-executable-acceptance-environments.md)
requires native tests to use fresh owned stores and the packaged acceptance gate rather than
ambient databases. Those decisions constrain this change; update ADR-12's classification
description during implementation. ADRs use the profile in `docs/adr/profile.dhall` and
require timestamp/log maintenance and strict validation.


## Plan of Work

### Milestone 1: Compute and serialize the new classification


Extend `kansoku-core/test/Kansoku/Ingest/EnrichmentSpec.hs` with table-driven page-view
fixtures before changing the classifier. First prove one representative path all the way
through `enrichedQueuedEvent`, JSON encoding/decoding, and `eventRowFromQueuedEvent`:
an external `https://gemini.google.com/` referrer must produce channel `ai_assistant` and
rule version 2. This exposes the existing decoder rejection early rather than completing
classifier-only tests with an unusable queue payload.

In `kansoku-core/src/Kansoku/Ingest/Channel.hs`, add named version-2 host and alias lists.
The host list is `chatgpt.com`, `chat.openai.com`, `perplexity.ai`, `claude.ai`,
`gemini.google.com`, `copilot.microsoft.com`, `you.com`, and `phind.com`. External referrers
use the existing complete-host/dot-suffix matcher. Normalized UTM sources match one of
these host tokens exactly, or an exact alias from `chatgpt`, `perplexity`, `claude`,
`gemini`, `copilot`, and `phind`. Do not add generic aliases such as `ai`, `you`, `google`,
or `microsoft`. Source tokens are not arbitrary URLs; a source containing a path, scheme,
userinfo, port, or a longer lookalike domain does not match this allowlist. Case and
surrounding whitespace follow existing source normalization.

Compute effective UTM inputs using the field/query precedence in the Decision Log.
Parse the destination URL once, reuse the existing query parser for percent-decoding,
and use case-sensitive query keys `utm_source`, `utm_medium`, and `utm_campaign`.
Malformed or non-HTTP(S) destination URLs contribute no fallback tags. Preserve the existing
nonempty click-ID behavior. An explicit nonblank source overrides the URL source, while
each medium/campaign field resolves independently. Do not populate or mutate public event
fields as a side effect. Insert the AI rule immediately after `other_campaign` and before
`organic_search`; either a matching external referrer or an effective AI source is sufficient.
Same-host referrers alone remain suppressed; an explicit campaign source can still attribute
such an event. Preserve all earlier rule order, including paid-social-before-paid-search.

Set `channelRuleVersion = 2` and make new enrichment use that constant instead of a
separate literal. In `kansoku-core/src/Kansoku/Ingest/Enrichment.hs`, accept stored version 2
and `ai_assistant`, while continuing to accept every previously supported version/channel
combination unchanged. Permit `ai_assistant` only with version 2. Unknown future versions
and unknown channel strings must still fail decoding. Browser/device/bot behavior does not
change, and non-web events still receive channel `unknown` under the current enrichment
version. Queue-envelope numbering and trait eligibility remain independent.

Add literal historical fixtures whose recorded channel/version are specified independently
of the current classifier: Gemini `organic_search`/1, ChatGPT `referral`/1, and a ChatGPT
source `other`/1. Exercise them in envelope versions 1 and 2, with the appropriate trait
field, and keep bare-event legacy/version-zero coverage. Assert decode, encode/decode,
and row conversion retain the recorded values. Milestone acceptance is a passing focused
enrichment suite with version-2 roundtrip and all historical/negative cases below.

### Milestone 2: Prove replay and reporting through production paths


Extend `kansoku-core/test/Kansoku/Ingest/EnrichmentIntegrationSpec.hs` with a stored
version-1 queue envelope for a Gemini-referred page view. Give it a distinct event ID,
valid account, session, URL, and page-view properties. Its historical enrichment must be
constructed as version 1 with `organic_search`, not produced by `enrichEvent`. Pass the
JSON payload through `writerBatchHandler` and `insertQueuedEvents` twice, using the
existing message/batch helpers. Query by account and event ID and assert one canonical
event with `organic_search` and `enrichment_version = 1`, also preserved through
`analytics.events_resolved_http`. Include a newly accepted Gemini event to show the same
referrer now writes `ai_assistant`/2. Update the existing paid-social fresh-event expectation
from version 1 to 2 while retaining its retry, country, privacy, and resolved-read assertions.
Filter existing assertions by their intended event IDs or isolate accounts to avoid cross-fixture counts.

Add an isolated population to `scripts/enrichment_acceptance.py`, using a fresh
`sourceService` prefix and separate sessions so current exact-count assertions stay valid.
Send page views with each of the five required external hosts (ChatGPT, Perplexity, Claude,
Gemini, Copilot), one with no referrer or explicit `utmSource` and only
`https://shop.example/entry?utm_source=chatgpt.com`, one ordinary Google referrer, and one
assistant referrer with `utmMedium=cpc`. Set `properties.url` consistently with `url`.
Read `/metrics/acquisition` over the fixture date range, filtered to that source-service
population, with `groupBy=channel`. Expect six `ai_assistant` sessions, one `organic_search`,
and one `paid_search`, independent of response ordering. Re-submit identical events and
verify the channel counts are unchanged. Reuse `send`, `query`, and `eventually`; do not
add sleeps or assertions against an unowned service. The existing acceptance harness
invocation must reach this scenario and print a distinct AI-channel success message.

Milestone acceptance is the owned `just acceptance` gate with nonzero, nonpending native
examples, the preserved historical record, and the stated public report counts.

### Milestone 3: Document and validate the final contract


Update `docs/guides/web-enrichment.md` to distinguish unchanged browser/bot version 1
from channel/enrichment version 2. Insert the AI channel at priority 5, shift subsequent
rows, and document the exact hosts, aliases, URL fallback, explicit-field precedence,
boundary rules, and missing-referrer limitations. Correct its stale queue-version paragraph:
current envelopes are version 2, envelopes 1 and 2 remain readable, and their stored
enrichment versions are independent. Explain that accepted version 1 rows retain their
old channel even when the same inputs would now classify differently.

Update ADR-12 with the new precedence and version relationship, preserving its immutable
history decision. Maintain the ADR timestamp and `docs/adr/log.md` with `okf log add`;
follow `agents/skills/exec-plan/ADR.md` and the existing guide profile/log convention.
Run the final gates below, reusing milestone-2 acceptance evidence if no intervening
runtime/test changes invalidate it. Record outcomes and triage any friction entries before
marking the plan complete. The scope excludes historical reclassification, bot-rule changes,
new dashboard code, and database or public event-schema migrations.


## Concrete Steps

Run commands from the repository root, the directory containing `flake.nix`, `justfile`,
and `cabal.project`. Enter the pinned development environment once:

```bash
nix develop --no-write-lock-file
```

Build the test component through the repository's migration-embedding wrapper, then run
only pure enrichment cases using the existing result auditor. This command intentionally
matches `Kansoku.Ingest.Enrichment`, not the destructive `Kansoku.Enrichment native` family:

```bash
clickhouse-migrate-embed-build --input kansoku-server migrations/clickhouse/manifest.json -- build kansoku-core:test:kansoku-core-test
PYTHONPATH=scripts python3 - <<'PY'
from test_support import binary, hspec
hspec([binary('kansoku-core:test:kansoku-core-test'), '--match=Kansoku.Ingest.Enrichment'])
PY
```

Before implementation the added positive cases must fail on channel/version or decoder
compatibility. Afterwards expect a positive example count, zero failures, and zero pending
cases. Run deterministic regression and the owned packaged acceptance gate at milestones:

```bash
just build-with-tests
just deterministic-test
just acceptance
```

`just acceptance` starts its own databases and packaged server, runs native Haskell cases,
and then exercises HTTP reports. It must finish with `Acceptance passed: required native/live
tests, Hurl, packaged administration/startup and three telemetry modes.` and the added
AI-channel success evidence. Its prerequisites are supplied by the development shell;
missing required integration prerequisites are failures, not permission to count pending tests.

For ADR/guide log commands, inspect the installed CLI usage before updating the entries:

```bash
okf log add --help
```

Finish with the repository gate and explicit documentation checks. `just check` already
includes strict ADR and guide validation, but the targeted commands help localize document
errors before the full gate:

```bash
okf validate docs/adr --strict --profile docs/adr/profile.dhall --profile-enforce --log-enforce
just guides-check
just check
git diff --check
```

Do not run formatting or generators over unrelated uncommitted edits. Record actual
acceptance output and any pre-existing failures in this plan without claiming they passed.
Implementation commits use Conventional Commits and these trailers:

```text
ExecPlan: docs/plans/58-classify-ai-assistant-referrals-as-a-channel.md
Intention: intention_01m6qf4v4kecvs88yevjp67k8x
```


## Validation and Acceptance

IR-6 AC-1 is satisfied when every listed host produces `ai_assistant` through external
referrers and exact UTM source tokens, every listed alias works as a source, and a URL-only
`utm_source=chatgpt.com` page view reaches that same result. Exercise uppercase hosts and
sources, whitespace around sources, referrer ports/trailing dots, and a valid subdomain.
`google.com` and `www.google.com` remain `organic_search`. Test lookalikes such as
`notchatgpt.com`, `chatgpt.com.evil.example`, and
`https://chatgpt.com@evil.example/`; none may become AI referrals. Generic parent domains,
unknown source aliases, malformed referrers, and same-host referrals must not gain an AI
classification without an independently matching source.

Precedence cases must show `email` for an AI referrer plus email medium, `paid_social`
for an explicit Facebook paid source plus AI referrer, `paid_search` for an AI source/referrer
plus CPC or a nonempty `gclid`/`msclkid`, and `other_campaign` for an AI referrer plus an
unrecognized explicit medium. An assistant signal beats organic search/social, including
`fbclid` alone. Test explicit event fields overriding contradictory URL tags, blank fields
falling back, percent-encoded source tokens, duplicate source parameters selecting the first
nonblank value, and URL-only email/CPC campaigns. A URL-only newsletter/email campaign
should classify as `email`; malformed/non-HTTP(S) URL fallback must not invent attribution.
Retain all existing non-AI regression fixtures and non-web `unknown` channel behavior.

IR-6 AC-2 is satisfied when the source lists and version constant are explicit in
`kansoku-core/src/Kansoku/Ingest/Channel.hs` and the validated guide describes the same
version, list, matching semantics, and ordered table. No browser or bot classification
fixture changes its category. New web and non-web enrichment carry version 2, while the
queue decoder roundtrips it and still rejects unsupported versions and channels.

IR-6 AC-3 is satisfied by explicit historical queue fixtures and the native Gemini replay
case: a version-1 `organic_search` record remains version 1 and `organic_search` after two
writer passes, while a newly accepted equivalent event becomes version 2 and `ai_assistant`.
Also preserve old ChatGPT `referral`/1 and source-only `other`/1 in deterministic tests,
and bare-event `unknown`/0 behavior. No old accepted event is passed through new classification.
The public report scenario proves the new category survives the entire producer, queue,
writer, session, and query path rather than merely passing a pure function test.


## Idempotence and Recovery

Pure tests, builds, and documentation validation can be repeated. The packaged acceptance
harness owns fresh PostgreSQL/ClickHouse directories, ports, and processes and retains
private evidence on failure; rerun the harness for a fresh attempt. Do not execute native
test families directly against an ambient database or manually truncate existing stores.

No historical update or migration is needed. Version-1 records may coexist indefinitely
with version-2 records; preserve accepted values on every read/replay path. An older binary
cannot decode enrichment version 2. Deploy upgraded queue consumers before enabling new
producers where these roles are separate; for a combined server, stop old instances before
starting the new release. If a runtime rollback is necessary after version-2 publication,
retain a reader that understands version 2 rather than reverting to the old rejecting
decoder or rewriting queue payloads. Deployment itself is outside this implementation plan.

The initial working tree contains unrelated planning/request edits. Preserve them and
stage only changes belonging to this plan. Use the current branch; do not create a feature
branch or reset unrelated changes.


## Interfaces and Dependencies

This is a standalone plan with no prerequisite ExecPlan or MasterPlan. It changes no
dependency bounds, package pins, public routes, or event fields. Use the repository's
existing URI/query parsing, JSON serialization, queue, and storage implementations. If an
external API needs investigation, locate its source/docs with `mori registry search`,
`mori registry show --full`, and `mori registry docs` before choosing an API. No dependency
upgrade is required to implement the policy.

Keep these interfaces stable in their existing modules:

```haskell
-- kansoku-core/src/Kansoku/Ingest/Channel.hs
classifyChannel :: AnalyticsEvent -> Text
canonicalHost :: Text -> Maybe Text
referrerHost :: AnalyticsEvent -> Maybe Text
channelRuleVersion :: Int -- becomes 2

-- kansoku-core/src/Kansoku/Ingest/Enrichment.hs
enrichEvent :: IngestRequestContext -> AnalyticsEvent -> Enrichment
legacyEnrichment :: Enrichment

-- kansoku-core/src/Kansoku/Ingest/QueuedEvent.hs
enrichedQueuedEvent :: IngestRequestContext -> AnalyticsEvent -> QueuedEvent

-- kansoku-core/src/Kansoku/ClickHouse/EventRow.hs
eventRowFromQueuedEvent :: QueuedEvent -> EventRow
```

`Enrichment.channel` gains the string `ai_assistant`, and `Enrichment.ruleVersion` gains
the accepted value 2. `QueuedEvent` continues to emit envelope version 2. Reports already
group channel strings, so the new category should flow through existing query interfaces;
the packaged report test is the acceptance proof for that assumption.
