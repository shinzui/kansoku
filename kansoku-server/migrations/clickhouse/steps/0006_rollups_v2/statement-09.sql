

CREATE TABLE analytics.daily_event_counts
(
    day        Date,
    event_name String,
    events     AggregateFunction(count)
)
ENGINE = AggregatingMergeTree
ORDER BY (day, event_name);