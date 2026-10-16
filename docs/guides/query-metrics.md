# Query metrics

Kansoku exposes account-scoped analytics at `GET /metrics/*`. Every request requires a service
token (`ksk_s_…`) in `Authorization: Bearer` or `X-Api-Key`. A write key can ingest but receives
HTTP 403 on metrics routes.

## Common query contract

Every implemented metric route requires `from` and `to` dates in `YYYY-MM-DD` format. Ranges are half-open in
UTC: `from` is inclusive and `to` is exclusive. For example, use `from=2026-07-01&to=2026-08-01`
for July.

The public limits are fixed:

| Input or answer | Limit |
| --- | --- |
| Date range | Positive, at most 366 days |
| Ordered funnel | 1..20 non-empty steps; repeated names retain their meaning |
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
`too_many_funnel_steps`, `invalid_retention_days`, `too_many_retention_days`, and
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
from [web enrichment](web-enrichment.md), or `prop:<name>`.

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
| acquisition | `groupBy` (default channel), `timeGrain`, repeatable session-attribute `filter`, `measure` (sessions/users), `includeBots` (default false) |
| sessions | `groupBy`, `timeGrain`, repeatable session-attribute `filter`, `measure` (count/bounce_rate/average_duration_seconds), `includeBots` (default false) |
| conversion | `groupBy` (no prop), repeatable `filter`; timeGrain rejected |
| funnel | required `steps`; optional `window`, `mode`, `measure`, repeatable `exclude`, `groupBy`, repeatable `filter` |
| users | `groupBy`, `timeGrain`, repeatable `filter`, `window` (calendar/rolling7/rolling30), `includeBots` |
| stickiness, lifecycle | `groupBy`, `timeGrain` (day only), repeatable `filter`, `includeBots` |
| retention | `groupBy`, `timeGrain` (day only), repeatable `filter`, `days`, `mode` (on/on_or_after), `cohort` (window/lifetime), `includeBots` |
| experiments | `experiment`, `timeGrain` (day/week/month), `measure` (exposures/diagnostics) |
| experiments/conversion | required `experiment`, `event` |
| experiments/funnel | required `experiment`, `steps`; optional `window`, `mode`, `measure`, repeatable `exclude`, `groupBy`, repeatable `filter` |

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
| `/metrics/funnel` | Exact identity-resolved users completing ordered event steps. |
| `/metrics/retention` | Exact closed-day on/on-or-after retention for window or retained-history lifetime cohorts, omitting immature offsets. |
| `/metrics/feature-adoption` | Exact identity-resolved users emitting `feature_used`, grouped by its `feature` property by default. |
| `/metrics/conversion` | Ordered signup completers among starters within the bounded default window; 0 for empty denominator, always 0..1. |
| `/metrics/users` | Exact calendar or rolling7/rolling30 active subjects, excluding profile-only and default bot rows. |
| `/metrics/stickiness` | Exact daily active, rolling30 active and their ratio as separate numeric measures. |
| `/metrics/lifecycle` | Nonnegative new/returning/resurrecting/dormant counts based on retained matching activity. |
| `/metrics/revenue` | Sum of numeric `amount` on `payment_completed` events. |
| `/metrics/experiments` | Approximate raw identities exposed per experiment/variant, or exact contamination and exclusive first-observed assignment diagnostics. |
| `/metrics/experiments/conversion` | Exact identity-resolved exposed and post-exposure converted users per variant, plus rate. |
| `/metrics/experiments/funnel` | Exact identity-resolved selected-chain post-exposure funnel counts/timing per variant. |

`/metrics/organizations` and `/metrics/custom` are reserved in the
contract but not implemented. They currently return HTTP 404 with code `not_implemented`; do not
build an integration that expects data from them.

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

## Ordered funnels

Supply a non-empty comma-separated `steps` list. A user counted at step N performed steps 1
through N in order. `window` is seconds from the first step to the last counted step and must be
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

Users defaults to `window=calendar` and supports normal hour/day/week/month grains. `rolling7`
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
The endpoint returns `exposed`, `converted`, and `rate` as separate points in each variant's
`group`; it does not calculate statistical significance.

```bash
curl --fail-with-body --get http://localhost:8080/metrics/experiments/conversion \
  --header "Authorization: Bearer $KANSOKU_SERVICE_TOKEN" \
  --data-urlencode 'experiment=checkout_copy' \
  --data-urlencode 'event=payment_completed' \
  --data-urlencode 'from=2026-07-01' \
  --data-urlencode 'to=2026-08-01' | jq .
```

The experiment funnel applies the normal ordered window only to events at or after each user's
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
identify_once, alias, group and experiment_viewed are not engagement; other application events
are. Zero-page sessions count but are not bounces. A page_view followed by page_leave can be
a bounce with positive duration. `measure=average_duration_seconds` averages last minus first
observed timestamp, including page_leave and one-event sessions with zero duration. It measures
elapsed observed duration, not active reading time. Empty ungrouped buckets return zero for
all measures; nonexistent groups are omitted.

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

Both `/metrics/funnel` and `/metrics/experiments/funnel` accept `mode=sequential|strict`,
`measure=count|time_to_convert`, repeatable `exclude`, one/two `groupBy` dimensions and repeated
JSON `filter`. Defaults are sequential/count/no exclusions. Timelines use canonical users,
immutable event deduplication and `(occurred_at milliseconds,event_id)` ordering. One event
cannot satisfy two repeated steps. Sequential skips intervening events; strict requires
adjacent events, including automatic events, without an implicit repeated-event rule. Strict
event filters return 400 because removing rows could hide interruptions.

Every matching start is considered. Select greatest reach, earliest completion, earliest
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
a later attempt wins. A `prop:` breakdown requires only the first-step schema; missing is null.
Typed dimensions, numeric steps and measure names determine final ordering. Large timelines
fail the shared resource limit instead of being truncated.

`/metrics/conversion` now means ordered signup conversion: denominator = canonical users with
signup_started; numerator = those starters with a valid subsequent signup_completed within
the range and default window capped at 90 days. Completion-only and completion-before-start
users do not convert. Empty denominator yields zero; the ratio stays in [0,1]. Group ownership
is the earliest eligible start. timeGrain and prop grouping return explicit 400 errors.

## Exposure diagnostics

`/metrics/experiments?measure=diagnostics` uses exact resolved users; default `measure=exposures`
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
