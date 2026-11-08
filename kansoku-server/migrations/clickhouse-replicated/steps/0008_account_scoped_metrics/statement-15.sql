

INSERT INTO analytics.daily_event_counts (account_id, day, event_name, events)
SELECT
    account_id,
    toDate(occurred_at) AS day,
    event_name AS event_name,
    countState() AS events
FROM analytics.events_raw
GROUP BY account_id, day, event_name;