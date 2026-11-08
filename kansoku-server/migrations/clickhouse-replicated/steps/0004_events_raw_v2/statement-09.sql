

INSERT INTO analytics.events_raw_v2
    (event_id, event_name, source, source_service, occurred_at, received_at,
     anonymous_id, user_id, organization_id, account_id, session_id, url,
     referrer, utm_source, utm_medium, utm_campaign, utm_content, utm_term,
     correlation_id, causation_id, source_event_id, source_global_position,
     properties, context)
SELECT
    event_id, event_name, source, coalesce(source_service, ''), occurred_at,
    received_at, coalesce(anonymous_id, ''), user_id,
    coalesce(organization_id, ''), account_id, coalesce(session_id, ''),
    coalesce(url, ''), coalesce(referrer, ''), coalesce(utm_source, ''),
    coalesce(utm_medium, ''), coalesce(utm_campaign, ''),
    coalesce(utm_content, ''), coalesce(utm_term, ''),
    coalesce(correlation_id, ''), coalesce(causation_id, ''),
    coalesce(source_event_id, ''), source_global_position, properties, context
FROM analytics.events_raw;