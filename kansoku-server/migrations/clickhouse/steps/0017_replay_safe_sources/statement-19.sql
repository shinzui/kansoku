

-- Trigger inputs are the current inserted block. Distinct-ID states compose
-- across arbitrary retry batches, parts, restarts and old archive replays.
CREATE MATERIALIZED VIEW analytics.mv_daily_event_counts
TO analytics.daily_event_counts AS
SELECT account_id, toDate(occurred_at) AS day, event_name,
       uniqExactState(event_id) AS events
FROM analytics.events_raw
GROUP BY account_id, day, event_name;