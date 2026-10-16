

CREATE TABLE analytics.dau
(
    account_id String,
    day        Date,
    users      AggregateFunction(uniqCombined, String)
)
ENGINE = AggregatingMergeTree
ORDER BY (account_id, day);