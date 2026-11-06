GET {{base_url}}/v1/schemas
Origin: https://allowed.example
HTTP 200
[Asserts]
header "Content-Type" contains "application/json"
header "Access-Control-Allow-Origin" == "https://allowed.example"
jsonpath "$.catalogVersion" == 5
jsonpath "$.service" == "kansoku"
jsonpath "$.events.page_view.versions[0].version" == 1
jsonpath "$.events.page_view.versions[0].properties[0].name" == "url"
jsonpath "$.events.page_view.versions[0].properties[0].required" == true
jsonpath "$.identifierKinds[4]" == "email_hmac"
jsonpath "$.events.identify.versions[1].version" == 2
jsonpath "$.events.identify_once.versions[0].version" == 1
jsonpath "$.events.client_error.versions[0].version" == 1
jsonpath "$.events.client_error.versions[0].properties[0].maxLength" == 256
jsonpath "$.events.client_error.versions[0].properties[1].maxLength" == 128
jsonpath "$.events.client_error.versions[0].properties[2].type" == "bool"
jsonpath "$.events.web_vital.versions[0].version" == 1
jsonpath "$.events.web_vital.versions[0].properties[0].pattern" == "^(LCP|INP|CLS|FCP|TTFB)$"
jsonpath "$.events.web_vital.versions[0].properties[1].minimum" == 0
