

CREATE TABLE analytics.wau
(
    week  Date,
    users AggregateFunction(uniqCombined, String)
)
ENGINE = AggregatingMergeTree
ORDER BY week;