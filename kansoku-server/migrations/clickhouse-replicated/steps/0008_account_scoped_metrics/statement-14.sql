

CREATE TABLE analytics.page_views_by_route
(
    account_id String,
    day        Date,
    route      String,
    views      AggregateFunction(count)
)
ENGINE = ReplicatedAggregatingMergeTree
ORDER BY (account_id, day, route);