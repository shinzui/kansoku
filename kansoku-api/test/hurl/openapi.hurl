GET {{base_url}}/openapi.json
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
jsonpath "$.openapi" == "3.1.0"
jsonpath "$.paths['/v1/events'].post.responses['202'].content['application/json']" exists
jsonpath "$.paths['/v1/beacon'].post.requestBody.content['text/plain;charset=utf-8']" exists
jsonpath "$.paths['/v1/beacon'].post.requestBody.content['application/json;charset=utf-8']" exists
jsonpath "$.paths['/v1/beacon'].post.responses['429'].headers['Retry-After'].required" == true
jsonpath "$.paths['/metrics/events'].get.responses['400'].content['application/problem+json']" exists
jsonpath "$.paths['/metrics/events'].get.responses['401'].content['application/problem+json']" exists
jsonpath "$.components.schemas.MetricResult.properties.points.maxItems" == 10000
jsonpath "$.paths['/health/live']" not exists
jsonpath "$.paths['/internal/metrics']" not exists
