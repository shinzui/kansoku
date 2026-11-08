

CREATE TABLE analytics.wau
(
    week  Date,
    users AggregateFunction(uniqCombined, String)
)
ENGINE = ReplicatedAggregatingMergeTree
ORDER BY week;