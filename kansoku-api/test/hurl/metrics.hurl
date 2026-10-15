GET {{base_url}}/metrics/events?from={{from}}&to={{to}}
Authorization: Bearer {{service_token}}
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.metric" == "events"
jsonpath "$.points" count > 0
jsonpath "$.points[0].value" == 8

GET {{base_url}}/metrics/page-views?from={{from}}&to={{to}}
Authorization: Bearer {{service_token}}
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.metric" == "page_views"
jsonpath "$.points" count > 0
jsonpath "$.points[0].value" == 3

GET {{base_url}}/metrics/sessions?from={{from}}&to={{to}}
Authorization: Bearer {{service_token}}
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.metric" == "sessions"
jsonpath "$.points" count > 0
jsonpath "$.points[0].value" == 2

GET {{base_url}}/metrics/feature-adoption?from={{from}}&to={{to}}
Authorization: Bearer {{service_token}}
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.metric" == "feature_adoption"
jsonpath "$.points" count > 0
jsonpath "$.points[0].value" == 1

GET {{base_url}}/metrics/conversion?from={{from}}&to={{to}}
Authorization: Bearer {{service_token}}
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.metric" == "conversion_rate"
jsonpath "$.points" count > 0
jsonpath "$.points[0].value" == 0.5

GET {{base_url}}/metrics/users?from={{from}}&to={{to}}
Authorization: Bearer {{service_token}}
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.metric" == "active_users"
jsonpath "$.points" count > 0
jsonpath "$.points[0].value" == 2

GET {{base_url}}/metrics/revenue?from={{from}}&to={{to}}&groupBy=prop:plan
Authorization: Bearer {{service_token}}
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.metric" == "revenue"
jsonpath "$.points" count > 0
jsonpath "$.points[0].value" == 7

GET {{base_url}}/metrics/funnel?from={{from}}&to={{to}}&steps=signup_started,signup_completed
Authorization: Bearer {{service_token}}
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.metric" == "funnel"
jsonpath "$.points" count > 0
jsonpath "$.points[0].value" == 2

GET {{base_url}}/metrics/retention?from={{from}}&to={{to}}&days=1,2,10
Authorization: Bearer {{service_token}}
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.metric" == "retention"
jsonpath "$.points" count > 0

GET {{base_url}}/metrics/experiments?from={{from}}&to={{to}}&experiment=checkout_v2
Authorization: Bearer {{service_token}}
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.metric" == "experiment_exposures"
jsonpath "$.points" count > 0

GET {{base_url}}/metrics/experiments/conversion?from={{from}}&to={{to}}&experiment=checkout_v2&event=signup_completed
Authorization: Bearer {{service_token}}
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.metric" == "experiment_conversion"
jsonpath "$.points" count > 0

GET {{base_url}}/metrics/experiments/funnel?from={{from}}&to={{to}}&experiment=checkout_v2&steps=signup_started,signup_completed
Authorization: Bearer {{service_token}}
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.metric" == "experiment_funnel"
jsonpath "$.points" count > 0

GET {{base_url}}/metrics/acquisition?from={{from}}&to={{to}}
Authorization: Bearer {{service_token}}
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.metric" == "acquisition"
jsonpath "$.points" count > 0

GET {{base_url}}/metrics/organizations?from={{from}}&to={{to}}
Authorization: Bearer {{service_token}}
HTTP 404
[Asserts]
header "Content-Type" contains "application/problem+json"
jsonpath "$.code" == "not_implemented"
jsonpath "$.status" == 404
jsonpath "$.retryable" == false

GET {{base_url}}/metrics/custom?from={{from}}&to={{to}}
Authorization: Bearer {{service_token}}
HTTP 404
[Asserts]
header "Content-Type" contains "application/problem+json"
jsonpath "$.code" == "not_implemented"
jsonpath "$.status" == 404
jsonpath "$.retryable" == false

GET {{base_url}}/metrics/events?from=2026-07-01&to=2026-07-01
Authorization: Bearer {{service_token}}
HTTP 400
[Asserts]
header "Content-Type" contains "application/problem+json"
jsonpath "$.code" == "invalid_date_range"
jsonpath "$.retryable" == false

GET {{base_url}}/metrics/events?from=2026-01-01&to=2027-01-03
Authorization: Bearer {{service_token}}
HTTP 400
[Asserts]
header "Content-Type" contains "application/problem+json"
jsonpath "$.code" == "query_range_too_large"
jsonpath "$.retryable" == false

GET {{base_url}}/metrics/events?from=nope&to={{to}}
Authorization: Bearer {{service_token}}
HTTP 400
[Asserts]
header "Content-Type" contains "application/problem+json"
jsonpath "$.code" == "malformed_request"
jsonpath "$.status" == 400

GET {{base_url}}/metrics/revenue?from={{from}}&to={{to}}&groupBy=prop:plan
Authorization: Bearer {{highcard_token}}
HTTP 400
[Asserts]
header "Content-Type" contains "application/problem+json"
jsonpath "$.code" == "metric_result_too_large"
jsonpath "$.retryable" == false
jsonpath "$.points" not exists

GET {{base_url}}/metrics/experiments?from={{from}}&to={{to}}
Authorization: Bearer {{highcard_token}}
HTTP 400
[Asserts]
header "Content-Type" contains "application/problem+json"
jsonpath "$.code" == "metric_result_too_large"
jsonpath "$.retryable" == false
jsonpath "$.points" not exists

# A finite event-name filter makes an event property dimension valid.
GET {{base_url}}/metrics/events?from={{from}}&to={{to}}&groupBy=source,prop:plan
Authorization: Bearer {{service_token}}
[QueryStringParams]
filter: {"dimension":"event_name","op":"eq","value":"payment_completed"}
filter: {"dimension":"prop:amount","op":"gt","value":0}
HTTP 200
[Asserts]
jsonpath "$.points[0].group.source" == "web"
jsonpath "$.points[0].group['prop:plan']" == "pro"
jsonpath "$.points[0].value" == 1

GET {{base_url}}/metrics/users?from={{from}}&to={{to}}
Authorization: Bearer {{service_token}}
[QueryStringParams]
filter: {"dimension":"source","op":"in","value":["web","app","service","worker","email","agent"]}
HTTP 200
[Asserts]
jsonpath "$.points[0].value" == 2

GET {{base_url}}/metrics/revenue?from={{from}}&to={{to}}
Authorization: Bearer {{service_token}}
[QueryStringParams]
filter: {"dimension":"prop:plan","op":"neq","value":"pro"}
HTTP 200
[Asserts]
jsonpath "$.points" count == 0

GET {{base_url}}/metrics/events?from={{from}}&to={{to}}
Authorization: Bearer {{service_token}}
[QueryStringParams]
filter: {"dimension":"source","op":"eq","value":null}
HTTP 400
[Asserts]
jsonpath "$.code" == "invalid_filter"
jsonpath "$.retryable" == false

GET {{base_url}}/metrics/events?from={{from}}&to={{to}}&unknown=value
Authorization: Bearer {{service_token}}
HTTP 400
[Asserts]
jsonpath "$.code" == "unsupported_query_parameter"

GET {{base_url}}/metrics/sessions?from={{from}}&to={{to}}&attribution=event
Authorization: Bearer {{service_token}}
HTTP 400
[Asserts]
jsonpath "$.code" == "unsupported_query_parameter"

GET {{base_url}}/metrics/sessions?from={{from}}&to={{to}}&measure=bounce_rate&groupBy=entry_page,exit_page
Authorization: Bearer {{service_token}}
HTTP 200
[Asserts]
jsonpath "$.metric" == "sessions"

GET {{base_url}}/metrics/sessions?from={{from}}&to={{to}}&measure=average_duration_seconds&includeBots=true
Authorization: Bearer {{service_token}}
HTTP 200
[Asserts]
jsonpath "$.metric" == "sessions"

GET {{base_url}}/metrics/sessions?from={{from}}&to={{to}}
Authorization: Bearer {{service_token}}
[QueryStringParams]
filter: {"dimension":"prop:url","op":"set"}
HTTP 400
[Asserts]
jsonpath "$.code" == "invalid_filter"

GET {{base_url}}/metrics/sessions?from={{from}}&to={{to}}&groupBy=prop:url
Authorization: Bearer {{service_token}}
HTTP 400
[Asserts]
jsonpath "$.code" == "invalid_group_by"

GET {{base_url}}/metrics/users?from={{from}}&to={{to}}&window=rolling7&timeGrain=day
Authorization: Bearer {{service_token}}
HTTP 200
[Asserts]
jsonpath "$.metric" == "active_users"

GET {{base_url}}/metrics/users?from={{from}}&to={{to}}&window=rolling30&timeGrain=week
Authorization: Bearer {{service_token}}
HTTP 400
[Asserts]
jsonpath "$.code" == "invalid_time_grain"

GET {{base_url}}/metrics/stickiness?from={{from}}&to={{to}}
Authorization: Bearer {{service_token}}
HTTP 200
[Asserts]
jsonpath "$.metric" == "stickiness"
jsonpath "$.points[0].group.measure" == "daily_active"

GET {{base_url}}/metrics/lifecycle?from={{from}}&to={{to}}
Authorization: Bearer {{service_token}}
HTTP 200
[Asserts]
jsonpath "$.metric" == "lifecycle"
jsonpath "$.points[0].group.status" == "new"

GET {{base_url}}/metrics/retention?from={{from}}&to={{to}}&days=1,7&mode=on_or_after&cohort=lifetime
Authorization: Bearer {{service_token}}
HTTP 200
[Asserts]
jsonpath "$.metric" == "retention"

GET {{base_url}}/metrics/users?from=2099-07-01&to=2099-07-02
Authorization: Bearer {{service_token}}
HTTP 400
[Asserts]
jsonpath "$.code" == "unclosed_observation_window"
