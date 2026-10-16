

CREATE TABLE analytics.daily_event_counts
(
    account_id String,
    day        Date,
    event_name String,
    events     AggregateFunction(count)
)
ENGINE = AggregatingMergeTree
ORDER BY (account_id, day, event_name);