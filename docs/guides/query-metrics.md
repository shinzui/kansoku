# Query metrics

Kansoku exposes account-scoped analytics at `GET /metrics/*`. Every request requires a service
token (`ksk_s_…`) in `Authorization: Bearer` or `X-Api-Key`. A write key can ingest but receives
HTTP 403 on metrics routes.

## Common query contract

Most metric routes require `from` and `to` dates in `YYYY-MM-DD` format. Ranges are half-open in
UTC: `from` is inclusive and `to` is exclusive. For example, use `from=2026-07-01&to=2026-08-01`
for July.

Standard metric routes also accept:

- `timeGrain`: `hour`, `day`, `week`, or `month`; the metric's default is `day`.
- `groupBy`: exactly one of `event_name`, `source`, `route`, or `prop:<name>`.

Property grouping is available only when the metric has a fixed set of registered event names
and every such event declares that property. It is therefore useful for routes such as
`page-views`, `feature-adoption`, and `revenue`, but not an unrestricted all-event metric.
Ratio metrics do not support property grouping. An invalid, multiple, or undeclared dimension
returns HTTP 400.

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

`bucket` is omitted when an endpoint returns an unbucketed result. `group` is always an object
and carries dimensions, funnel steps, retention cohorts, or experiment variants. A valid query
with no matching data returns HTTP 200 with an empty `points` array.

## Implemented endpoints

| Endpoint | Current meaning |
| --- | --- |
| `/metrics/events` | Distinct event IDs across all event names. |
| `/metrics/page-views` | `page_view` rows; the default daily path uses the page-view rollup. |
| `/metrics/sessions` | Distinct non-empty producer-supplied `sessionId` values. |
| `/metrics/funnel` | Exact identity-resolved users completing ordered event steps. |
| `/metrics/retention` | Exact identity-resolved activity by new-in-window cohort and day offset. |
| `/metrics/feature-adoption` | Exact identity-resolved users emitting `feature_used`, grouped by its `feature` property by default. |
| `/metrics/conversion` | Users with `signup_completed` divided by users with `signup_started`; returns 0 when the denominator is 0. |
| `/metrics/users` | Active users. Day/week use approximate raw-identity rollups; other grains use exact query-time identity resolution. |
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

Exact user metrics resolve identity at query time. Day/week active-user and experiment-exposure
rollups use `uniqCombined` (about 0.8% relative error at scale and exact for small sets). Exposure
rollups use raw identity, while experiment conversion and funnels use exact stitched identity;
do not treat their denominators as interchangeable without acknowledging that difference.

For the complete parameter and response schema, use the
[generated OpenAPI document](../api/openapi.json) or `GET /openapi.json`.

[Documentation index](../README.md)
