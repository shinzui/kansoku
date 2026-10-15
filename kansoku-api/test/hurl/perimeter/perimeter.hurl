GET {{base_url}}/metrics/events?from={{from}}&to={{to}}
HTTP 401
[Asserts]
header "Content-Type" contains "application/problem+json"
header "WWW-Authenticate" contains "Bearer"
jsonpath "$.code" == "unauthorized"
jsonpath "$.status" == 401

GET {{base_url}}/metrics/events?from={{from}}&to={{to}}
Authorization: Bearer disposable-invalid-token
HTTP 401
[Asserts]
header "Content-Type" contains "application/problem+json"
jsonpath "$.code" == "unauthorized"
jsonpath "$.retryable" == false

GET {{base_url}}/metrics/events?from={{from}}&to={{to}}
Authorization: Bearer {{write_token}}
HTTP 403
[Asserts]
header "Content-Type" contains "application/problem+json"
jsonpath "$.code" == "forbidden"
jsonpath "$.status" == 403

OPTIONS {{base_url}}/v1/events
Origin: https://allowed.example
Access-Control-Request-Method: POST
Access-Control-Request-Headers: authorization,content-type
HTTP 200
[Asserts]
header "Access-Control-Allow-Origin" == "https://allowed.example"

GET {{base_url}}/v1/schemas
Origin: https://blocked.example
HTTP 400
[Asserts]
header "Content-Type" contains "text/html"
header "Access-Control-Allow-Origin" not exists
body contains "origin"

POST {{base_url}}/v1/events
Authorization: Bearer {{service_token}}
Origin: https://allowed.example
Content-Type: application/json
```
{
```
HTTP 400
[Asserts]
header "Content-Type" contains "application/problem+json"
header "Access-Control-Allow-Origin" == "https://allowed.example"
jsonpath "$.code" == "malformed_request"
jsonpath "$.status" == 400

POST {{base_url}}/v1/events
Authorization: Bearer {{service_token}}
Origin: https://allowed.example
Content-Type: application/json
file,{{oversized_file}};
HTTP 413
[Asserts]
header "Content-Type" contains "application/problem+json"
header "Access-Control-Allow-Origin" == "https://allowed.example"
jsonpath "$.code" == "payload_too_large"
jsonpath "$.retryable" == false

GET {{base_url}}/definitely-missing
HTTP 404
[Asserts]
header "Content-Type" contains "application/problem+json"
jsonpath "$.code" == "not_found"
jsonpath "$.status" == 404
