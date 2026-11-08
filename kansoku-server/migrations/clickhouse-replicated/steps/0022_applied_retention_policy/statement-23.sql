
CREATE MATERIALIZED VIEW analytics.mv_user_properties_once TO analytics.user_properties_once AS
SELECT account_id,user_id,name,argMinState(tuple(trait_type,text_value,number_value),tuple(occurred_at,received_at,event_id)) AS value
FROM (WITH
  toFloat64OrNull(toString(getSubcolumn(properties_json,'company_size'))) AS company_number
SELECT account_id,user_id,event_id,event_name,occurred_at,received_at,
       trait.1 AS name,trait.2 AS trait_type,trait.3 AS text_value,trait.4 AS number_value
FROM (SELECT *, properties_json, identity_context_key, context_json FROM analytics.events_raw WHERE occurred_at >= (SELECT argMax(cutoff,revision) FROM analytics.retention_policy))
ARRAY JOIN [('plan','string',ifNull(dynamicElement(getSubcolumn(properties_json,'plan'),'String'),''),toFloat64(0)),('signup_source','string',ifNull(dynamicElement(getSubcolumn(properties_json,'signup_source'),'String'),''),toFloat64(0)),('initial_plan','string',ifNull(dynamicElement(getSubcolumn(properties_json,'initial_plan'),'String'),''),toFloat64(0)),('country','string',ifNull(dynamicElement(getSubcolumn(properties_json,'country'),'String'),''),toFloat64(0)),('role','string',ifNull(dynamicElement(getSubcolumn(properties_json,'role'),'String'),''),toFloat64(0)),('company_size','number','',ifNull(company_number,toFloat64(0)))] AS trait
WHERE governed_traits_valid AND user_id!=''
  AND ((event_name='identify' AND schema_version=2) OR (event_name='identify_once' AND schema_version=1))
  AND (account_id,event_id) NOT IN (SELECT account_id,event_id FROM analytics.trait_event_erasures)
  AND (NOT JSONHas(properties,'plan') OR dynamicType(getSubcolumn(properties_json,'plan'))='String')
  AND (NOT JSONHas(properties,'signup_source') OR dynamicType(getSubcolumn(properties_json,'signup_source'))='String')
  AND (NOT JSONHas(properties,'initial_plan') OR dynamicType(getSubcolumn(properties_json,'initial_plan'))='String')
  AND (NOT JSONHas(properties,'country') OR dynamicType(getSubcolumn(properties_json,'country'))='String')
  AND (NOT JSONHas(properties,'role') OR dynamicType(getSubcolumn(properties_json,'role'))='String')
  AND (NOT JSONHas(properties,'company_size') OR (dynamicType(getSubcolumn(properties_json,'company_size')) IN ('Int64','UInt64','Float64') AND isFinite(company_number) AND company_number>=0 AND floor(company_number)=company_number))
  AND JSONHas(properties,trait.1)) WHERE event_name='identify_once' GROUP BY account_id,user_id,name;
