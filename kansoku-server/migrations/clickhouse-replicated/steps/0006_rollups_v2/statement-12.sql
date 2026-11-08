

CREATE TABLE analytics.page_views_by_route
(
    day   Date,
    route String,
    views AggregateFunction(count)
)
ENGINE = ReplicatedAggregatingMergeTree
ORDER BY (day, route);