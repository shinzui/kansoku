INSERT INTO analytics.__session_engagement_check
SELECT throwIf(mismatches > 0, 'canonical retained session rebuild mismatch') FROM (
SELECT count() AS mismatches FROM (
(SELECT * FROM (SELECT account_id,source_service,session_id,
       min(occurred_at) AS started,
       max(occurred_at) AS ended,
       uniqExactIf(event_id,event_name='page_view') AS page_ids,
       uniqExactIf(event_id,event_name NOT IN ('page_view','session_start','page_leave','identify','identify_once','alias','group','experiment_viewed','client_error','web_vital')) AS engagement_ids,
       argMin(tuple(toString(event_name),toString(source),toString(url),toString(referrer),toString(utm_source),toString(utm_medium),toString(utm_campaign),toString(utm_content),toString(utm_term),toString(browser_family),toString(os_family),toString(device_class),toString(channel),toString(country_code),toString(properties)),tuple(occurred_at,event_id)) AS first_event,
       argMinIf(tuple(toString(event_name),toString(source),toString(url),toString(referrer),toString(utm_source),toString(utm_medium),toString(utm_campaign),toString(utm_content),toString(utm_term),toString(browser_family),toString(os_family),toString(device_class),toString(channel),toString(country_code),toString(properties)),tuple(occurred_at,event_id),event_name='page_view') AS first_page,
       argMaxIf(tuple(url),tuple(occurred_at,event_id),event_name='page_view') AS last_page,
       max(is_bot) AS bot
FROM (SELECT *, properties_json, identity_context_key, context_json FROM analytics.events_canonical WHERE occurred_at >= (SELECT argMax(cutoff,revision) FROM analytics.retention_policy))
WHERE source='web' AND session_id!=''
GROUP BY account_id,source_service,session_id) EXCEPT DISTINCT SELECT * FROM (SELECT account_id,source_service,session_id,
       minMerge(started) AS started,
       maxMerge(ended) AS ended,
       uniqExactIfMerge(page_ids) AS page_ids,
       uniqExactIfMerge(engagement_ids) AS engagement_ids,
       argMinMerge(first_event) AS first_event,
       argMinIfMerge(first_page) AS first_page,
       argMaxIfMerge(last_page) AS last_page,
       maxMerge(bot) AS bot
FROM analytics.sessions GROUP BY account_id,source_service,session_id))
UNION ALL
(SELECT * FROM (SELECT account_id,source_service,session_id,
       minMerge(started) AS started,
       maxMerge(ended) AS ended,
       uniqExactIfMerge(page_ids) AS page_ids,
       uniqExactIfMerge(engagement_ids) AS engagement_ids,
       argMinMerge(first_event) AS first_event,
       argMinIfMerge(first_page) AS first_page,
       argMaxIfMerge(last_page) AS last_page,
       maxMerge(bot) AS bot
FROM analytics.sessions GROUP BY account_id,source_service,session_id) EXCEPT DISTINCT SELECT * FROM (SELECT account_id,source_service,session_id,
       min(occurred_at) AS started,
       max(occurred_at) AS ended,
       uniqExactIf(event_id,event_name='page_view') AS page_ids,
       uniqExactIf(event_id,event_name NOT IN ('page_view','session_start','page_leave','identify','identify_once','alias','group','experiment_viewed','client_error','web_vital')) AS engagement_ids,
       argMin(tuple(toString(event_name),toString(source),toString(url),toString(referrer),toString(utm_source),toString(utm_medium),toString(utm_campaign),toString(utm_content),toString(utm_term),toString(browser_family),toString(os_family),toString(device_class),toString(channel),toString(country_code),toString(properties)),tuple(occurred_at,event_id)) AS first_event,
       argMinIf(tuple(toString(event_name),toString(source),toString(url),toString(referrer),toString(utm_source),toString(utm_medium),toString(utm_campaign),toString(utm_content),toString(utm_term),toString(browser_family),toString(os_family),toString(device_class),toString(channel),toString(country_code),toString(properties)),tuple(occurred_at,event_id),event_name='page_view') AS first_page,
       argMaxIf(tuple(url),tuple(occurred_at,event_id),event_name='page_view') AS last_page,
       max(is_bot) AS bot
FROM (SELECT *, properties_json, identity_context_key, context_json FROM analytics.events_canonical WHERE occurred_at >= (SELECT argMax(cutoff,revision) FROM analytics.retention_policy))
WHERE source='web' AND session_id!=''
GROUP BY account_id,source_service,session_id))
)
) SETTINGS max_result_rows=0,max_result_bytes=0,result_overflow_mode='throw',read_overflow_mode='throw';
