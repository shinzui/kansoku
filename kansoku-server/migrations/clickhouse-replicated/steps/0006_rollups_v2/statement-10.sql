

CREATE TABLE analytics.dau
(
    day   Date,
    users AggregateFunction(uniqCombined, String)
)
ENGINE = ReplicatedAggregatingMergeTree
ORDER BY day;