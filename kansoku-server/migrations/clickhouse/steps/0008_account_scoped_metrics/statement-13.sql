

CREATE TABLE analytics.wau
(
    account_id String,
    week       Date,
    users      AggregateFunction(uniqCombined, String)
)
ENGINE = AggregatingMergeTree
ORDER BY (account_id, week);