

CREATE TABLE analytics.dau
(
    day   Date,
    users AggregateFunction(uniqCombined, String)
)
ENGINE = AggregatingMergeTree
ORDER BY day;