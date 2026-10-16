

INSERT INTO analytics.daily_event_counts_rebuild
SELECT account_id, toDate(occurred_at) AS day, event_name,
       uniqExactState(event_id) AS events
FROM analytics.events_canonical
GROUP BY account_id, day, event_name;