

CREATE TABLE analytics.daily_event_counts
(
    day        Date,
    event_name String,
    events     AggregateFunction(count)
)
ENGINE = ReplicatedAggregatingMergeTree
ORDER BY (day, event_name);