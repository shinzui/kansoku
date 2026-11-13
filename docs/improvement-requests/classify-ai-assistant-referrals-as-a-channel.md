---
type: Improvement Request
title: Classify AI assistant referrals as their own channel
description: Add channel rule version 2 with an ai_assistant channel for visits referred by ChatGPT, Perplexity, Claude, Gemini, Copilot and similar assistants, which version 1 splits across organic_search, referral and other.
generated:
  by: process:codex
  at: "2026-11-06T03:57:44Z"
requestId: IR-6
status: completed
completedAt: "2026-11-06T04:50:51Z"
resolution: >-
  AC-1 through AC-3 delivered by plan 58: channel rule version 2 classifies known AI
  assistant referrer hosts and sources as ai_assistant ahead of organic search, with the
  explicit list in Channel.hs and the web-enrichment guide row; stored version 0/1 history
  keeps its channel and version. The focused suite, just check and full owned acceptance
  in three telemetry modes passed (commit 406c882).
targetPlan: docs/plans/58-classify-ai-assistant-referrals-as-a-channel.md
origin: mori://shinzui/kansoku-ui
acceptanceCriteria:
  - id: AC-1
    statement: A new channel rule version classifies a page view whose external referrer or utm_source is a known AI assistant host or alias as ai_assistant, ahead of the organic search rule, while explicit email, paid and campaign-medium rules keep their precedence.
    verification: Fixture tests for chatgpt.com, perplexity.ai, claude.ai, gemini.google.com, copilot.microsoft.com, a utm_source=chatgpt.com URL with no referrer, a google.com search referrer, and a utm_medium=cpc link from an assistant.
  - id: AC-2
    statement: The host and alias list is an explicit, versioned list in Channel.hs, and the web-enrichment guide's channel table documents the new row and version.
    verification: Read kansoku-core/src/Kansoku/Ingest/Channel.hs and docs/guides/web-enrichment.md.
  - id: AC-3
    statement: Accepted history keeps its recorded rule version and channel, as the guide already promises for classification changes.
    verification: An enrichment acceptance check that replays a version 1 queue record and asserts its channel is unchanged.
reviews:
  - kind: model
    reviewer: process:claude-code
    reviewed_at: "2026-11-05T21:06:04Z"
    document_timestamp: "2026-11-05T21:06:04Z"
    scope: content-and-metadata
    outcome: commented
    provider: anthropic
    model: claude-opus-5-5
    effort: unspecified
    context: >-
      Author review against kansoku aaf84df kansoku-core/src/Kansoku/Ingest/Channel.hs and
      docs/guides/web-enrichment.md. The assistant host list is the author's and should be
      checked against current referrer behaviour. No independent verification attestation is
      claimed.
---

# Classify AI assistant referrals as their own channel

**Authored by:** a `claude-code` session in `mori://shinzui/kansoku-ui`, planning a Reports page.
**Addressed to:** `shinzui/kansoku` agents.
**Created:** 2026-11-05.

Part of the set filed with IR-4; that request lists the others.

**Implementation plan:** [ExecPlan 58: Classify AI assistant referrals as a channel](../plans/58-classify-ai-assistant-referrals-as-a-channel.md).
Completed by Plan 58 on 2026-11-06; see `resolution` (status reconciled on 2026-11-13).


## Why

Visitors who arrive from an AI assistant are a growing source that site owners want to see on its
own. Channel rule version 1 (`kansoku-core/src/Kansoku/Ingest/Channel.hs`) has no such channel,
and splits them three ways:

- `gemini.google.com` is a dot-suffix of `google.com` in `searchHosts`, so it becomes
  `organic_search`.
- `chatgpt.com`, `perplexity.ai`, `claude.ai` and `copilot.microsoft.com` referrers become
  `referral`.
- Assistants that strip the referrer but tag links (ChatGPT adds `utm_source=chatgpt.com`) have a
  source and no medium, so they fall through to `other`.

The bot rules already recognise assistant crawlers. This request is about human visitors who
followed a link in an assistant's answer.


## What is asked

Add `ai_assistant` in a new rule version, after the explicit medium rules (1 to 4) and before
organic search. Match on the external referrer host and on `utm_source`, using an explicit list
such as `chatgpt.com`, `chat.openai.com`, `perplexity.ai`, `claude.ai`, `gemini.google.com`,
`copilot.microsoft.com`, `you.com` and `phind.com`. Kansoku owns the final list.


## Not requested

Reclassifying accepted history, or any change to the bot rules.
