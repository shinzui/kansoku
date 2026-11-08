

CREATE TABLE analytics.wau
(
    account_id String,
    week       Date,
    users      AggregateFunction(uniqCombined, String)
)
ENGINE = ReplicatedAggregatingMergeTree
ORDER BY (account_id, week);