

CREATE TABLE analytics.page_views_by_route_rebuild
(
    account_id String,
    day Date,
    route String,
    views AggregateFunction(uniqExact, String)
)
ENGINE = AggregatingMergeTree
ORDER BY (account_id, day, route);