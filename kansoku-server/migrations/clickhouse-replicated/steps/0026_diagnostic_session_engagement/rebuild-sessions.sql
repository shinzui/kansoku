INSERT INTO analytics.sessions
SELECT account_id,source_service,session_id,
       minState(occurred_at) AS started,
       maxState(occurred_at) AS ended,
       uniqExactIfState(event_id,event_name='page_view') AS page_ids,
       uniqExactIfState(event_id,event_name NOT IN ('page_view','session_start','page_leave','identify','identify_once','alias','group','experiment_viewed','client_error','web_vital')) AS engagement_ids,
       argMinState(tuple(toString(event_name),toString(source),toString(url),toString(referrer),toString(utm_source),toString(utm_medium),toString(utm_campaign),toString(utm_content),toString(utm_term),toString(browser_family),toString(os_family),toString(device_class),toString(channel),toString(country_code),toString(properties)),tuple(occurred_at,event_id)) AS first_event,
       argMinIfState(tuple(toString(event_name),toString(source),toString(url),toString(referrer),toString(utm_source),toString(utm_medium),toString(utm_campaign),toString(utm_content),toString(utm_term),toString(browser_family),toString(os_family),toString(device_class),toString(channel),toString(country_code),toString(properties)),tuple(occurred_at,event_id),event_name='page_view') AS first_page,
       argMaxIfState(tuple(url),tuple(occurred_at,event_id),event_name='page_view') AS last_page,
       maxState(is_bot) AS bot
FROM (SELECT *, properties_json, identity_context_key, context_json FROM analytics.events_canonical WHERE occurred_at >= (SELECT argMax(cutoff,revision) FROM analytics.retention_policy))
WHERE source='web' AND session_id!=''
GROUP BY account_id,source_service,session_id
SETTINGS insert_deduplicate=0,deduplicate_blocks_in_dependent_materialized_views=0,max_result_rows=0,max_result_bytes=0,result_overflow_mode='throw',read_overflow_mode='throw';
