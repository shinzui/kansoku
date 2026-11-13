---
type: Reference
title: "Query metrics"
description: "Look up metric populations, query bounds, filters, grouping, analytical semantics, cohorts and saved definitions."
docId: DOC-10
tags: ["metrics", "queries", "identity", "cohorts"]
timestamp: 2026-11-13T02:09:59Z
generated:
  by: process:codex
  at: "2026-11-06T14:31:34Z"
---

# Query metrics

Kansoku exposes account-scoped analytics at `GET /metrics/*`. Every request requires a service
token (`ksk_s_…`) in `Authorization: Bearer` or `X-Api-Key`. A write key can ingest but receives
HTTP 403 on metrics routes.

## Select identified users

Use the filter-only dimension `user_id` with original, case-sensitive opaque IDs:

```text
filter=user_id:eq:alice
filter=user_id:neq:alice
```

```json
{"dimension":"user_id","op":"in","value":["alice","bob"]}
{"dimension":"user_id","op":"eq","value":"123"}
{"dimension":"user_id","op":"eq","value":"user:人|literal"}
```

`eq` and `neq` require one nonempty string. `in` requires 1..20 nonempty strings,
counted before deduplication. The existing 1024 UTF-8 bytes per string, eight AND
filter groups, eight OR alternatives per group and 16384 decoded bytes still apply.
Use JSON strings (or quoted shorthand) for numeric-looking IDs; IDs containing `|`
require JSON. Whitespace, prefixes, punctuation and Unicode are preserved exactly.
`in` selects a combined population; it does not group per user. `groupBy=user_id`
returns `invalid_group_by`. Governed `user:<trait>` dimensions remain separate.

| Supported route | Selection ownership |
| --- | --- |
| events, page-views, revenue, feature-adoption | Resolved event user |
| users | Resolved event user; calendar, rolling7 and rolling30 |
| sessions, acquisition | First resolved user of the complete retained session |
| custom | Resolved event user for every aggregation, saved defaults and ratio components |

All other metric routes, including conversion, organizations, paths, funnel, retention,
lifecycle, stickiness and experiments, reject `user_id` with `invalid_metric`.
Invalid operators, empty/nonstring IDs and lists above twenty also return `invalid_metric`;
malformed filter grammar keeps `invalid_filter`. Existing date, bot, grain, grouping,
organisation aggregation and result-shape rules remain route-specific.

Only identified subjects match, including `neq`. An anonymous subject with the same ID
text is excluded. Each comparison independently fails for missing/anonymous subjects,
so `user_id:eq:alice|event_name:eq:page_view` can still select anonymous page views.
Current account-scoped identity evidence can stitch pre-login events even when the
identification occurs outside the query dates. Identity/cohort changes can reclassify
historical results. An unknown user gives the route's ordinary empty/zero metric,
rather than a profile 404.

Session selection retains all session events, duration, start date and attribution,
even if a later event belongs to another user. Saved simple selection ANDs with request
filters. Common ratio filters select both sides; component filters select their own side.

Selecting one user does not promise a keyed lookup or a scan proportional to that user's
activity. Count, sum, average and percentile may now pay identity-resolution cost, and
sessions can require retained-history assembly. Warm connection snapshots may help;
existing execution/memory deadlines and the 10000-point complete-result cap still apply.

## Whole-range totals

Use `timeGrain=none` to aggregate the entire half-open UTC range into one `bucket: null`
point per populated group. Exact distinct users are resolved across the whole range;
adding daily distinct counts overcounts returning visitors. A person in two groups counts
once in each, so group totals can overlap.

| Route | Whole-range support |
| --- | --- |
| `/metrics/users` | `window=calendar` only; `to` must be a closed UTC day |
| `/metrics/custom` | count, unique_count, sum, average and percentile; ratios require omitted grain |
| `/metrics/acquisition` | sessions, users, converted_users and conversion_rate; default grouping remains channel |
| `/metrics/events` | distinct canonical events |
| `/metrics/page-views` | canonical page views |
| `/metrics/sessions` | count, bounce_rate and average_duration_seconds |

For example, request `/metrics/users?from=2026-07-01&to=2026-08-01&timeGrain=none`,
`/metrics/custom?from=2026-07-01&to=2026-08-01&events=page_view&aggregation=unique_count&timeGrain=none`,
or `/metrics/acquisition?from=2026-07-01&to=2026-08-01&measure=users&timeGrain=none`.
Omitting grain preserves existing route defaults. An explicit request overrides a saved
simple definition in either direction: none overrides day and day overrides none. Saved
JSON `timeGrain: null` (or an absent field) supplies no override; `"none"` is explicit.

Session rates and durations use all selected sessions, rather than averages of daily
results. Empty ungrouped session queries return one null-bucket zero for every measure;
empty grouped sessions and other supported routes return no points. Existing filters,
current traits, cohorts, account isolation and limits apply. Users/page views exclude bot
rows by default, whereas acquisition/sessions exclude any session containing a bot event;
custom keeps its existing event population and does not accept includeBots. Unprefixed
entry_page/exit_page remain specific to sessions/acquisition. Other routes reject explicit none.

## Sessions containing an event

On `/metrics/sessions`, add `containsEvent=client_error` to select whole sessions
with at least one retained web event of that name. A comma-separated list such as
`containsEvent=client_error,page_leave` has any-of semantics: a session matching both
names still contributes once. This applies to count, bounce_rate and
average_duration_seconds; each measure uses the selected whole sessions. Omit the
option to include the existing session population. The `event_name` attribution
dimension still describes the first page view (or earliest event), not all contained names.

The single scalar accepts 1..20 raw names before deduplication. Entries are trimmed;
each must contain 1..128 lowercase ASCII letters, digits, underscore, dot, colon or
hyphen. Empty entries, uppercase, Unicode, SQL punctuation, overlong names and 21 raw
entries (even identical names) return HTTP 400 `invalid_contains_event`. Valid undeclared
or absent names produce an empty selection. A repeated or valueless parameter returns
`invalid_query_parameter`; other routes reject it with `unsupported_query_parameter`.
Authentication is required before these request checks.

Matching uses complete retained web history for the same account, source service and
nonempty session ID. A final error after `to` can select a session that starts in
`[from,to)`; only the session start determines its date and bucket. Non-web events and
events without session IDs cannot witness a match. Session attribution, filters, current
traits/cohorts, grouping and any-bot exclusion still apply after assembly. Arbitrary
`prop:` session filters and grouping remain unsupported.

To report the percentage of visits with errors, make these two authenticated requests
with the same dates, population filters and bot setting:

```text
GET /metrics/sessions?from=2026-07-01&to=2026-07-02&measure=count&timeGrain=none
GET /metrics/sessions?from=2026-07-01&to=2026-07-02&measure=count&timeGrain=none&containsEvent=client_error
```

For three sessions with one error session, the null-bucket values are 3 and 1. Display
`100 * 1 / 3`, approximately 33.33%. When the denominator is zero, display no percentage:
there were no observed sessions. Separate requests are not an atomic snapshot; late
arrivals, erasure or retention can change either result between calls.

The derived Haskell `Metrics.sessions metricsClient` takes an additional `Maybe Text`
argument between measure and includeBots. Source callers must pass `Nothing` to retain
omission behavior or `Just "client_error,page_leave"` to select names.

## Events selected by session attributes

`/metrics/page-views`, `/metrics/users` (calendar, rolling7 and rolling30), and
`/metrics/custom` accept `session:<attribute>` in filters and grouping. Unprefixed
`channel` describes each event; `session:channel` describes its retained web visit.
For an organic-search landing followed by two direct pages,
`filter=channel:eq:organic_search` selects one page view, while
`filter=session:channel:eq:organic_search` selects all three. Combine event and
session dimensions with `groupBy=route,session:referrer_host`; response group keys
retain the full prefix.

The complete allowed suffixes are `channel`, `referrer_host`, `utm_source`,
`utm_medium`, `utm_campaign`, `utm_content`, `utm_term`, `entry_page`, `exit_page`,
`device_class`, `browser_family`, `os_family`, `country_code`, `event_name`, `source`,
`source_service`, `host`, `route`, and `is_bot`. Only `is_bot` is Boolean; all others
are nullable strings. Nested properties, traits, organizations and cohorts are not
session attributes. Other routes reject this namespace.

```bash
curl --get "$KANSOKU_URL/metrics/page-views" \
  --header "Authorization: Bearer $KANSOKU_SERVICE_TOKEN" \
  --data-urlencode 'from=2026-07-01' --data-urlencode 'to=2026-07-02' \
  --data-urlencode 'filter=session:channel:eq:organic_search' \
  --data-urlencode 'groupBy=route,session:referrer_host'
```

The equivalent JSON filter is:

```json
{"dimension":"session:channel","op":"eq","value":"organic_search"}
```

A session contains all retained web events with the same account, source service and
nonempty session ID. Its first page view supplies attribution; absent page views, its
first event does. Ties use event ID after timestamp. `session:route` comes from that
attribution event, while entry/exit pages require actual page views. Later campaign,
device or country changes do not replace the first touch. Events can inherit a later
first page even when that page is outside the event query interval.

Event dates, properties and identities retain their existing meaning. A session landing
before `from` still supplies attributes to later in-range events, unlike `/metrics/sessions`
and acquisition, which select the session start date. Rolling users retain their activity
lookback and closed-day/day-grain rules, while session attribution uses whole retained
history. Page views/users still exclude individual bot rows by default; `includeBots=true`
restores them. `session:is_bot` reflects any bot in the retained session, including one
outside the query dates. Custom metrics retain their existing bot population. Whole-session
routes retain whole-session bot exclusion.

Events without an eligible web session group under null and cannot satisfy any session
filter, including `unset`, `neq` or `in`. A real session with missing country can satisfy
`session:country_code:unset`. Comparisons, including `neq`, do not match a missing attribute.
The presence rule applies to each OR alternative: `session:channel:eq:organic_search|source:eq:service`
can select a service event through its ordinary source alternative. Repeated filters remain
AND conditions; all ordinary operator types and query/result bounds remain in force.

Saved simple custom definitions can supply session filters and default grouping; request
grouping overrides the default and request filters are conjoined. Both saved ratio components
can independently filter session attributes, even without a common filter or session group.
For example, count payments in organic-search sessions in the numerator and referral sessions
in the denominator; common request filters apply to both. Ratios remain unbucketed and reject
property grouping. Numeric aggregates, including exact percentiles for simple metrics, retain
their declared-property rules. Users still count event-resolved people or the requested
organizations. A person may appear in several session-channel groups, so summing grouped
distinct-user counts does not produce a whole-range distinct-user total.

## Common query contract

Every implemented metric route requires `from` and `to` dates in `YYYY-MM-DD` format. Ranges are half-open in
UTC: `from` is inclusive and `to` is exclusive. For example, use `from=2026-07-01&to=2026-08-01`
for July.

The public limits are fixed:

| Input or answer | Limit |
| --- | --- |
| Date range | Positive, at most 366 days |
| Paths | 1..10 transitions; top 1..20 per step; window 1..7776000 seconds |
| Funnels | 1..20 non-empty steps; repeated names retain their meaning |
| Acquisition conversion events | 1..20 supplied names, validated before deduplication |
| Retention offsets | At most 32 distinct values in 1..365, normalized to ascending unique order |
| Complete metric answer | At most 10,000 points |
| AND-combined filters | At most 8 JSON objects |
| `in` operands | 1..100 values of one scalar type |
| Filter strings | At most 1024 UTF-8 bytes each |
| Decoded filter JSON combined | At most 16 KiB, including whitespace |

Retention always includes the implicit offset-zero cohort point; do not send zero as
an offset. Default offsets remain 1, 7, 14 and 30. A funnel's existing maximum window
is still 90 days within the bounded query interval.

All bounds fail with HTTP 400, `application/problem+json`, and `retryable: false`.
Stable codes are `invalid_date_range`, `query_range_too_large`,
`invalid_path_options`, `invalid_conversion_events`, `too_many_funnel_steps`, `invalid_retention_days`, `too_many_retention_days`, and
`metric_result_too_large`. A result overflow returns no partial metric payload:

```json
{
  "type": "about:blank",
  "title": "Bad Request",
  "status": 400,
  "detail": "narrow the query range or grouping to at most 10000 metric points",
  "code": "metric_result_too_large",
  "retryable": false
}
```

Narrow the interval or grouping after a permanent limit error. The service caps the
final aggregate projection, after grouping, ratios, identity resolution and funnel
computation. It never limits the raw event input to fabricate an in-bound answer.
The row cap bounds result transfer and Haskell collection. Separate positive configuration
limits bound execution (30 seconds by default) and native query memory (512 MiB by default).
The request deadline includes pool wait, native settings, identity preparation and SELECT.
Each native statement/subquery also receives the execution/memory settings; cold identity
construction uses the smaller of its existing 256 MiB cap and the configured query memory.
Timeout or native memory-limit failures return permanent 400 `query_resource_limit`, without
partial data, after the failed physical handle is disposed. External cancellation propagates.
Other storage failures remain retryable 503.

Metric aggregates return complete-or-error answers rather than cursor pages: pages
recomputed over an evolving event set can disagree. This is a deliberate service
exception to the collection pagination standard, documented in
[ADR-9](../adr/0009-bounded-complete-aggregate-responses.md). Future resource-list APIs
still follow `mori://shinzui/haskell-jitsurei/docs/api-relay-pagination`.

Standard event/user/revenue routes accept `timeGrain` (`hour`, `day`, `week`, `month`),
`groupBy` and repeatable `filter`. The default grain is day; ordered signup conversion rejects timeGrain and returns one
ratio over the whole interval. `groupBy` contains one or two distinct comma-separated names:
`event_name`, `source`, `source_service`, `host`, `route`, enrichment/acquisition dimensions
from [web enrichment](web-enrichment.md), `prop:<name>`, or current `user:<name>` traits.

Property dimensions require a compatible scalar declaration across the selected registered
events and their schema versions. Missing declarations in older versions are missing values;
incompatible declarations, PTAny, arrays and objects do not establish a scalar dimension.
For `/metrics/events`, an `event_name` `eq`/`in` filter establishes the finite scope required
for property validation. An unrestricted all-event request cannot filter/group by a property.
Ratio requests reject event-property grouping; their population filters apply to both sides.

Each `filter` is a URL-encoded JSON object with exactly `dimension`, `op` and `value`.
`set`/`unset` omit `value`. Unknown keys, null operands and mixed/empty `in` arrays are invalid.

| Operator | Operand and behavior |
| --- | --- |
| `eq`, `neq` | A scalar of the dimension's declared string, number or Boolean type. |
| `in` | A nonempty array of one compatible scalar type. |
| `contains` | Case-sensitive string substring, including an empty substring. |
| `gt`, `lt` | A finite number and a declared numeric dimension. |
| `set`, `unset` | Presence or absence; no operand. |

Missing and JSON-null properties are unset. Historical values of an incompatible type also
become unset through guarded extraction. Every comparison, including `neq`, is false for
unset values. An empty property string is present; absent built-in strings normalize to null.
All operand values are native parameters. Strings retain their text, Booleans render as
`true`/`false`, and numbers use native Float64 text. Numeric groups sort numerically; missing
groups sort first. Full group keys such as `source` and `prop:source` remain distinct.

Unknown/unsupported parameters return 400 `unsupported_query_parameter`. Only `filter` and funnel `exclude` may
repeat; duplicate scalar parameters or missing values return `invalid_query_parameter`.
Invalid JSON/filter grammar or incompatible filter types return `invalid_filter`.

| Route | Parameters in addition to required `from`, `to` |
| --- | --- |
| events, feature-adoption, revenue | `groupBy`, `timeGrain`, repeatable `filter` |
| page-views | `groupBy`, `timeGrain`, repeatable `filter`, `includeBots` (default false) |
| acquisition | `groupBy` (default channel), `timeGrain`, repeatable session-attribute `filter`, `measure` (sessions/users/converted_users/conversion_rate), `conversionEvents` (required only for conversion measures), `includeBots` (default false) |
| sessions | `groupBy`, `timeGrain`, repeatable session-attribute `filter`, `measure` (count/bounce_rate/average_duration_seconds), `containsEvent` (optional 1..20 any-of event names), `includeBots` (default false) |
| conversion | `groupBy` (no prop), repeatable `filter`; timeGrain rejected |
| paths | optional `start` or `end`, `by`, `steps`, `top`, `window`, CSV `events`, CSV `exclude`, repeatable `filter`; event mode requires an anchor |
| funnel | required `steps`; optional `window`, `mode`, `counting`, `attribution`, `measure`, repeatable `exclude`, `groupBy`, repeatable `filter` |
| users | `groupBy`, `timeGrain`, repeatable `filter`, `window` (calendar/rolling7/rolling30), `includeBots` |
| stickiness, lifecycle | `groupBy`, `timeGrain` (day only), repeatable `filter`, `includeBots` |
| retention | `groupBy`, `timeGrain` (day only), repeatable `filter`, `days`, `mode` (on/on_or_after), `cohort` (window/lifetime), `includeBots` |
| experiments | `experiment`, `timeGrain` (day/week/month), `measure` (exposures/diagnostics), user-trait-only `groupBy` and repeatable `filter` |
| experiments/conversion | required `experiment`, `event`; user-trait-only `groupBy` and repeatable `filter` |
| experiments/funnel | required `experiment`, `steps`; optional `window`, `mode`, `counting`, `attribution`, `measure`, repeatable `exclude`, `groupBy`, repeatable `filter` |

Session/cohort/funnel filters follow their dedicated population contracts; strict funnels reject
event filters so that interruptions remain visible.
`source_service` and URL `host` separate applications/properties within one account. They do
not establish cross-origin browser identity: that also needs the SDK cookie/handoff contract.

All successful routes return:

```json
{
  "metric": "events",
  "points": [
    {
      "bucket": "2026-07-20",
      "group": {"source": "web"},
      "value": 42
    }
  ]
}
```

`bucket` is null for an unbucketed result. Group values are nullable strings: null, empty
string and literal `other` are distinct. `group` is always an object
and carries dimensions, funnel steps, retention cohorts, or experiment variants. A valid query
with no matching data normally returns HTTP 200 with an empty `points` array. Ungrouped
conversion returns a single zero when its denominator is zero.

## Implemented endpoints

| Endpoint | Current meaning |
| --- | --- |
| `/metrics/events` | Distinct event IDs across all event names. |
| `/metrics/page-views` | Distinct canonical `page_view` event IDs with the same filters and default row-level bot exclusion at every grain. |
| `/metrics/acquisition` | Complete retained web sessions, first-touch attribution and exact primary-subject users; defaults to sessions grouped by channel, excluding any-bot sessions. |
| `/metrics/sessions` | Whole retained web sessions, assigned to their earliest event bucket; count, bounce rate and observed duration, excluding any-bot sessions by default. |
| `/metrics/paths` | Exact canonical-user event paths or page flows, forward or backward. |
| `/metrics/funnel` | Exact identity-resolved users or nonoverlapping attempts, with ordered or any-order reach and timing. |
| `/metrics/retention` | Exact closed-day on/on-or-after retention for window or retained-history lifetime cohorts, omitting immature offsets. |
| `/metrics/feature-adoption` | Exact identity-resolved users emitting `feature_used`, grouped by its `feature` property by default. |
| `/metrics/conversion` | Ordered signup completers among starters within the bounded default window; 0 for empty denominator, always 0..1. |
| `/metrics/users` | Exact calendar or rolling7/rolling30 active subjects, excluding profile-only and default bot rows. |
| `/metrics/stickiness` | Exact daily active, rolling30 active and their ratio as separate numeric measures. |
| `/metrics/lifecycle` | Nonnegative new/returning/resurrecting/dormant counts based on retained matching activity. |
| `/metrics/revenue` | Sum of numeric `amount` on `payment_completed` events. |
| `/metrics/experiments` | Approximate raw identities exposed per experiment/variant, or exact contamination and exclusive first-observed assignment diagnostics. |
| `/metrics/experiments/conversion` | Exact identity-resolved exposed and post-exposure converted users per variant, plus rate. |
| `/metrics/experiments/funnel` | Exact post-exposure funnel reach/timing per variant, including any-order, attempt totals and property attribution. |

`/metrics/custom` computes ad-hoc or saved definitions as described below.
`/metrics/organizations` counts exact organisations per bucket; see Organisations below.

## Standard metric example

Group page views by normalized URL route and week:

```bash
curl --fail-with-body --get http://localhost:8080/metrics/page-views \
  --header "Authorization: Bearer $KANSOKU_SERVICE_TOKEN" \
  --data-urlencode 'from=2026-07-01' \
  --data-urlencode 'to=2026-08-01' \
  --data-urlencode 'timeGrain=week' \
  --data-urlencode 'groupBy=route' | jq .
```

Group revenue by the declared optional `plan` property:

```bash
curl --fail-with-body --get http://localhost:8080/metrics/revenue \
  --header "Authorization: Bearer $KANSOKU_SERVICE_TOKEN" \
  --data-urlencode 'from=2026-07-01' \
  --data-urlencode 'to=2026-08-01' \
  --data-urlencode 'groupBy=prop:plan' \
  --data-urlencode 'timeGrain=month' | jq .
```

Filter revenue and group by both a deployment dimension and the declared plan:

```bash
curl --fail-with-body --get http://localhost:8080/metrics/revenue \
  --header "Authorization: Bearer $KANSOKU_SERVICE_TOKEN" \
  --data-urlencode 'from=2026-07-01' \
  --data-urlencode 'to=2026-08-01' \
  --data-urlencode 'groupBy=source_service,prop:plan' \
  --data-urlencode 'filter={"dimension":"prop:amount","op":"gt","value":0}' \
  --data-urlencode 'filter={"dimension":"prop:plan","op":"in","value":["pro","enterprise"]}' | jq .
```

## Paths

`GET /metrics/paths` returns the most common transitions after an event or before an
end event. Each canonical user contributes one sequence, ordered by stored millisecond
`occurred_at`, then immutable `event_id`; replayed events are counted once. `start`
selects the first matching occurrence. `end` selects the last occurrence and walks
backwards, so step 1 goes from the end event to its immediate predecessor. They are
mutually exclusive. A missing anchor returns no points.

```bash
curl --fail-with-body --get http://localhost:8080/metrics/paths \
  -H "Authorization: Bearer $TOKEN" \
  --data-urlencode from=2026-07-01 --data-urlencode to=2026-08-01 \
  --data-urlencode start=signup_completed --data-urlencode steps=4 \
  --data-urlencode top=5 --data-urlencode exclude=page_view,page_leave
```

Use `end=payment_completed` instead of `start` for reverse paths. `steps` counts
transitions away from the anchor, defaults to 5, and accepts 1..10. `window` is an
inclusive elapsed-time bound in seconds from the anchor, defaults to the query
range capped at 90 days, and accepts 1..7776000. Both directions stay inside the
half-open date range. Exhaustion within that observed range/window emits one final
transition to `(end)` if there is a remaining step; this means no further observed
event, not proof that the user permanently left. Reverse paths use the same marker
when no earlier observed event remains. Reaching the step limit does not emit it.

`by=route` considers only nonbot `page_view` rows with nonempty `path(url)`. Anchors
are paths beginning with `/` (at most 1024 UTF-8 bytes); query strings and fragments
are not part of the path. Consecutive identical paths collapse after selecting the
anchor and time window. Omit both anchors for entry mode: each user's first selected
page view begins the sequence. This is a per-user flow over the requested interval,
not a per-session flow.

```bash
curl --fail-with-body --get http://localhost:8080/metrics/paths \
  -H "Authorization: Bearer $TOKEN" \
  --data-urlencode from=2026-07-01 --data-urlencode to=2026-08-01 \
  --data-urlencode by=route --data-urlencode start=/pricing \
  --data-urlencode steps=3 --data-urlencode top=5
```

`by=event` is the default and requires `start` or `end`. `events` is an optional
comma-separated allowlist of event names; `exclude` is a comma-separated denylist.
Each accepts at most 100 names using the existing event-name grammar; blank names
are invalid and exclusions win. Repeated names in a sequence remain separate steps
in event mode. Repeated `filter` parameters use the normal bounded JSON grammar.
All selection runs before anchoring, so a filter can remove the anchor or an
intervening event. Property filters require a finite registered event scope from
`events`, a positive event-name filter, or route mode's `page_view` scope.
`groupBy`, `timeGrain` and `includeBots` are unsupported here.

Points have `bucket: null`, `group: {"step":"1","from":"signup_completed",
"to":"onboarding_started"}` and `value` equal to unique users. `top` defaults to
10 and accepts 1..20. For each step, rank transitions by users descending, then
source and target names ascending. Keep K transitions and sum the rest into one
`from="(other)", to="(other)"` point: its source represents combined origins, not a
real edge from a retained node. Because each user has one transition per step,
this sum is still a unique-user count within that step. Synthetic `(end)` and
`(other)` names cannot collide with valid event names or `/`-prefixed route anchors.
Final ordering is numeric step ascending, value descending, then source and target
names ascending, including the folded point. At most `steps * (top + 1)` points
are possible (210 at public maxima); the shared 10000-point guard still applies.

Invalid controls return permanent HTTP 400 `invalid_path_options`; malformed parsed
values use the shared `malformed_request` problem. Date, filter, authentication,
resource-limit and storage problems keep their normal codes. Haskell clients can
use `pathsClient` or `Metrics.paths metricsClient`, both derived from the served API.

## Ordered funnels

Supply a non-empty comma-separated `steps` list. By default, a user counted at step N
performed steps 1 through N in order. Any-order and totals controls are described below. `window` is seconds from the first step to the last counted step and must be
between 1 and 7,776,000 (90 days). When omitted, it is the requested date-range duration capped
at 90 days.

```bash
curl --fail-with-body --get http://localhost:8080/metrics/funnel \
  --header "Authorization: Bearer $KANSOKU_SERVICE_TOKEN" \
  --data-urlencode 'from=2026-07-01' \
  --data-urlencode 'to=2026-08-01' \
  --data-urlencode 'steps=signup_started,signup_completed' \
  --data-urlencode 'window=86400' | jq .
```

Funnel points put `step` and one-based `index` values in `group`. Equal event timestamps may
satisfy the ordering rule.

## Closed-day users, stickiness and lifecycle

Users, stickiness, retention and lifecycle observe complete UTC days: the exclusive `to` must
be no later than the current UTC date. A later value returns permanent HTTP 400
`unclosed_observation_window`. Query through today's date to include yesterday; a partially
observed day is not a mature zero. The ordinary date, filter, work and point limits still apply.

Users defaults to `window=calendar` and supports hour/day/week/month and explicit none grains. `rolling7`
and `rolling30` require day grain (default): day d counts exact distinct subjects active in
`[d-(N-1) days,d+1 day)`. Only requested output days are returned. Three different users active
on days 1,3,9 yield rolling7=2 on days 7 and 9. `/metrics/stickiness` emits separate points with
`group.measure=daily_active`, `rolling30_active`, and `ratio`; the ratio is daily/rolling30 on
0..1, or zero for an empty denominator. Counts remain numeric `value` fields.

`/metrics/lifecycle` emits nonnegative `group.status` values per closed day: new is first
retained matching activity that day; returning is active today and yesterday; resurrecting is
active today after an inactive yesterday with earlier retained activity; dormant is active
yesterday and inactive today. New+returning+resurrecting equals exact daily actives. Profile
updates (`identify`, `identify_once`, `alias`, `group`) do not count as activity anywhere in
lookback. Bot rows are excluded unless `includeBots=true`. Filters and one/two group dimensions
apply identically throughout lookback; each group defines its own matching population. Missing
group values remain null. Ungrouped rolling/daily series fill zero days; nonexistent dimension
groups are omitted. Retention/erasure can move first retained activity; it is not first ever.

```bash
curl --get "$KANSOKU_URL/metrics/users" \
  --header "Authorization: Bearer $KANSOKU_SERVICE_TOKEN" \
  --data-urlencode 'from=2026-07-01' --data-urlencode 'to=2026-07-10' \
  --data-urlencode 'window=rolling7' --data-urlencode 'timeGrain=day'
```

## Retention

`days` defaults to `1,7,14,30`, with at most 32 distinct positive offsets in 1..365. Offset 0
always gives cohort size. `cohort=window` (default) means first matching activity inside the
observed range; a previously active subject can appear as new again. `cohort=lifetime` means
first matching activity over retained account history, with identical historical filters and
current identity/trait population; subjects whose first retained activity predates `from` are
excluded. There is no permanent first-seen store or first-ever claim after history expires.

`mode=on` (default) counts activity on exactly cohort+N, emitting an offset only when that entire
UTC day has closed by `to`. `mode=on_or_after` counts any activity from cohort+N through the
largest requested offset, including intermediate days not requested. For example, with offsets
1,7 a day-5-only return counts for cumulative offset 1 and not 7. Cumulative nonzero offsets
are omitted unless the whole maximum horizon is closed. Offset 0 is always present. A mature
missing return is zero; an immature result is absent. Day grain only.

```bash
curl --get "$KANSOKU_URL/metrics/retention" \
  --header "Authorization: Bearer $KANSOKU_SERVICE_TOKEN" \
  --data-urlencode 'from=2026-07-01' --data-urlencode 'to=2026-08-01' \
  --data-urlencode 'days=1,7,14' --data-urlencode 'mode=on_or_after' \
  --data-urlencode 'cohort=lifetime'
```

Each point puts `cohort` and `offset` beside any requested dimensions in `group`; `bucket` is
null and `value` is an exact subject count. Lifetime/lifecycle scans can read all retained
matching history. The default 30-second/512-MiB query budgets and identity snapshot footprint
limits apply; resource exhaustion returns 400 `query_resource_limit` with no partial result.
Narrowing the output range does not itself bound lifetime lookback work.

## Experiments

Emit `experiment_viewed` when a user actually sees a variant, not when the variant is merely
assigned. Version 1 requires lowercase-safe `experiment` and `variant` properties matching
`[a-z0-9_.:-]{1,128}`.

Exposure counts are fast, approximate `uniqCombined` counts over raw `userId`, falling back to
`anonymousId`. They may count the same person before and after identification. The optional
`experiment` filters one experiment. `timeGrain` may be `day`, `week`, or `month`; `hour` is
rejected because the rollup is daily.

```bash
curl --fail-with-body --get http://localhost:8080/metrics/experiments \
  --header "Authorization: Bearer $KANSOKU_SERVICE_TOKEN" \
  --data-urlencode 'from=2026-07-01' \
  --data-urlencode 'to=2026-08-01' \
  --data-urlencode 'experiment=checkout_copy' \
  --data-urlencode 'timeGrain=week' | jq .
```

Conversion counts query exact, current identity resolution. A conversion counts only at or after
that user's first exposure to the variant. A user exposed to multiple variants counts in each.
The endpoint returns `exposed`, `converted`, and `conversion_rate` as separate points in each variant's
`group`; it does not calculate statistical significance.

```bash
curl --fail-with-body --get http://localhost:8080/metrics/experiments/conversion \
  --header "Authorization: Bearer $KANSOKU_SERVICE_TOKEN" \
  --data-urlencode 'experiment=checkout_copy' \
  --data-urlencode 'event=payment_completed' \
  --data-urlencode 'from=2026-07-01' \
  --data-urlencode 'to=2026-08-01' | jq .
```

The experiment funnel applies the selected mode and window only to events at or after each user's
first exposure:

```bash
curl --fail-with-body --get http://localhost:8080/metrics/experiments/funnel \
  --header "Authorization: Bearer $KANSOKU_SERVICE_TOKEN" \
  --data-urlencode 'experiment=checkout_copy' \
  --data-urlencode 'steps=checkout_started,payment_completed' \
  --data-urlencode 'from=2026-07-01' \
  --data-urlencode 'to=2026-08-01' \
  --data-urlencode 'window=86400' | jq .
```

## Accuracy and freshness

Ingestion is asynchronous. A successful HTTP 202 means the durable PostgreSQL queue accepted the
event, not that ClickHouse queries already include it. Allow at least one writer flush interval
or observe the queue and writer metrics before reading fresh data.

HTTP user counts use exact current identity resolution, with the same activity population
for filtered and unfiltered requests. Raw internal DAU/WAU and experiment-exposure
rollups use `uniqCombined` (about 0.8% relative error at scale and exact for small sets). Exposure
rollups use raw identity, while experiment conversion and funnels use exact stitched identity;
do not treat their denominators as interchangeable without acknowledging that difference.

For the complete parameter and response schema, use the
[generated OpenAPI document](../api/openapi.json) or `GET /openapi.json`.

[Documentation index](../README.md)

## Session measures

`/metrics/sessions` defaults to `measure=count`, daily UTC buckets and no grouping. A session
key combines account, source service and a nonempty producer session ID. It spans all retained
web events, across insert batches, midnight and hosts. The server assembles the session before
applying its start date or attributes. A session starting before `from` is excluded even if
later events fall inside the requested range. Missing IDs and non-web events do not join.

`measure=bounce_rate` returns a fraction from zero to one: exactly one distinct page_view and
no engagement events, divided by every selected session. session_start, page_leave, identify,
identify_once, alias, group, experiment_viewed, client_error and web_vital are not engagement;
other application events such as purchase are. The diagnostic exclusions depend only on exact
event name, for all versions including versionless rows. Zero-page sessions count but are not bounces. A page_view followed by page_leave can be
a bounce with positive duration. `measure=average_duration_seconds` averages last minus first
observed timestamp, including page_leave, client_error, web_vital and one-event sessions with zero duration. It measures
elapsed observed duration, not active reading time. Empty ungrouped buckets return zero for
all measures; nonexistent groups are omitted. One page at time 0 plus diagnostics at 10 and 20
seconds has bounce rate 1 and duration 20 seconds; purchase at 30 seconds changes these to 0
and 30 seconds. Apply migration `0026_diagnostic_session_engagement` and the matching application
binary together inside the [maintenance window](clickhouse-migrations.md#diagnostic-session-engagement-upgrade).
The migration corrects all retained aggregates; unupgraded aggregates retain the old classification.

Use `groupBy=entry_page,exit_page` for the first/last page_view route; lifecycle events cannot
supply these routes. Other common/enrichment dimensions use first-page attribution, otherwise
the earliest web event, with `(occurred_at,event_id)` tie ordering. Repeated attribute filters
select whole sessions; arbitrary `prop:` filters/grouping are rejected on this route. Any bot
event excludes the session unless `includeBots=true`. Session counts and acquisition's sessions
measure agree under equivalent filters/grouping. Example:

```bash
curl --get "$KANSOKU_URL/metrics/sessions" \
  --header "Authorization: Bearer $KANSOKU_SERVICE_TOKEN" \
  --data-urlencode 'from=2026-07-01' --data-urlencode 'to=2026-07-03' \
  --data-urlencode 'measure=bounce_rate' --data-urlencode 'groupBy=entry_page,channel'
```

Replay does not double-count page views or engagement. Late arrivals can move a session to an
earlier start bucket or extend duration. These are retained-history sessions: expiry, erasure
or corrected historical facts can change their minimum and attribution after a fenced rebuild.
The server does not invent IDs or apply a second inactivity timeout; browser SDK rotation
controls browser sessions. Identical IDs in different source services remain separate.


## Deterministic funnels and conversion

Both `/metrics/funnel` and `/metrics/experiments/funnel` accept `mode=sequential|strict|any_order`,
`measure=count|time_to_convert`, repeatable `exclude`, one/two `groupBy` dimensions and repeated
JSON `filter`. Defaults are sequential/count/no exclusions. Timelines use canonical users,
immutable event deduplication and `(occurred_at milliseconds,event_id)` ordering. One event
cannot satisfy two repeated steps. Sequential skips intervening events; strict requires
adjacent events, including automatic events, without an implicit repeated-event rule. Strict current-user filters select participants while retaining their complete timelines. Strict
event filters return 400 because removing rows could hide interruptions.

For sequential/strict `counting=uniques` (the default), every matching start is considered. Select greatest reach, earliest completion, earliest
start, then event IDs. The inclusive window measures milliseconds from that start; public
`window` remains seconds, defaulting to range length capped at 90 days. An excluded event
between matched steps stops further reach; a later start may still qualify. Up to 20 distinct
validated exclusions are allowed, with no step/exclusion overlap. Sequential filters select
step rows; exclusions always remain visible. Experiment chains use only events at or after
that user's first exposure for the variant within the range. Multi-variant users remain in
each variant.

Counts emit cumulative reach by `group.index` and `group.step`. Timing emits reached steps
2 onward with `group.measure=p50_seconds|p90_seconds`. These are exact nearest-rank quantiles:
sort selected-chain elapsed milliseconds/1000, select rank ceil(p*N). No reached chains means
no timing rows. Group attributes belong to the earliest eligible first-step event, even if
a later attempt wins. Property attribution is described below; missing property values use `other`.
Typed dimensions, numeric steps and measure names determine final ordering. Large timelines
fail the shared resource limit instead of being truncated.

`mode=any_order` opens one inclusive window at the earliest event matching any step.
Reach is the number of distinct step positions matched before completion, expiry or an
exclusion. For `steps=a,b`, `b,a` reaches 2, while sequential reaches 1. Repeated names
require separate immutable events. Intermediate `index` values are reach ranks; `step`
retains the requested label at that index. Timing measures elapsed time to each reach rank.
Uniques does not search later windows in any-order mode.

`counting=totals` counts nonoverlapping attempts instead of users. Each attempt opens at
step one in sequential/strict mode, or any matching step in any-order mode. Completion
consumes the final event; expiry, an exclusion, or a strict interruption closes the current
attempt while preserving its reached prefix. The closing event can start the next attempt
if it is eligible. There is no two-second exclusion grace period. Repeating a completed
`a,b` twice yields 2 at both ranks, versus 1 under uniques. Each attempt owns its start
group and its timing values. Count rows have `group.measure=count`; totals also emits an
unbucketed `group.measure=entries` point with null step/index and null breakdown dimensions,
per variant for experiment funnels. This counts all attempts, including partial ones,
even when `measure=time_to_convert`. An empty ordinary population emits entries=0.

For `groupBy=prop:<name>`, `attribution=first_touch|last_touch|step:<n>` selects the
property at the earliest eligible start, at the last matched event of the selected chain,
or at the matched event for the requested step position (1-based, within `steps`). Totals
applies this per attempt. In any-order, first touch is the earliest matching event and
`step:n` names the requested position even when that event occurs first chronologically.
Missing, null and unreached values use `other`, including a user who never reaches the
attribution step. A property set only at step three therefore groups under its value for
`step:3` and under `other` for first touch. For ordered modes the first-touch schema is checked first, with
other step declarations used when that property is absent there; any-order first touch and last touch require
compatible scalar declarations wherever declared among the steps. `step:n` validates its
own step schema. Undeclared properties and incompatible declarations remain errors.
Other grouping dimensions continue to use the start event; `attribution` does not change
their ownership. These controls apply identically after experiment exposure gating.

`/metrics/conversion` now means ordered signup conversion: denominator = canonical users with
signup_started; numerator = those starters with a valid subsequent signup_completed within
the range and default window capped at 90 days. Completion-only and completion-before-start
users do not convert. Empty denominator yields zero; the ratio stays in [0,1]. Group ownership
is the earliest eligible start. timeGrain and prop grouping return explicit 400 errors.

## Exposure diagnostics

`/metrics/experiments?measure=diagnostics` returns `metric=experiment_diagnostics` and uses exact resolved users; default `measure=exposures`
retains the approximate raw-identity sketch. Select an optional experiment and whole-range,
day, week or month scope. For each experiment/bucket, assign each user once to their earliest
valid exposure ordered by millisecond time then event ID. Missing/invalid variant names do
not enter the diagnostic population. `group.measure` contains exposed_users, multiple_exposure
(users seeing >1 variant), and per-variant assigned_users and variant_share. Re-exposures do
not increase assignment counts; all observed variants remain visible, including zero assignments.
Shares sum to one for nonempty buckets. Empty buckets emit zero totals and no variant rows;
without an experiment selection or observations, the experiment label is null.

A user seeing A then B has exposed_users=1, multiple_exposure=1, assigned A=1, B=0, shares 1/0.
Existing experiment conversion still counts that user in both observed variants. First observed
exposure is not an authoritative randomization log. High contamination invalidates a naive
sample-ratio interpretation; these diagnostics do not calculate significance or select winners.


## Organisations

`GET /metrics/organizations` counts distinct nonempty organisation IDs on matching events,
with day buckets by default. It supports `timeGrain`, one/two dimensions and bounded repeated
filters. Use `filter=organization:eq:workspace_123` to inspect one organisation, or
`groupBy=organization,source_service`. Identity-only `group` events count on this route;
`/metrics/users?aggregate=organizations` counts activity and excludes identity/profile events.

Users, funnel, retention, conversion and feature-adoption accept `aggregate=users|organizations`,
defaulting to users. Organisations merge their members' event streams: one member may start a
funnel and another finish it. Sequential/strict order and exclusions still apply. A retention
cohort is the organisation's first matching activity in the selected window (or retained history
with `cohort=lifetime`); any member can retain it. Feature adoption counts organisations using
the feature; conversion keeps the existing ordered signup denominator and ratio semantics.
Organisation aggregation excludes events without an organisation and bypasses user rollups.
Experiments, sessions, acquisition, paths, stickiness and lifecycle keep their existing user or
session aggregation and reject `aggregate`. All queries retain account isolation, execution and
memory limits, and the complete-or-error 10,000-point cap.

Emit `group` with explicit `schemaVersion: 2`, a nonempty top-level `organizationId`, and optional
`plan`, `industry`, `country` strings or finite nonnegative integral `seats`. Omitted properties
remain unchanged; null is rejected. Version 1 remains context-only. Haskell `group` and
`groupEvent` helpers select version 2; explicit version APIs can still send v1. Other producers
must select version 2 explicitly to write traits. For each account/organisation/key the latest
(occurredAt milliseconds, first accepted receivedAt milliseconds, eventId) wins. Duplicate
immutable events cannot change the winner. Use `org:plan`, `org:industry`, `org:country`,
`org:seats` for typed filters and grouping on ordinary event-based metrics, including revenue
(experiment exposure/conversion selection keeps its existing user/cohort-only contract):

```bash
curl --fail-with-body --get http://localhost:8080/metrics/revenue \
  -H "Authorization: Bearer $TOKEN" \
  --data-urlencode from=2026-07-01 --data-urlencode to=2026-08-01 \
  --data-urlencode groupBy=org:plan
```

`attribution=event` is the default on organisation aggregation. With
`attribution=user_organization`, an event lacking an organisation inherits its resolved user's
current organisation, taken from the latest `group` event with a nonempty explicit userId and
organisationId. Existing event organisation IDs always win. Unresolved anonymous identities,
including an anonymous ID with the same text as a user ID, never inherit membership. Membership
is account scoped; a pre-login event stitched to a user can inherit it. User aggregation rejects
`user_organization`; `/metrics/organizations` always aggregates organisations and rejects
`aggregate=users`.

Current traits and membership intentionally reclassify historical metrics; these are not
event-time snapshots. A later group/move may change historical results. No implicit ungroup or
membership deletion event is defined. The ordinary funnel's existing `attribution=first_touch`,
`last_touch` and `step:<n>` values remain property attribution with event organisation IDs.
Its `event` and `user_organization` values use first-touch property attribution. Experiment
funnels retain only their original property attribution values. Organisation dimensions are
unsupported on whole-session/acquisition sources. Business traits are analytics observations,
never authorization facts. See the [erasure runbook](../runbooks/identity-data-deletion.md).


## Current person traits

Emit `identify` with explicit `schemaVersion: 2` to set current traits, or `identify_once` with
explicit version 1 to initialize them. Both require a nonempty top-level userId. Supported
optional strings are plan, signup_source, initial_plan, country and role; company_size is a
finite nonnegative integer. Null is rejected, not treated as deletion. Omitted keys are
unchanged; unknown extra properties do not become traits. Identify v1 remains valid identity
telemetry without governed trait effects. The public catalog is version 4 and publishes the
numeric minimum/multipleOf constraints.

For each account/user/key, the latest set wins, ordered by stored millisecond occurredAt,
first accepted receivedAt and eventId. If any set exists, it overrides set-once; otherwise the
earliest set-once wins. Replay is idempotent. Late events can revise order. Current traits
intentionally reclassify historical metrics; these are not event-time trait snapshots.

Use repeatable typed filters such as `{"dimension":"user:company_size","op":"gt","value":2}`
and `groupBy=user:plan,user:company_size`. Strings compare as decoded text and numeric values
use Float64 comparison and ordering. Missing traits are null, including unresolved anonymous
subjects. An anonymous ID with the same text as a user's ID does not inherit that user's
traits. Pre-login events that conservative identity resolution stitches to the user do inherit
current traits. Repeated references share one bounded pivot per resolved source.

| Metric population | Current-trait ownership |
| --- | --- |
| Events, page views, users, revenue, feature adoption | Each event's resolved user; trait selection forces resolved reads when needed. |
| Signup conversion | Same starter/ordered-completer population and first-start ownership. |
| Funnels, including experiment funnels | Participant's current traits; strict user filters retain all interruptions. |
| Rolling users, stickiness, retention, lifecycle | Identical current-trait population across the full lookback. |
| Sessions and acquisition | First resolved user of the entire retained session, before trait/date selection; all session events remain included. |
| Experiment exposures/conversion/diagnostics | Current user selection only; selected exposures use exact resolved users, while unselected default exposures retain the raw-identity sketch. |
| Custom | Event, property, cohort and current-user selection under the definition scope. |
| Organizations | Unimplemented stub. |

```json
{
  "eventId": "profile-update-1",
  "eventName": "identify",
  "schemaVersion": 2,
  "source": "service",
  "userId": "user-42",
  "occurredAt": "2026-07-01T12:00:00Z",
  "receivedAt": "2026-07-01T12:00:00Z",
  "properties": {"plan": "pro", "company_size": 10},
  "context": {}
}
```

Trait reports accepted with public write keys are analytics observations. Do not use role,
plan or other reported business attributes for authorization. Use service-owned producers for
trusted business reporting. Current-trait session selection uses complete retained identity
scope and may cost more than the materialized session fast path; the shared query budgets and
complete-result cap still apply. Fenced deletion/rebuild primitives reserve erased source IDs;
administrative queue/archive/acceptance cleanup is coordinated by the maintenance executable.

## External consumers and analytical units

[Consume ClickHouse](consume-clickhouse.md) defines the trusted SQL reader and verified
Grafana/GrowthBook recipes. Revenue is a Float64 analytical sum in one producer-normalized
account currency/unit; it does not convert currencies, account for refunds/net revenue or
provide an exact monetary ledger. Feature adoption is a distinct-user count, not a percentage
without a defined eligible denominator.

## Cohorts

A saved cohort names a set of identified users in the service token's account. Create,
read, update and delete definitions at `/cohorts` and `/cohorts/{id}`. The response has
`id`, `definition`, `createdAt` and `updatedAt`; IDs are UUIDs. Names are unique within
an account. Updating a definition preserves its kind. Write keys cannot manage cohorts.
Missing IDs, including IDs owned by another account, return `cohort_not_found` (404).
Invalid definitions return `invalid_cohort` (400).

A behavioural definition has one to four event conditions, optional current trait filters,
and a name. A trait-only definition may omit event conditions. All conditions and filters
are ANDed. Each condition has exactly one of `did` or `didNot`, an event name,
`withinDays` in 1..365, optional `atLeast` and `atMost` nonnegative occurrence counts,
and optional `filters` in the existing JSON metric-filter grammar. Without occurrence
bounds the minimum is one; an upper bound alone includes zero occurrences. `didNot`
negates the complete occurrence test. Duplicate event IDs count once. Event names need not
be registered, but event property filters must be declared for that event. `traits` accepts
only governed `user:` filters. Event-condition filters also support governed `org:`
traits, including numeric `org:seats` and OR alternatives. They use current retained
trait values joined by account and each resolved event's stamped organization ID.
Missing traits do not satisfy comparisons; `set` and `unset` test their presence.
These conditions select identified users. An outer metric's organization aggregation
or `user_organization` attribution does not change the cohort's event attribution.
Nested cohort references are unsupported.

```json
{
  "name": "power_users",
  "kind": "behavioural",
  "conditions": [
    {"did": "feature_used", "atLeast": 3, "withinDays": 30,
     "filters": [{"dimension": "prop:feature", "op": "eq", "value": "export"}]},
    {"didNot": "subscription_cancelled", "withinDays": 90}
  ],
  "traits": [{"dimension": "user:plan", "op": "eq", "value": "pro"}]
}
```

Membership is evaluated at query time, after identity resolution, over each condition's
`[to - withinDays, to)` UTC window. The metric's `from` bound does not truncate that
lookback. Current traits and identity evidence may change historical answers. Anonymous
activity can contribute after it resolves to an identified user; an anonymous-only subject
belongs to the `out` group. Sequences, first-ever occurrence, and stopped-doing criteria
are deferred. Definitions are stored in PostgreSQL; member facts are queried in ClickHouse.

Use `{"dimension":"cohort","op":"eq","value":"<uuid>"}` to include members and
`neq` to exclude them. Only these two cohort operators are supported. The shorthand
`cohort:eq:<uuid>` and `cohort:neq:<uuid>` is also accepted. `groupBy=cohort:<uuid>`
labels groups `in` and `out`; it can be combined with another dimension under the existing
two-dimension limit. Cohort selection forces identity-aware queries, including whole
session attribution for sessions/acquisition. Strict funnels accept cohort selection;
experiment routes accept cohort and governed user selection. Query date, point, memory,
and execution-time limits continue to apply.

For example, retention of power users uses the saved ID returned by the create response:

```bash
curl -sS --get "$BASE/metrics/retention" -H "Authorization: Bearer $TOKEN" \
  --data-urlencode from=2026-07-01 --data-urlencode to=2026-08-01 \
  --data-urlencode "filter=cohort:eq:$COHORT_ID"
```

For a Q3 beta list, create a static definition and upload explicit, unprefixed user IDs.
`PUT` replaces the entire list; sending an empty list clears it. At most 50,000 nonempty
IDs of at most 1024 characters are accepted, subject to the server's request-body limit.
Duplicates are removed. Repeated uploads are safe. Replacements are serialized per
cohort across server processes and use a single versioned ClickHouse insert.

```bash
curl -sS "$BASE/cohorts" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' -d '{"name":"q3_beta","kind":"static"}'
curl -sS -X PUT "$BASE/cohorts/$BETA_ID/members" -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' -d '{"userIds":["alice","bob"]}'
curl -sS --get "$BASE/metrics/revenue" -H "Authorization: Bearer $TOKEN" \
  --data-urlencode from=2026-07-01 --data-urlencode to=2026-10-01 \
  --data-urlencode "filter=cohort:eq:$BETA_ID"
```

Page views split by churn risk use the same ID syntax for grouping:

```bash
curl -sS --get "$BASE/metrics/page-views" -H "Authorization: Bearer $TOKEN" \
  --data-urlencode from=2026-07-01 --data-urlencode to=2026-08-01 \
  --data-urlencode "groupBy=cohort:$CHURN_RISK_ID"
```

`GET /cohorts` and `GET /cohorts/{id}/members?from=2026-07-01&to=2026-08-01`
return Relay connections with `edges` (`node`, opaque `cursor`) and `pageInfo`.
Use `first`/`after` or `last`/`before`, with default size 20 and maximum 100. Definition
pages order by UUID; member pages order by user ID in ClickHouse. Return cursors unchanged;
a cursor for another ordering returns `invalid_cursor`. Pagination faults use the Relay
JSON error shape (`code`, `message`, `retryable`, `parameter`). Other failures use problem
JSON. Behavioural member lists include identified users observed in `[from,to)` who satisfy
the definition anchored on `to`; static lists return all present uploaded IDs, independent
of event history. `GET /cohorts/{id}/size` takes the same `from` and `to` parameters and
returns `{"size":123}` for that population. Concurrent edits can change a page walk;
there is no cross-request snapshot. User erasure removes static member facts as well.

The Haskell `cohortsClient` in `Kansoku.Client.Metrics` is derived from the served route
record. It uses `kansokuMetricsCredential`, the cohort DTOs in `Kansoku.Cohort.Types`, and
Relay `ClientPage` arguments. Deleting a cohort makes subsequent metric references fail
with `cohort_not_found`, including future saved metric definitions that reference it.

## OR filters

Separate `filter` parameters are joined with AND. Alternatives inside one parameter
are joined with OR. Use full terms, for example
`filter=prop:plan:eq:pro|prop:plan:eq:enterprise`, then another filter such as
`filter=source:eq:web` to select either plan on web events. Prefixes such as `prop:`
and `user:` belong to the dimension. `set`/`unset` omit the last colon and operand.
Shorthand operands parse JSON numbers/Booleans; JSON string quotes preserve numeric-looking
text. `in` uses a JSON scalar array as its operand. A literal `|` in a shorthand value
is ambiguous and rejected; the existing JSON form preserves arbitrary text.

Typed clients can encode an OR group as
`{"or":[{"dimension":"source","op":"eq","value":"web"},{"dimension":"source","op":"eq","value":"app"}]}`.
Nested groups are rejected. There are at most eight terms per group, eight repeated groups,
100 values per `in`, 1024 UTF-8 bytes per string and 16384 decoded bytes across the request.
All terms are type checked and parameterized. A mixed OR group does not establish an event
scope: only a group consisting entirely of positive event-name eq/in terms narrows scope.

## Custom metrics

`GET /metrics/custom` requires `from`, `to`, `events` (1..100 comma-separated validated
names) and `aggregation`: `count`, `unique_count`, `sum`, `average`, `percentile` or `ratio`.
Sum/average/percentile require `property`, declared numeric across every listed event/version.
Count deduplicates event IDs; unique count uses resolved identities across all listed
events. Event names need not be registered, but property dimensions require declarations.
The standard filters, up to two group dimensions and time grains apply; day is the default.

```bash
curl --get "$BASE_URL/metrics/custom" -H "Authorization: Bearer $TOKEN" \
  --data-urlencode from=2026-07-01 --data-urlencode to=2026-08-01 \
  --data-urlencode events=payment_completed --data-urlencode aggregation=sum \
  --data-urlencode property=amount --data-urlencode groupBy=prop:plan \
  --data-urlencode 'filter=prop:plan:eq:pro|prop:plan:eq:enterprise'
```

For ratios, supply `denominatorEvents` and optionally `denominatorAggregation` (default
`unique_count`). `aggregation=ratio` selects a unique-count numerator; supplying another
aggregation with `denominatorEvents` selects that numerator aggregation. A shared `property`
applies to whichever component uses sum/average. Ratios are unbucketed; omit `timeGrain`.
Event-property grouping is unsupported for ratios. A zero denominator returns zero.
Invalid definitions and unsupported aggregation combinations return 400 `invalid_metric`.
Filters retain `invalid_filter`; date, cardinality and resource bounds retain their standard
codes. No custom definition contains SQL, and every query uses the authenticated account.

### Percentiles and sample counts

Use `aggregation=percentile&property=amount&quantile=0.75` for p75; p50 and p95 use
0.5 and 0.95. Quantile is required, finite, and strictly between zero and one, with
no default. Other aggregations and either ratio component reject quantile/percentile.
Malformed numeric URL text returns a decoding error; invalid numeric bounds return
400 `invalid_metric`.

Percentile uses exact inclusive interpolation (R-7), with normal Float64 rounding and
no approximate estimator. Sort n eligible samples and interpolate between adjacent
values at zero-based position `(n-1)*quantile`. Samples 10, 20, 30, 40 have p50=25,
p75=32.5 and p95=38.5. A singleton returns itself. Zero, negative and repeated values
are eligible. Only finite numeric values with compatible numeric declarations across
the selected events participate; missing, null, incompatible historical types and
non-finite values are excluded. Replay cannot add samples. Filters, account isolation,
current traits and cohorts apply before aggregation. Each group and time bucket is
computed from its own underlying samples; combining daily percentiles does not produce
a weekly percentile. Empty buckets/groups emit no points, including an entirely empty
`points` array; there is no synthetic zero percentile.

Pair a percentile with a separate `count` request using identical events, dates,
filters, grouping and grain. Add an explicit `filter=prop:amount:set` to **both**
requests so the count measures the eligible numeric samples. Omit `property` and
`quantile` from the count request. For example:

```bash
curl --get "$BASE_URL/metrics/custom" -H "Authorization: Bearer $TOKEN" \
  --data-urlencode from=2026-07-01 --data-urlencode to=2026-08-01 \
  --data-urlencode events=payment_completed --data-urlencode aggregation=percentile \
  --data-urlencode property=amount --data-urlencode quantile=0.75 \
  --data-urlencode groupBy=prop:plan --data-urlencode timeGrain=day \
  --data-urlencode 'filter=prop:amount:set'
curl --get "$BASE_URL/metrics/custom" -H "Authorization: Bearer $TOKEN" \
  --data-urlencode from=2026-07-01 --data-urlencode to=2026-08-01 \
  --data-urlencode events=payment_completed --data-urlencode aggregation=count \
  --data-urlencode groupBy=prop:plan --data-urlencode timeGrain=day \
  --data-urlencode 'filter=prop:amount:set'
```

Match the returned bucket/group keys. A group with no eligible values is absent from
both results. These separate requests are non-atomic: new events or changed identities,
traits or cohort membership between reads can change the population. This recipe does
not provide a transactional snapshot. Exact percentile retains samples in memory;
existing memory, execution and complete-result limits apply. Resource exhaustion returns
the existing query error, never an approximate result or silently truncated population.

### Saved definitions

Save a simple definition with `POST /metric-definitions`:

```json
{
  "name": "paid_revenue",
  "description": "Revenue from paid plans",
  "eventNames": ["payment_completed"],
  "aggregation": "sum",
  "aggregationProperty": "amount",
  "filters": ["prop:plan:eq:pro|prop:plan:eq:enterprise"],
  "groupBy": ["prop:plan"],
  "timeGrain": "day"
}
```

To save p75, use the same simple shape with `"aggregation":"percentile"`,
`"aggregationProperty":"amount"`, `"quantile":0.75`, and `"filters":["prop:amount:set"]`.
POST, GET and PUT preserve quantile. Older definitions without quantile remain valid;
saved execution takes its quantile from the definition. `metric=payment_p75&quantile=0.95`
is rejected; replace the definition with PUT to change its quantile.

A ratio body has `name`, optional `description`, and `numerator`/`denominator` containing
simple definitions of the same shape (each with empty groupBy and null timeGrain).
Component filters select only that side; request filters select both sides. The name has
1..200 characters and is unique within an account. Names are labels and cannot change
builtin dispatch. Both simple and ratio definitions are validated on write and execution.

The response wraps `id`, `definition`, `createdAt`, and `updatedAt`. Read, replace and delete
by UUID using GET/PUT/DELETE `/metric-definitions/{id}`; a duplicate name returns
400 `invalid_metric`. List with GET `/metric-definitions?first=20&after=<cursor>` or
`last`/`before`. Lists use UUID keysets in canonical order, default 20 and maximum 100;
`edges` and `pageInfo` follow the same Relay contract as cohorts. Lists are current reads.
Missing or foreign IDs/names return 404 `metric_not_found`.

Run `GET /metrics/custom?metric=paid_revenue&from=2026-07-01&to=2026-08-01`.
Request `groupBy`/`timeGrain` override simple saved defaults. Request filters are conjoined
with saved filters, and the combined population remains subject to the eight-group cap.
Do not combine `metric` with ad-hoc definition parameters. Saved cohort references are
resolved in the current account at execution time; deleting a cohort makes its references
fail with `cohort_not_found`. Trait and cohort selection uses resolved event paths even
for event counts, sums, averages and percentiles. The typed client exposes `Metrics.custom metricsClient` and
`metricDefinitionsClient` from `Kansoku.Client.Metrics`.


## Acquisition conversions

Use `/metrics/acquisition` to attribute converting people to their first selected web
session in the requested range. Omitted `measure` still means `sessions`; omitted `groupBy`
still means `channel`; omitted `timeGrain` still means daily UTC buckets.

| Measure | `conversionEvents` | Value |
| --- | --- | --- |
| `sessions` | Must be absent | Selected complete sessions |
| `users` | Must be absent | Distinct primary resolved subjects in each bucket/group |
| `converted_users` | Required | Selected people with at least one eligible conversion |
| `conversion_rate` | Required | Converted people divided by the selected first-session population in the same bucket/group |

`conversionEvents` is one comma-separated scalar parameter with 1..20 raw entries. Entries
are trimmed, then must contain 1..128 ASCII lowercase letters, digits, underscore, dot,
colon or hyphen. Empty entries (including leading/trailing commas) are invalid. Duplicate
names have OR semantics and normalize only after the raw count limit; matching repeated
conversions still counts a person once. Well-formed unregistered names are valid and may
match no facts. Invalid combinations or lists return HTTP 400 `invalid_conversion_events`;
repeated or valueless parameters return `invalid_query_parameter`.

For example:

```http
GET /metrics/acquisition?from=2026-07-01&to=2026-07-03&measure=converted_users&conversionEvents=signup_completed,payment_completed
Authorization: Bearer ksk_s_…
```

Suppose two people first arrive through organic search on July 1, one through email, and
one organic visitor and the email visitor later convert. The organic visitor first visits
anonymously, aliases to a known user, converts from a backend service on July 2, and returns
through email. The response is:

```json
{"metric":"acquisition","points":[
  {"bucket":"2026-07-01","group":{"channel":"email"},"value":1},
  {"bucket":"2026-07-01","group":{"channel":"organic_search"},"value":1}
]}
```

Changing `measure` to `conversion_rate` produces email=1 and organic_search=0.5 in those
same buckets. `timeGrain=none` computes those whole-range rates directly with null buckets.

Selection first assembles each complete retained web session by account, source service
and nonempty session ID. The start must lie in `[from,to)`. Session attributes come from
its first page view, falling back to its first event. Apply session filters, current traits,
cohort selection and any-bot exclusion before choosing one session per nonempty canonical
subject across the entire range. Equal starts choose the lower `(source_service,session_id)`
tuple. Only then group and bucket by that session's start. Narrowing a filter may select a
later session. First touch means first selected session in this range, not lifetime first visit.

Conversion facts use the same current identity resolution over retained account history.
Later alias evidence may therefore join an anonymous session to a known user; ambiguity,
erasure and retention follow the shared identity policy. A conversion may originate from any
supported source or service and needs no session ID. Session channel, service, page, property,
trait and cohort filters select the acquisition population; they do not filter conversion
event attributes. Occurrence must be in `[from,to)` and at or after the selected session start.
Equality at session start counts; an earlier conversion or one at exclusive `to` does not.
A conversion on a later day belongs to the selected session's earlier bucket.

By default, any bot event in the complete retained session excludes that session, even
outside the request dates. Individually bot-marked conversion events are excluded too.
`includeBots=true` restores both. Empty session subjects never enter the denominator.
Existing populated groups with no matching conversion return zero; absent groups have no points.

Legacy `users` may count the same person in several session channels or buckets. Its output
is therefore not generally the denominator of the new rate. Each person has exactly one
assignment within a fixed conversion query, so converted-user counts can be summed across
its buckets/groups. Separate date-window queries select their own first sessions and may
overlap. Rates must not be summed or averaged across buckets; use `timeGrain=none` for an
exact whole-range rate. All measures retain the 10,000-point complete-or-error bound and
native resource limits; no sessions or conversions are truncated before final grouping.


## Identified users, profiles and history

All `/users` reads require a metrics-read service token. Identity and traits are analytical
inference, never authentication or authorization. The principal supplies the account.

`GET /users` returns a Relay connection of identified subjects, including users with only
identity/profile events. Optional paired `from`/`to` select users with activity in the UTC
half-open range `[from,to)` spanning 1..366 days. First/last activity always cover all retained
history. Activity excludes identify, identify_once, alias and group; `includeBots=false` is
the default. Without dates, users with no qualifying activity remain with null extrema.
`search` is a literal case-insensitive user-ID substring of 1..256 Unicode code points;
percent and underscore have no wildcard meaning. `order=lastActivity` (default) or
`firstActivity` sorts the chosen timestamp descending, null last, then userId ascending.
Traits are current governed scalar values; missing names are omitted.

Repeat `filter` for AND: at most eight `user:` trait terms and one `cohort` eq/neq UUID term.
Use the existing typed eq/neq/in/contains/gt/lt/set/unset grammar. OR and other dimensions
are rejected. Cohort behavioural windows anchor to explicit `to` or one captured next UTC
midnight; missing/foreign definitions return `cohort_not_found`. Filters share the 16384-byte
decoded budget. Examples:

```bash
curl -H "Authorization: Bearer $KANSOKU_SERVICE_TOKEN" \
  "$KANSOKU_URL/users?first=20&search=alice&order=lastActivity"
curl -H "Authorization: Bearer $KANSOKU_SERVICE_TOKEN" \
  "$KANSOKU_URL/users/activity-counts?from=2026-07-01&to=2026-07-03"
```

`GET /users/activity-counts` requires paired dates and accepts only `includeBots` in addition.
It returns JSON integer `identified` and `anonymous` exact distinct activity counts. Their
sum equals the ungrouped `/metrics/users?timeGrain=none` result with identical dates/bots;
adding daily distinct counts is incorrect. Empty subjects are excluded.

`GET /users/{userId}` treats the captured ID literally, including colons. It returns current
traits as `{value,observedAt,operation}` with `set` or `set_once` provenance, default nonbot
activity extrema, all-kind/all-bot `retainedEventCount`, five evidence counts, original
`resolvedAnonymousCount`, and nullable `{organizationId,traits}` current explicit membership.
A set always wins over set-once; latest set/earliest set-once uses occurrence milliseconds,
receipt milliseconds and event ID. Legacy ineligible writes do not establish provenance.
Evidence keys cookie/device/fingerprint/email_hmac/email_sha256 include zeros and count
distinct bindings, including conflicted evidence; they never include identifier values.
Fingerprint validity expires 180 days after occurrence even before physical TTL cleanup.
Resolved anonymous counts include only original anonymous events currently stitched to this
user. Profile queries share a connection and overall deadline, with eventual cross-table
consistency rather than an atomic snapshot.

`GET /users/{userId}/events` returns resolved history including identity/profile events and
stitched pre-login events. Optional paired dates and `includeBots` have the same bounds and
default; at most one `filter` selects event_name by eq or in, with 1..100 raw names of
1..128 characters from `[a-z0-9_.:-]`, bounded before deduplication. Unknown valid names return
empty pages. Nodes expose eventId, eventName, occurredAt, source, sourceService, sessionId,
nullable host/path, isPageView and properties. Host/path use existing enrichment expressions;
page-view status describes canonical page_view facts. Ordering is occurrence, receipt and
event ID descending. Properties contain only present typed declared scalars at the exact
stored schema version. Unknown versions, PTAny, nulls, incompatible/nonfinite values,
arrays/objects, identifier properties, alias payloads and context are omitted. Identity and
group event properties additionally require their governed trait catalogs.

Both collections accept `first`/`after` or `last`/`before`, default 20, minimum 1, maximum 100.
Cursors carry complete keys, including directory null markers, and reject incompatible
orders. Keep all selection parameters unchanged while walking. These are current reads,
without a cross-request snapshot: arrivals, identity/trait changes and retention can move
rows; refresh and deduplicate after concurrent changes. Newer arrivals are visible on
refresh, not through a continuation below a saved history key.

Unknown, foreign-account and erased users return indistinguishable `user_not_found` 404s.
Retention changes extrema, counts, evidence and traits; no retained resolved facts means no
user. Administrative `erase-user --delete-events` removes explicit facts; default identity
unlinking retains explicit facts and can retain the profile. Erased source-ID replay cannot
resurrect deleted facts. Unknown/repeated scalar parameters,
invalid ranges/search/sort/filter combinations and exhausted resources return complete
errors. Errors use `application/problem+json`, except Relay pagination 400 wire errors use
JSON. Expensive retained-history reads can return retryable 503 rather than truncated input.
