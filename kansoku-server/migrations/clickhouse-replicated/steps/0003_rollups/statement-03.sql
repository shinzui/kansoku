

CREATE MATERIALIZED VIEW IF NOT EXISTS analytics.mv_daily_event_counts
TO analytics.daily_event_counts
AS
SELECT
    toDate(occurred_at) AS day,
    event_name AS event_name,
    uniqExactState(toString(event_id)) AS events
FROM analytics.events_raw
GROUP BY day, event_name;