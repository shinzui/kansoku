# Explicit opt-in write family. Only the observing GET retries.
POST {{base_url}}/v1/batch
Authorization: Bearer {{write_ingest_token}}
Origin: https://allowed.example
Content-Type: application/json
[
  {
    "eventId": "{{event_id}}",
    "eventName": "acceptance_visible",
    "source": "web",
    "occurredAt": "2026-07-01T12:00:00Z",
    "receivedAt": "2026-07-01T12:00:01Z",
    "userId": "acceptance-user",
    "properties": {},
    "context": {}
  },
  {
    "eventId": "{{event_id}}_invalid",
    "eventName": "page_view",
    "source": "web",
    "occurredAt": "2026-07-01T12:00:00Z",
    "receivedAt": "2026-07-01T12:00:01Z",
    "properties": {},
    "context": {}
  }
]
HTTP 202
[Asserts]
header "Content-Type" contains "application/json"
header "Access-Control-Allow-Origin" == "https://allowed.example"
jsonpath "$.accepted" == 1
jsonpath "$.rejected" count == 1
jsonpath "$.rejected[0].index" == 1

GET {{base_url}}/metrics/events?from={{from}}&to={{to}}&groupBy=event_name
Authorization: Bearer {{service_ingest_token}}
[Options]
retry: 40
retry-interval: 150ms
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.metric" == "events"
jsonpath "$.points" count == 1
jsonpath "$.points[0].group.event_name" == "acceptance_visible"
jsonpath "$.points[0].value" == 1

GET {{base_url}}/metrics/events?from={{from}}&to={{to}}&groupBy=event_name
Authorization: Bearer {{other_token}}
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.metric" == "events"
jsonpath "$.points" count == 0

# SDK alias/group envelopes and the page-exit lifecycle schema share validation.
POST {{base_url}}/v1/batch
Authorization: Bearer {{write_ingest_token}}
Content-Type: application/json
[
  {
    "eventId": "{{event_id}}_alias",
    "eventName": "alias",
    "schemaVersion": 1,
    "source": "web",
    "occurredAt": "2026-07-01T12:00:00Z",
    "receivedAt": "2026-07-01T12:00:00Z",
    "anonymousId": "sdk-anonymous",
    "userId": "sdk-user",
    "properties": {"previousId": "sdk-anonymous", "newId": "sdk-user"},
    "context": {}
  },
  {
    "eventId": "{{event_id}}_group",
    "eventName": "group",
    "schemaVersion": 1,
    "source": "web",
    "occurredAt": "2026-07-01T12:00:00Z",
    "receivedAt": "2026-07-01T12:00:00Z",
    "userId": "sdk-user",
    "organizationId": "sdk-organization",
    "properties": {},
    "context": {}
  },
  {
    "eventId": "{{event_id}}_leave",
    "eventName": "page_leave",
    "schemaVersion": 1,
    "source": "web",
    "occurredAt": "2026-07-01T12:00:00Z",
    "receivedAt": "2026-07-01T12:00:00Z",
    "url": "https://example.test/page",
    "properties": {"durationMs": 1250},
    "context": {}
  }
]
HTTP 202
[Asserts]
jsonpath "$.accepted" == 3
jsonpath "$.rejected" count == 0
