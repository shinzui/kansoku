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
`groupBy` and repeatable `filter`. The default grain is day; conversion without a grain is one
ratio over the whole interval. `groupBy` contains one or two distinct comma-separated names:
`event_name`, `source`, `source_service`, `host`, `route`, or `prop:<name>`.

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

Unknown/unsupported parameters return 400 `unsupported_query_parameter`. Only `filter` may
repeat; duplicate scalar parameters or missing values return `invalid_query_parameter`.
Invalid JSON/filter grammar or incompatible filter types return `invalid_filter`.

| Route | Parameters in addition to required `from`, `to` |
| --- | --- |
| events, page-views, users, feature-adoption, revenue, conversion | `groupBy`, `timeGrain`, repeatable `filter` |
| sessions | `timeGrain` |
| funnel | required `steps`; optional `window` |
| retention | `days` |
| experiments | `experiment`, `timeGrain` (day/week/month) |
| experiments/conversion | required `experiment`, `event` |
| experiments/funnel | required `experiment`, `steps`; optional `window` |

Session/cohort/funnel-specific filter populations are extended by their dedicated feature
contracts; unsupported event-filter parameters currently fail explicitly on those routes.
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
| `/metrics/page-views` | Distinct canonical `page_view` event IDs with the same filters at every grain. |
| `/metrics/sessions` | Distinct non-empty producer-supplied `sessionId` values. |
| `/metrics/funnel` | Exact identity-resolved users completing ordered event steps. |
| `/metrics/retention` | Exact identity-resolved activity by new-in-window cohort and day offset. |
| `/metrics/feature-adoption` | Exact identity-resolved users emitting `feature_used`, grouped by its `feature` property by default. |
| `/metrics/conversion` | Users with `signup_completed` divided by users with `signup_started`; returns 0 when the denominator is 0. |
| `/metrics/users` | Exact canonical resolved active users at every grain, excluding identify, identify_once, alias and group events. |
| `/metrics/revenue` | Sum of numeric `amount` on `payment_completed` events. |
| `/metrics/experiments` | Approximate raw identities exposed per experiment and variant. |
| `/metrics/experiments/conversion` | Exact identity-resolved exposed and post-exposure converted users per variant, plus rate. |
| `/metrics/experiments/funnel` | Exact identity-resolved ordered post-exposure funnel counts per variant. |

`/metrics/acquisition`, `/metrics/organizations`, and `/metrics/custom` are reserved in the
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

## Retention

`days` is an optional comma-separated list of positive day offsets and defaults to
`1,7,14,30`. Offset 0 is always included as the cohort size. A user's cohort day is their first
activity inside the requested range, not their lifetime first activity; someone active before
the range can appear as new again.

```bash
curl --fail-with-body --get http://localhost:8080/metrics/retention \
  --header "X-Api-Key: $KANSOKU_SERVICE_TOKEN" \
  --data-urlencode 'from=2026-07-01' \
  --data-urlencode 'to=2026-08-01' \
  --data-urlencode 'days=1,7,14' | jq .
```

Each point puts `cohort` and `offset` in `group` and the retained user count in `value`.

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
