-- EP-40: governed current traits. Keep ingest/writers fenced during DDL/rebuilds.
-- Identify v1 is identity-only. Eligibility mirrors the shared registry and
-- checks actual stored schema_version and the immutable server validation marker.
-- Exact decimal integrality is validated before Float64/native JSON conversion.
-- Strings are stored decoded; numeric values use the metrics Float64 contract.
ALTER TABLE analytics.events_raw ADD COLUMN IF NOT EXISTS governed_traits_valid Bool DEFAULT false;

CREATE OR REPLACE VIEW analytics.events_canonical
AS SELECT *,properties_json,identity_context_key,context_json FROM analytics.events_raw FINAL;

CREATE TABLE IF NOT EXISTS analytics.trait_event_erasures
(account_id String,event_id String)
ENGINE=ReplacingMergeTree ORDER BY (account_id,event_id);

CREATE TABLE IF NOT EXISTS analytics.user_properties
(account_id String,user_id String,name String,
 value AggregateFunction(argMax,Tuple(String,String,Float64),Tuple(DateTime64(3,'UTC'),DateTime64(3,'UTC'),String)))
ENGINE=AggregatingMergeTree ORDER BY (account_id,user_id,name);

CREATE TABLE IF NOT EXISTS analytics.user_properties_once
(account_id String,user_id String,name String,
 value AggregateFunction(argMin,Tuple(String,String,Float64),Tuple(DateTime64(3,'UTC'),DateTime64(3,'UTC'),String)))
ENGINE=AggregatingMergeTree ORDER BY (account_id,user_id,name);

CREATE OR REPLACE VIEW analytics.user_trait_events AS
WITH
  toFloat64OrNull(toString(getSubcolumn(properties_json,'company_size'))) AS company_number
SELECT account_id,user_id,event_id,event_name,occurred_at,received_at,
       trait.1 AS name,trait.2 AS trait_type,trait.3 AS text_value,trait.4 AS number_value
FROM analytics.events_canonical
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
  AND JSONHas(properties,trait.1);

DROP TABLE IF EXISTS analytics.mv_user_properties;
CREATE MATERIALIZED VIEW analytics.mv_user_properties TO analytics.user_properties AS
SELECT account_id,user_id,name,argMaxState(tuple(trait_type,text_value,number_value),tuple(occurred_at,received_at,event_id)) AS value
FROM (WITH
  toFloat64OrNull(toString(getSubcolumn(properties_json,'company_size'))) AS company_number
SELECT account_id,user_id,event_id,event_name,occurred_at,received_at,
       trait.1 AS name,trait.2 AS trait_type,trait.3 AS text_value,trait.4 AS number_value
FROM analytics.events_raw
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
  AND JSONHas(properties,trait.1)) WHERE event_name='identify' GROUP BY account_id,user_id,name;

INSERT INTO analytics.user_properties
SELECT account_id,user_id,name,argMaxState(tuple(trait_type,text_value,number_value),tuple(occurred_at,received_at,event_id)) AS value
FROM (SELECT * FROM analytics.user_trait_events) WHERE event_name='identify' GROUP BY account_id,user_id,name;

DROP TABLE IF EXISTS analytics.mv_user_properties_once;
CREATE MATERIALIZED VIEW analytics.mv_user_properties_once TO analytics.user_properties_once AS
SELECT account_id,user_id,name,argMinState(tuple(trait_type,text_value,number_value),tuple(occurred_at,received_at,event_id)) AS value
FROM (WITH
  toFloat64OrNull(toString(getSubcolumn(properties_json,'company_size'))) AS company_number
SELECT account_id,user_id,event_id,event_name,occurred_at,received_at,
       trait.1 AS name,trait.2 AS trait_type,trait.3 AS text_value,trait.4 AS number_value
FROM analytics.events_raw
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

INSERT INTO analytics.user_properties_once
SELECT account_id,user_id,name,argMinState(tuple(trait_type,text_value,number_value),tuple(occurred_at,received_at,event_id)) AS value
FROM (SELECT * FROM analytics.user_trait_events) WHERE event_name='identify_once' GROUP BY account_id,user_id,name;

CREATE OR REPLACE VIEW analytics.user_traits AS
SELECT account_id,user_id,name,selected.1 AS trait_type,selected.2 AS text_value,selected.3 AS number_value
FROM (
  SELECT account_id,user_id,name,argMax(candidate,priority) AS selected
  FROM (
    SELECT account_id,user_id,name,argMaxMerge(value) AS candidate,toUInt8(1) AS priority
    FROM analytics.user_properties GROUP BY account_id,user_id,name
    UNION ALL
    SELECT account_id,user_id,name,argMinMerge(value) AS candidate,toUInt8(0) AS priority
    FROM analytics.user_properties_once GROUP BY account_id,user_id,name
  ) GROUP BY account_id,user_id,name
);
