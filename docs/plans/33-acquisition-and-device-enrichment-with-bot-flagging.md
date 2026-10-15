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
---

# Acquisition and device enrichment with bot flagging

This ExecPlan is a living document. Update its living sections and durable ADRs as work
proceeds. It is a child of
`docs/masterplans/5-act-on-rev-1-close-silent-loss-paths-add-metric-filters-and-enrich-web-analytics.md`
and acts on findings E4 (parts 1 to 4), A5 and C2 of
`docs/reviews/2026-10-15-architecture-and-feature-set-against-comparable-products.md`.


## Purpose / Big Picture

A marketing site sending page views to Kansoku will be able to answer where visitors came
from and what they used: `GET /metrics/acquisition` will return sessions or users by channel,
UTM source, medium, campaign and referrer host, and page views, sessions and users will group
by browser, operating system and device class. Crawler traffic will be flagged at ingest and
excluded from those answers by default. Deployments that opt in will record a visitor's
country code without ever storing an IP address. The `context` object the browser SDK already
sends will become queryable.


## Progress

- [ ] M1: Typed `browser_family`, `os_family`, `device_class` and `is_bot` columns are populated at ingest for web-source events, `context_json` is materialized, and the fixtures classify as expected.
- [ ] M2: A `channel` column is derived deterministically from referrer and UTM fields with a documented rule table, backfilled for existing rows.
- [ ] M3: `GET /metrics/acquisition` is implemented and device dimensions are accepted by page-views, sessions and users, excluding bots unless `includeBots=true`.
- [ ] M4: Optional country enrichment resolves the client address to a two-letter code at ingest and stores nothing else, proven with a local database and off by default.


## Surprises & Discoveries

(None yet.)


## Decision Log

- Decision: Parse the user agent server-side at ingest into typed columns rather than at query
  time, and keep the raw string inside `context`.
  Rationale: Grouping and filtering need low-cardinality columns; parsing per query over JSON is
  the cost ADR 4 exists to avoid. PostHog materializes the same way.
  Date: 2026-10-15
- Decision: Bot handling is a flag, not a drop. `is_bot = 1` when the server list matches or the
  SDK sends `context.bot = true`; metrics exclude flagged rows by default.
  Rationale: A dropped event cannot be counted or audited; PostHog and Plausible both keep a
  way to see bot volume.
  Date: 2026-10-15
- Decision: Country enrichment is opt-in, country-only, and resolves the address from a
  configured trusted header; the address is discarded before the event is enqueued.
  Rationale: Kansoku's privacy posture (no IP capture) is a strength REV-1 credits; Plausible
  shows country is achievable without retaining the address.
  Date: 2026-10-15


## Outcomes & Retrospective

(To be filled during and after implementation.)


## Context and Orientation

`analytics.events_raw` (latest shape in `db/clickhouse/migrations/0004_events_raw_v2.sql`
with later additive columns) stores `url`, `referrer` and the five UTM fields as columns and
`context` as a JSON string. The browser SDK (`mori://shinzui/kansoku-ts`,
`packages/kansoku-js/src/context.ts` and `attribution.ts`) fills `context` with
`locale`, `timezone`, `screen`, `viewport`, `userAgent` and `sdk`, and top-level `url`,
`referrer` and UTM fields. Nothing in the server reads `context`. The writer maps
`AnalyticsEvent` to the insert block in `kansoku-core/src/Kansoku/ClickHouse/EventRow.hs`; the
pinned driver cannot carry JSON on the wire, so JSON-typed columns are `MATERIALIZED` from
strings (`properties_json` in `0009_typed_properties.sql`,
[ADR 4](../adr/0004-queryable-event-properties-and-identity-resolved-projection.md)).
Metric dimensions are `event_name`, `source`, `route` (`path(url)`) and `prop:<name>`
(`kansoku-core/src/Kansoku/Metrics/Query.hs`); `/metrics/acquisition` is a contract stub
returning 404 `not_implemented` in `kansoku-api/src/Kansoku/Metrics/Api.hs`. The ingest
handler (`kansoku-core/src/Kansoku/Ingest/Handler.hs`) sees the WAI request, so it can read a
trusted client-address header before the event is enqueued.

"Channel" is the marketing bucket a visit is attributed to (direct, organic search, paid
search, organic social, paid social, email, referral, other), derived from the referrer host
and UTM parameters. "Device class" is desktop, mobile, tablet, bot or unknown. An MMDB file is
the binary database format MaxMind and DB-IP publish for address-to-country lookup.

No cross-repository ADR applies. The SDK-side bot list (REV-1 E4 part 1) is work in
`mori://shinzui/kansoku-ts`; this plan accepts its `context.bot` flag but does not require it.


## Plan of Work

### M1: User-agent parsing and context materialization

Evaluate a Haskell user-agent parser through Mori (`mori registry search ua-parser`) and
Hackage; if a maintained package builds on GHC 9.12, use it. Otherwise implement
`kansoku-core/src/Kansoku/Ingest/UserAgent.hs`: a conservative, ordered pattern table for
browser family (Chrome, Safari, Firefox, Edge, Opera, Samsung Internet, other), operating
system family (Windows, macOS, iOS, Android, Linux, ChromeOS, other), device class, and a bot
list seeded from the patterns posthog-js blocks by default plus the IAB-style generic tokens
(`bot`, `crawler`, `spider`, `headless`, `lighthouse`). Record accuracy against a fixture of
100 real user-agent strings in the plan. Add a migration with four additive columns
(`browser_family`, `os_family`, `device_class` as `LowCardinality(String) DEFAULT ''`,
`is_bot UInt8 DEFAULT 0`) and `context_json JSON MATERIALIZED CAST(context, 'JSON')` with
`max_dynamic_paths` set to 256 and `SKIP userAgent` so the raw string is not indexed as a
dynamic path. Populate the typed columns in the ingest handler for `source = web` from
`context.userAgent`, or from `context.bot` when present, and carry them through `EventRow`.

### M2: Channel classification

Add `channel LowCardinality(String) DEFAULT ''` and compute it at ingest in a pure
`Kansoku.Ingest.Channel` module from referrer host, `utm_medium`, `utm_source` and the
presence of `gclid`, `fbclid`, `msclkid` in the URL, following a rule table placed in
`docs/guides/query-metrics.md`: paid search for click ids or `utm_medium` in `cpc,ppc,paid`;
organic search for known search engine hosts; paid social and organic social for known social
hosts split by medium; email for `utm_medium=email`; referral for any other external host;
direct for no referrer and no UTM. Backfill existing rows with one `ALTER TABLE … UPDATE`
using the same rules expressed in SQL, documented as a one-time mutation in the migration
comment.

### M3: Acquisition route and device dimensions

Implement `/metrics/acquisition` as a standard route whose default measure is distinct
sessions, with `measure=users` optional, `groupBy` one or two of `channel`, `utm_source`,
`utm_medium`, `utm_campaign`, `referrer_host`, and the common `from`, `to`, `timeGrain` and
`filter` parameters. Add `browser`, `os` and `device` as built-in dimensions for page-views,
sessions and users, mapping to the new columns. All these routes add `AND is_bot = 0` unless
`includeBots=true`. Regenerate OpenAPI and the client; document the measures and the bot rule.

### M4: Optional country

Behind `KANSOKU_INGEST_GEOIP_DB` (path to an MMDB country database) and
`KANSOKU_INGEST_CLIENT_IP_HEADER` (default `X-Forwarded-For`, first valid address), resolve the
country code in the ingest handler and set `country_code LowCardinality(String) DEFAULT ''`
on the event before validation; the address itself is never placed in the event, logs or
spans. Evaluate a Haskell MMDB reader via Mori and Hackage. If none builds on GHC 9.12, implement a
minimal MMDB country reader in `Kansoku.Ingest.GeoCountry` (the format is documented and the
country lookup needs only the search tree and one data field); shelling out to an external
binary is not acceptable. Record the choice in the Decision Log.
Add `country` as a dimension on acquisition, page-views, sessions and users.


## Concrete Steps

Inside `nix develop` with the stack running:

```bash
cabal build all --enable-tests
cabal test kansoku-core --test-options='--match "UserAgent"'
cabal test kansoku-core --test-options='--match "Channel"'
just ch-migrate
cabal test kansoku-core --test-options='--match "Acquisition"'
just openapi && just openapi-check
```

Example after `just run`:

```bash
curl -s --get http://localhost:8080/metrics/acquisition -H "Authorization: Bearer $TOKEN" \
  --data-urlencode from=2026-07-01 --data-urlencode to=2026-08-01 --data-urlencode groupBy=channel
```

Expected: HTTP 200 with one point per channel present in the fixtures and no bot sessions.


## Validation and Acceptance

1. M1: the 100-string fixture classifies with recorded accuracy of at least 95 percent on
   family and 100 percent on the bot subset; a `Googlebot` page view stores `is_bot = 1`;
   `SELECT context_json.locale FROM analytics.events_raw` returns the SDK's locale.
2. M2: fixtures with `gclid`, a Google referrer, a Facebook referrer with `utm_medium=paid`,
   `utm_medium=email`, an unknown host, and no referrer classify as paid_search,
   organic_search, paid_social, email, referral and direct respectively; the backfill leaves
   row counts unchanged.
3. M3: acquisition by channel equals a hand-written SQL over the fixtures; `includeBots=true`
   raises the session count by exactly the bot sessions; device dimensions group page views.
4. M4: with a local country database the fixture request resolves to its country; with the
   variable unset the column stays empty; grepping the access log and span attributes for the
   test address finds nothing.
5. OpenAPI conformance tests cover the new route and dimensions.


## Idempotence and Recovery

Migrations are additive columns with defaults. The channel backfill mutation is idempotent
(same rules, same result) and can be re-run. Country enrichment is off unless configured. If
the user-agent classifier misclassifies, the raw string remains in `context` and a corrected
classifier can be re-applied by mutation.


## Interfaces and Dependencies

Soft dependency on `docs/plans/31-metric-property-filters-and-dual-grouping.md` for
`filter=` on the new dimensions; the route works without it. Consumed by
`docs/plans/34-session-analytics-duration-bounce-entry-and-exit-pages.md` (`channel` and
`is_bot` columns). Claims columns `browser_family`, `os_family`, `device_class`, `is_bot`,
`channel`, `country_code` and `context_json`, and configuration `KANSOKU_INGEST_GEOIP_DB`
and `KANSOKU_INGEST_CLIENT_IP_HEADER`. A new ADR should record the enrichment boundary (what
is derived at ingest, the bot flag policy, and the no-address rule).
