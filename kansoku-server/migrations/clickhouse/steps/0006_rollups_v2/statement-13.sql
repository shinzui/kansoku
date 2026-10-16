

-- Backfill from the (already deduplicated-by-merges) raw table.
INSERT INTO analytics.daily_event_counts (day, event_name, events)
SELECT
    toDate(occurred_at) AS day,
    event_name AS event_name,
    countState() AS events
FROM analytics.events_raw
GROUP BY day, event_name;