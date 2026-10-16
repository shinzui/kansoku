
CREATE MATERIALIZED VIEW analytics.mv_daily_event_counts TO analytics.daily_event_counts AS
SELECT account_id, toDate(occurred_at) AS day, event_name,
       uniqExactState(event_id) AS events
FROM (SELECT *, properties_json, identity_context_key, context_json FROM analytics.events_raw WHERE occurred_at >= (SELECT argMax(cutoff,revision) FROM analytics.retention_policy))
GROUP BY account_id, day, event_name;