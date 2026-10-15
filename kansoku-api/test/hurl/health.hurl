GET {{base_url}}/health/live
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.status" == "ok"
jsonpath "$.check" == "all"
jsonpath "$.failingSince" == null

GET {{base_url}}/health/ready
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.status" == "ok"
jsonpath "$.check" == "all"
jsonpath "$.failingSince" == null

GET {{base_url}}/health
HTTP 200
[Asserts]
header "Content-Type" contains "text/plain"
body == "OK"

GET {{base_url}}/ready
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.status" == "ready"
jsonpath "$.checks" count == 5
jsonpath "$.checks[2].check" == "clickhouse_query_reachable"
jsonpath "$.checks[2].ok" == true

GET {{base_url}}/internal/metrics
HTTP 200
[Asserts]
header "Content-Type" contains "text/plain"
body contains "kansoku_queue_length"
body contains "kansoku_writer_events_written_total"
