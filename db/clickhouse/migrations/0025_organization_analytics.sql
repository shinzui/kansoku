-- EP-45: append the organization without changing the first seven columns.
-- Rollback (after reverting consumers):
-- CREATE OR REPLACE VIEW analytics.events_resolved_v3 DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
-- SELECT event_id,event_name,occurred_at,url,account_id,canonical_user,properties_json
-- FROM analytics.events_resolved_internal(scope_all_accounts=1,scope_account='',scope_from=toDateTime64('1970-01-01',3,'UTC'),scope_to=toDateTime64('2100-01-01',3,'UTC'));
-- CREATE OR REPLACE VIEW analytics.events_resolved DEFINER = CURRENT_USER SQL SECURITY DEFINER AS SELECT * FROM analytics.events_resolved_v3;
CREATE OR REPLACE VIEW analytics.events_resolved_v3
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
SELECT event_id,event_name,occurred_at,url,account_id,canonical_user,properties_json,organization_id
FROM analytics.events_resolved_internal(scope_all_accounts=1,scope_account='',scope_from=toDateTime64('1970-01-01',3,'UTC'),scope_to=toDateTime64('2100-01-01',3,'UTC'));
CREATE OR REPLACE VIEW analytics.events_resolved
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS SELECT * FROM analytics.events_resolved_v3;

CREATE TABLE IF NOT EXISTS analytics.organization_properties
(account_id String,organization_id String,name String,
 value AggregateFunction(argMax,Tuple(String,String,Float64),Tuple(DateTime64(3,'UTC'),DateTime64(3,'UTC'),String)))
ENGINE=AggregatingMergeTree ORDER BY (account_id,organization_id,name);
CREATE OR REPLACE VIEW analytics.organization_trait_events AS
WITH toFloat64OrNull(toString(getSubcolumn(properties_json,'seats'))) AS seat_number
SELECT account_id,organization_id,event_id,occurred_at,received_at,
trait.1 AS name,trait.2 AS trait_type,trait.3 AS text_value,trait.4 AS number_value
FROM analytics.events_canonical
ARRAY JOIN [('plan','string',ifNull(dynamicElement(getSubcolumn(properties_json,'plan'),'String'),''),toFloat64(0)),('industry','string',ifNull(dynamicElement(getSubcolumn(properties_json,'industry'),'String'),''),toFloat64(0)),('country','string',ifNull(dynamicElement(getSubcolumn(properties_json,'country'),'String'),''),toFloat64(0)),('seats','number','',ifNull(seat_number,toFloat64(0)))] AS trait
WHERE event_name='group' AND schema_version=2 AND organization_id!='' AND governed_traits_valid
AND (account_id,event_id) NOT IN (SELECT account_id,event_id FROM analytics.trait_event_erasures)
AND (NOT JSONHas(properties,'plan') OR dynamicType(getSubcolumn(properties_json,'plan'))='String')
AND (NOT JSONHas(properties,'industry') OR dynamicType(getSubcolumn(properties_json,'industry'))='String')
AND (NOT JSONHas(properties,'country') OR dynamicType(getSubcolumn(properties_json,'country'))='String')
AND (NOT JSONHas(properties,'seats') OR (dynamicType(getSubcolumn(properties_json,'seats')) IN ('Int64','UInt64','Float64') AND isFinite(seat_number) AND seat_number>=0 AND floor(seat_number)=seat_number))
AND JSONHas(properties,trait.1);
CREATE MATERIALIZED VIEW IF NOT EXISTS analytics.mv_organization_properties TO analytics.organization_properties AS
SELECT account_id,organization_id,name,argMaxState(tuple(trait_type,text_value,number_value),tuple(occurred_at,received_at,event_id)) AS value
FROM (WITH toFloat64OrNull(toString(getSubcolumn(properties_json,'seats'))) AS seat_number
SELECT account_id,organization_id,event_id,occurred_at,received_at,
trait.1 AS name,trait.2 AS trait_type,trait.3 AS text_value,trait.4 AS number_value
FROM analytics.events_raw
ARRAY JOIN [('plan','string',ifNull(dynamicElement(getSubcolumn(properties_json,'plan'),'String'),''),toFloat64(0)),('industry','string',ifNull(dynamicElement(getSubcolumn(properties_json,'industry'),'String'),''),toFloat64(0)),('country','string',ifNull(dynamicElement(getSubcolumn(properties_json,'country'),'String'),''),toFloat64(0)),('seats','number','',ifNull(seat_number,toFloat64(0)))] AS trait
WHERE event_name='group' AND schema_version=2 AND organization_id!='' AND governed_traits_valid
AND (account_id,event_id) NOT IN (SELECT account_id,event_id FROM analytics.trait_event_erasures)
AND (NOT JSONHas(properties,'plan') OR dynamicType(getSubcolumn(properties_json,'plan'))='String')
AND (NOT JSONHas(properties,'industry') OR dynamicType(getSubcolumn(properties_json,'industry'))='String')
AND (NOT JSONHas(properties,'country') OR dynamicType(getSubcolumn(properties_json,'country'))='String')
AND (NOT JSONHas(properties,'seats') OR (dynamicType(getSubcolumn(properties_json,'seats')) IN ('Int64','UInt64','Float64') AND isFinite(seat_number) AND seat_number>=0 AND floor(seat_number)=seat_number))
AND JSONHas(properties,trait.1)) GROUP BY account_id,organization_id,name;
INSERT INTO analytics.organization_properties
SELECT account_id,organization_id,name,argMaxState(tuple(trait_type,text_value,number_value),tuple(occurred_at,received_at,event_id)) AS value
FROM (SELECT * FROM analytics.organization_trait_events) GROUP BY account_id,organization_id,name;
CREATE OR REPLACE VIEW analytics.organization_traits AS
SELECT account_id,organization_id,name,selected.1 AS trait_type,selected.2 AS text_value,selected.3 AS number_value
FROM (SELECT account_id,organization_id,name,argMaxMerge(value) AS selected FROM analytics.organization_properties GROUP BY account_id,organization_id,name);

CREATE TABLE IF NOT EXISTS analytics.user_organizations
(account_id String,user_id String,
 organization_id AggregateFunction(argMax,String,Tuple(DateTime64(3,'UTC'),DateTime64(3,'UTC'),String)))
ENGINE=AggregatingMergeTree ORDER BY (account_id,user_id);
CREATE MATERIALIZED VIEW IF NOT EXISTS analytics.mv_user_organizations TO analytics.user_organizations AS
SELECT account_id,user_id,argMaxState(r.organization_id,tuple(occurred_at,received_at,event_id)) AS organization_id
FROM analytics.events_raw AS r
WHERE event_name='group' AND r.organization_id!='' AND user_id!=''
AND (account_id,event_id) NOT IN (SELECT account_id,event_id FROM analytics.trait_event_erasures)
GROUP BY account_id,user_id;
INSERT INTO analytics.user_organizations
SELECT account_id,user_id,argMaxState(r.organization_id,tuple(occurred_at,received_at,event_id)) AS organization_id
FROM analytics.events_canonical AS r
WHERE event_name='group' AND r.organization_id!='' AND user_id!=''
AND (account_id,event_id) NOT IN (SELECT account_id,event_id FROM analytics.trait_event_erasures)
GROUP BY account_id,user_id;
