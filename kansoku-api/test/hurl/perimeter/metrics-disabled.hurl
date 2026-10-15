GET {{base_url}}/internal/metrics
HTTP 404
[Asserts]
header "Content-Type" contains "text/plain"
body == "Not Found"
