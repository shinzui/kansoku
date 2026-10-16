

CREATE TABLE analytics.daily_event_counts_rebuild
(
    account_id String,
    day Date,
    event_name String,
    events AggregateFunction(uniqExact, String)
)
ENGINE = AggregatingMergeTree
ORDER BY (account_id, day, event_name);