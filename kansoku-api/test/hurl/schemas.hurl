GET {{base_url}}/v1/schemas
Origin: https://allowed.example
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
header "Access-Control-Allow-Origin" == "https://allowed.example"
jsonpath "$.catalogVersion" == 3
jsonpath "$.service" == "kansoku"
jsonpath "$.events.page_view.versions[0].version" == 1
jsonpath "$.events.page_view.versions[0].properties[0].name" == "url"
jsonpath "$.events.page_view.versions[0].properties[0].required" == true
jsonpath "$.identifierKinds[4]" == "email_hmac"
