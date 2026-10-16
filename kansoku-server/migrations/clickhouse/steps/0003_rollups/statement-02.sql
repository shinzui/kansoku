

-- ---------- Daily event counts, by event_name ----------
CREATE TABLE IF NOT EXISTS analytics.daily_event_counts
(
    day        Date,
    event_name String,
    events     AggregateFunction(uniqExact, String)
)
ENGINE = AggregatingMergeTree
ORDER BY (day, event_name);