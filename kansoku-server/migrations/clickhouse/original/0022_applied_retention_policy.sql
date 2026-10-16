-- Applied cutoff advances only through fenced kansoku-admin apply-retention.
-- Physical TTL cleanup is separate from the immediate canonical predicate.
CREATE TABLE IF NOT EXISTS analytics.retention_policy
(
    singleton UInt8,
    revision UInt64,
    cutoff DateTime64(3, 'UTC')
)
ENGINE = ReplacingMergeTree(revision) ORDER BY singleton;
INSERT INTO analytics.retention_policy VALUES (1,0,'1970-01-01 00:00:00');
CREATE OR REPLACE VIEW analytics.events_canonical AS
SELECT *, properties_json, identity_context_key, context_json
FROM analytics.events_raw FINAL
WHERE occurred_at >= (SELECT argMax(cutoff,revision) FROM analytics.retention_policy);

-- Every raw-triggered projection filters the applied cutoff before updating state.
-- Keep the raw table inside the subquery so native insert-block triggers still fire.

DROP TABLE IF EXISTS analytics.mv_daily_event_counts;
CREATE MATERIALIZED VIEW analytics.mv_daily_event_counts TO analytics.daily_event_counts AS
SELECT account_id, toDate(occurred_at) AS day, event_name,
       uniqExactState(event_id) AS events
FROM (SELECT *, properties_json, identity_context_key, context_json FROM analytics.events_raw WHERE occurred_at >= (SELECT argMax(cutoff,revision) FROM analytics.retention_policy))
GROUP BY account_id, day, event_name;

DROP TABLE IF EXISTS analytics.mv_page_views_by_route;
CREATE MATERIALIZED VIEW analytics.mv_page_views_by_route TO analytics.page_views_by_route AS
SELECT account_id, toDate(occurred_at) AS day, path(url) AS route,
       uniqExactState(event_id) AS views
FROM (SELECT *, properties_json, identity_context_key, context_json FROM analytics.events_raw WHERE occurred_at >= (SELECT argMax(cutoff,revision) FROM analytics.retention_policy))
WHERE event_name = 'page_view'
GROUP BY account_id, day, route;

DROP TABLE IF EXISTS analytics.mv_identity_signals;
CREATE MATERIALIZED VIEW analytics.mv_identity_signals TO analytics.identity_signals AS
SELECT account_id, sig.1 AS signal_kind, sig.2 AS signal_value, user_id,
       occurred_at AS observed_at, event_id, received_at, source_service, session_id
FROM (SELECT *, properties_json, identity_context_key, context_json FROM analytics.events_raw WHERE occurred_at >= (SELECT argMax(cutoff,revision) FROM analytics.retention_policy))
ARRAY JOIN arrayDistinct(arrayFilter(kv -> kv.1 != '' AND kv.2 != '',
    arrayConcat([(if(event_name IN ('identify','identify_once','alias'), 'cookie', ''), anonymous_id)],
                JSONExtractKeysAndValues(identifiers, 'String')))) AS sig
WHERE user_id != '';

DROP TABLE IF EXISTS analytics.mv_identity_context_signals;
CREATE MATERIALIZED VIEW analytics.mv_identity_context_signals TO analytics.identity_context_signals AS
SELECT account_id,toDate(occurred_at) AS day,tuple(source_service,session_id,anonymous_id,identifiers) AS context_key,
       sig.1 AS signal_kind,sig.2 AS signal_value
FROM (SELECT *, properties_json, identity_context_key, context_json FROM analytics.events_raw WHERE occurred_at >= (SELECT argMax(cutoff,revision) FROM analytics.retention_policy))
ARRAY JOIN arrayDistinct(arrayFilter(kv -> kv.2!='',
    arrayConcat([('cookie',anonymous_id)],JSONExtractKeysAndValues(identifiers,'String')))) AS sig
WHERE user_id='';

DROP TABLE IF EXISTS analytics.mv_dau;
CREATE MATERIALIZED VIEW analytics.mv_dau TO analytics.dau AS
SELECT account_id, toDate(occurred_at) AS day, uniqCombinedState(if(user_id!='',concat('user:',user_id),concat('anonymous:',anonymous_id))) AS users
FROM (SELECT *, properties_json, identity_context_key, context_json FROM analytics.events_raw WHERE occurred_at >= (SELECT argMax(cutoff,revision) FROM analytics.retention_policy)) WHERE user_id != '' OR anonymous_id != ''
GROUP BY account_id, day;

DROP TABLE IF EXISTS analytics.mv_wau;
CREATE MATERIALIZED VIEW analytics.mv_wau TO analytics.wau AS
SELECT account_id, toMonday(occurred_at) AS week, uniqCombinedState(if(user_id!='',concat('user:',user_id),concat('anonymous:',anonymous_id))) AS users
FROM (SELECT *, properties_json, identity_context_key, context_json FROM analytics.events_raw WHERE occurred_at >= (SELECT argMax(cutoff,revision) FROM analytics.retention_policy)) WHERE user_id != '' OR anonymous_id != ''
GROUP BY account_id, week;

DROP TABLE IF EXISTS analytics.mv_experiment_exposures;
CREATE MATERIALIZED VIEW analytics.mv_experiment_exposures TO analytics.experiment_exposures AS
SELECT account_id, toDate(occurred_at) AS day, CAST(toString(getSubcolumn(properties_json, 'experiment')), 'String') AS experiment, CAST(toString(getSubcolumn(properties_json, 'variant')), 'String') AS variant, uniqCombinedState(if(user_id!='',concat('user:',user_id),concat('anonymous:',anonymous_id))) AS users
FROM (SELECT *, properties_json, identity_context_key, context_json FROM analytics.events_raw WHERE occurred_at >= (SELECT argMax(cutoff,revision) FROM analytics.retention_policy)) WHERE event_name = 'experiment_viewed' AND (user_id != '' OR anonymous_id != '') AND match(experiment, '^[a-z0-9_.:-]{1,128}$') AND match(variant, '^[a-z0-9_.:-]{1,128}$')
GROUP BY account_id, experiment, variant, day;

DROP TABLE IF EXISTS analytics.mv_sessions;
CREATE MATERIALIZED VIEW analytics.mv_sessions TO analytics.sessions AS
SELECT account_id,source_service,session_id,
       minState(occurred_at) AS started,
       maxState(occurred_at) AS ended,
       uniqExactIfState(event_id,event_name='page_view') AS page_ids,
       uniqExactIfState(event_id,event_name NOT IN ('page_view','session_start','page_leave','identify','identify_once','alias','group','experiment_viewed')) AS engagement_ids,
       argMinState(tuple(toString(event_name),toString(source),toString(url),toString(referrer),toString(utm_source),toString(utm_medium),toString(utm_campaign),toString(utm_content),toString(utm_term),toString(browser_family),toString(os_family),toString(device_class),toString(channel),toString(country_code),toString(properties)),tuple(occurred_at,event_id)) AS first_event,
       argMinIfState(tuple(toString(event_name),toString(source),toString(url),toString(referrer),toString(utm_source),toString(utm_medium),toString(utm_campaign),toString(utm_content),toString(utm_term),toString(browser_family),toString(os_family),toString(device_class),toString(channel),toString(country_code),toString(properties)),tuple(occurred_at,event_id),event_name='page_view') AS first_page,
       argMaxIfState(tuple(url),tuple(occurred_at,event_id),event_name='page_view') AS last_page,
       maxState(is_bot) AS bot
FROM (SELECT *, properties_json, identity_context_key, context_json FROM analytics.events_raw WHERE occurred_at >= (SELECT argMax(cutoff,revision) FROM analytics.retention_policy))
WHERE source='web' AND session_id!=''
GROUP BY account_id,source_service,session_id;

DROP TABLE IF EXISTS analytics.mv_user_properties;
CREATE MATERIALIZED VIEW analytics.mv_user_properties TO analytics.user_properties AS
SELECT account_id,user_id,name,argMaxState(tuple(trait_type,text_value,number_value),tuple(occurred_at,received_at,event_id)) AS value
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
  AND JSONHas(properties,trait.1)) WHERE event_name='identify' GROUP BY account_id,user_id,name;

DROP TABLE IF EXISTS analytics.mv_user_properties_once;
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
