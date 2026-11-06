---
type: Explanation
title: "Web enrichment and acquisition"
description: "Understand preserved web enrichment, first-touch acquisition, versioned device and bot classifications, and trusted optional country lookup."
docId: DOC-12
tags: ["web-analytics", "enrichment", "acquisition", "privacy"]
generated:
  by: process:codex
  at: "2026-11-06T14:31:34Z"
---

# Web enrichment and acquisition

Existing web producers keep sending the public event schema. The server classifies each newly
accepted event and stores the result in its private queue envelope. An equal retry retains the
first accepted browser, device, bot, channel and country values, even if request headers change.
No new producer fields or contract-generation command is required.

Query sessions by their first-touch channel:

```bash
curl --get "$KANSOKU_URL/metrics/acquisition" \
  --header "Authorization: Bearer $KANSOKU_SERVICE_TOKEN" \
  --data-urlencode "from=2026-07-01" \
  --data-urlencode "to=2026-07-03"
```

The defaults are `measure=sessions`, `groupBy=channel`, daily buckets and `includeBots=false`.
`measure=users` counts each selected session's primary canonical subject: its first resolved
user in `(occurred_at,event_id)` order, otherwise its earliest anonymous subject. Empty identity
contributes no user. A subject may occur in more than one channel; channel counts do not add up
to an account-wide unique-user total.

Add `groupBy=channel,browser_family` for a browser breakdown. Common dimensions and repeated
JSON filters follow [query metrics](query-metrics.md). Enrichment/acquisition dimensions are
`browser_family`, `os_family`, `device_class`, `channel`, `country_code`, `is_bot`, `utm_source`,
`utm_medium`, `utm_campaign`, `utm_content`, `utm_term` and `referrer_host`.

Sessions use the full retained `(account_id,source_service,session_id)` key and require a nonempty
session ID on web events. Start time is the earliest observed event. Attribution comes from the
first `page_view`, otherwise the earliest web event, ordered by `(occurred_at,event_id)`.
Dates select the session's start after assembly; filters select whole sessions by their attributed
fields. Later campaign changes, hosts or midnight boundaries do not split or reattribute it.
Missing session IDs and non-web events do not enter acquisition. Late earlier events can change
the observed start/attribution, and deleting retained history can change the remaining session.

Acquisition excludes a session if any of its events is flagged as a bot. Page-view and active-user
routes exclude individual bot rows, including ungrouped daily queries. `includeBots=true` on
these three routes explicitly includes them. Other metric routes keep their documented population
and reject that parameter. Existing raw rollups are bypassed when they cannot preserve the policy.

# Browser and bot classification version 1

Browser rules are ordered: Edge, Opera, Samsung Internet, Android WebView, Chrome, Firefox,
Safari and Internet Explorer, otherwise `unknown`. This ordering handles overlapping signatures
such as Edge/Chrome and iOS browser/Safari. OS rules distinguish Windows Phone, iOS, Android,
Chrome OS, Windows, macOS and Linux; remaining systems are unknown. Device rules prioritize
explicit tablets, mobile signatures and then Android browser tablet/desktop heuristics.
The request `User-Agent` is bounded to 2048 bytes; missing, invalid UTF-8 or larger agents are
unknown. Producer categorical claims do not override derived columns. Non-web events retain
unknown browser, OS and device categories.

These are deterministic approximations, not authentication or fraud detection. The committed
142 distinct synthetic fixtures cover browser/OS overlap, phones/tablets, crawlers and negative
signatures; all match their specified categories. That agreement is not an empirical accuracy
claim for all real-world agents. iPads requesting an indistinguishable desktop agent cannot be
reliably identified from that string alone.

Bot rule version 1 matches explicit signatures for Google/Bing/DuckDuckGo/Baidu/Yandex/Sogou,
Slurp, Exabot, Facebook/Twitter/LinkedIn/Slack/Discord/Apple/Petal previews, Semrush/Ahrefs/MJ12/
DotBot, HeadlessChrome/PhantomJS/Lighthouse, GPTBot/ChatGPT/OAI/Claude/Perplexity/ByteSpider/
CCBot/Amazon/Meta crawlers, UptimeRobot and Pingdom. The exact case-insensitive list is in
`kansoku-core/src/Kansoku/Ingest/UserAgent.hs`. Generic words such as “bot” and “search” alone
do not match. A Boolean `context.bot=true` also flags the event; false cannot clear a server
match, and the string `"true"` is not Boolean true.

Channel/enrichment rule version 2 uses the following precedence. Host comparison is case-insensitive,
removes trailing dots/ports and respects full host or dot-suffix boundaries. Self-referrals
are ignored. Source aliases and known search/social hosts are explicit versioned lists in
`kansoku-core/src/Kansoku/Ingest/Channel.hs`.

| Priority | Signal | Channel |
| --- | --- | --- |
| 1 | Email medium (`email`, `e-mail`, `e_mail`) | `email` |
| 2 | Known social source with a paid medium, or a campaign plus social medium | `paid_social` |
| 3 | Nonempty `gclid`/`msclkid`, or CPC/PPC/search paid medium | `paid_search` |
| 4 | Remaining effective medium | `other_campaign` |
| 5 | Known external AI assistant referrer or exact assistant source | `ai_assistant` |
| 6 | Known external search referrer | `organic_search` |
| 7 | Known external social referrer or nonempty `fbclid` | `organic_social` |
| 8 | Other external referrer | `referral` |
| 9 | Source/campaign present without a matching rule | `other` |
| 10 | No external referrer or campaign/source | `direct` |

For each of source, medium and campaign independently, a nonblank explicit event field wins;
otherwise the first nonblank matching URL query parameter (`utm_source`, `utm_medium`,
`utm_campaign`) supplies the effective value. Keys are case-sensitive; values are percent-decoded,
trimmed and lowercased. Only valid HTTP(S) destination URLs supply fallback tags. Classification
does not fill in or rewrite the event fields. URL-only newsletter/email and assistant/CPC campaigns
therefore retain email and paid-search precedence.

The assistant host list is `chatgpt.com`, `chat.openai.com`, `perplexity.ai`, `claude.ai`,
`gemini.google.com`, `copilot.microsoft.com`, `you.com` and `phind.com`. External referrers
match complete hosts or dot-delimited subdomains. Effective sources match these host tokens
exactly or the exact aliases `chatgpt`, `perplexity`, `claude`, `gemini`, `copilot`, `phind`.
Sources containing URLs, paths, ports, user information or unlisted subdomains do not match.
Generic `ai`, `you`, `google` and `microsoft` aliases are excluded. Parent hosts `google.com`,
`microsoft.com` and `openai.com` are not assistant hosts; Google remains organic search.
Lookalikes such as `notchatgpt.com`, `chatgpt.com.evil.example` and a referrer with
`chatgpt.com@evil.example` cannot match. Same-host referrers alone supply no assistant signal;
an independently matching source can still attribute them. Either an assistant source or an
external assistant referrer suffices after the earlier campaign rules, ahead of organic signals
including `fbclid` alone. Missing or stripped referrers/tags cannot establish assistant attribution.
These lists recognize input signals; they do not guarantee assistants send those signals.

The social source uses the effective UTM source when present, otherwise the external social referrer.
Facebook CPC therefore reaches paid social before generic paid search. `fbclid` alone indicates
social referral rather than paid traffic. A medium/campaign is still a producer claim about
attribution, not evidence of spend.

# Optional country lookup

Country collection is off by default and produces no configuration warning. To enable it, obtain
a licensed MaxMind country/city MMDB and configure both values before normal server startup:

```bash
export KANSOKU_INGEST_GEOIP_DB=/path/to/country.mmdb
export KANSOKU_INGEST_TRUSTED_PROXY_CIDRS=10.0.0.0/8,fd00::/8
```

Use your actual trusted proxy networks. A header name alone does not establish trust. For an
untrusted socket peer, forwarded headers are ignored and the socket address is used. For a
trusted peer, the server parses the entire `X-Forwarded-For` chain and walks right to left past
trusted hops; the first untrusted hop is the client. Missing, duplicate, malformed, all-trusted,
more-than-32-hop or above-4096-byte chains produce missing country. CIDRs explicitly identify
IPv4/IPv6 networks; hostnames, ports and zone identifiers are not accepted as forwarded addresses.

The maintained `mori://maxmind/libmaxminddb` reader is pinned to released 1.14.1 and included in
the Nix shell and server closure. Missing, corrupt or unsupported configured databases fail startup;
point the setting at a readable supported country/city MMDB, or unset both settings to disable it.
The service stores the reader's two-letter country code or missing. It does not copy request
addresses into events, queue messages, logs or spans. Country is an approximation of the request
origin, not a person's citizenship or residence.

New private queue envelopes use queue version 2 and record enrichment version 2, including
non-web events whose channel remains `unknown`. Queue envelope versions 1 and 2 remain readable;
envelope numbering is independent of the stored enrichment rule version. Browser/device/OS and
bot algorithms remain version 1. Bare earlier development events remain readable with
unknown/version-zero categorical values. Accepted version 1 rows retain their original channels:
Gemini stays `organic_search`, ChatGPT referrals stay `referral`, and source-only ChatGPT stays
`other`, even though equivalent new events now classify as `ai_assistant`. Replay never reclassifies
them. Upgrade queue consumers before producers; an older reader rejects enrichment version 2.
Changing a classification rule or database does not rewrite accepted history. Any deliberate
historical correction must rebuild affected derived state from canonical facts under the
administrative maintenance boundary; queue replay preserves its original accepted enrichment.

## Visit-wide event selection

On page views, calendar/rolling users and custom metrics, `session:channel` selects
events by their retained web session's first touch. Existing `channel` selects the
event's own attribution. Thus `session:channel:eq:organic_search` includes subsequent
direct pages in a search visit; `channel:eq:organic_search` includes its search landing.
Use `groupBy=route,session:referrer_host` to report each viewed route by visit referrer.
The equivalent JSON filter is `{"dimension":"session:channel","op":"eq","value":"organic_search"}`.

Allowed suffixes are `channel`, `referrer_host`, `utm_source`, `utm_medium`, `utm_campaign`,
`utm_content`, `utm_term`, `entry_page`, `exit_page`, `device_class`, `browser_family`,
`os_family`, `country_code`, `event_name`, `source`, `source_service`, `host`, `route` and
Boolean `is_bot`. Other values are nullable strings. First page wins, otherwise first event;
entry/exit require pages. Account/service/session keys isolate attachment. Missing or non-web
sessions group under null and fail every session predicate, including `unset` and `neq`;
a real session's missing attribute can satisfy `unset`. OR alternatives apply this rule
independently. Nested session properties/traits/cohorts and other metric routes are excluded.

Session assembly uses all retained history; event dates and rolling activity lookback still
select events. A landing before `from` can attribute later pages although the session route
excludes that start. Page views/users apply their individual-row bot policy, while
`session:is_bot` sees bots anywhere in the retained session. Custom populations retain their
existing policy; session/acquisition routes exclude entire bot-containing visits by default.
Saved custom filters and both ratio populations use the same namespace. Request filters apply
to both ratio sides, with component filters local to their side. Distinct people can appear
in multiple session-channel groups; group counts cannot be summed into a distinct-person total.
See [the event session query contract](query-metrics.md#events-selected-by-session-attributes)
for commands, saved-definition behavior and rolling-user constraints.
