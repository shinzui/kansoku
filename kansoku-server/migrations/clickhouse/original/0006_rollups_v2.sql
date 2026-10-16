-- Rollup states v2: bounded-size states instead of exact-distinct states that
-- stored every id. events/views: AggregateFunction(uniqExact, String) over
-- event_id -> AggregateFunction(count) (dedup makes duplicate rows rare and
-- transient, so count-vs-distinct drift is negligible; exactness lives in the
-- raw table). dau/wau users: uniqExact -> uniqCombined sketch (~0.8% error at
-- scale, exact for small sets). Tables are rebuilt (state types cannot be
-- ALTERed) and backfilled from events_raw.

DROP TABLE IF EXISTS analytics.mv_daily_event_counts;
DROP TABLE IF EXISTS analytics.mv_dau;
DROP TABLE IF EXISTS analytics.mv_wau;
DROP TABLE IF EXISTS analytics.mv_page_views_by_route;
DROP TABLE IF EXISTS analytics.daily_event_counts;
DROP TABLE IF EXISTS analytics.dau;
DROP TABLE IF EXISTS analytics.wau;
DROP TABLE IF EXISTS analytics.page_views_by_route;

CREATE TABLE analytics.daily_event_counts
(
    day        Date,
    event_name String,
    events     AggregateFunction(count)
)
ENGINE = AggregatingMergeTree
ORDER BY (day, event_name);

CREATE TABLE analytics.dau
(
    day   Date,
    users AggregateFunction(uniqCombined, String)
)
ENGINE = AggregatingMergeTree
ORDER BY day;

CREATE TABLE analytics.wau
(
    week  Date,
    users AggregateFunction(uniqCombined, String)
)
ENGINE = AggregatingMergeTree
ORDER BY week;

CREATE TABLE analytics.page_views_by_route
(
    day   Date,
    route String,
    views AggregateFunction(count)
)
ENGINE = AggregatingMergeTree
ORDER BY (day, route);

-- Backfill from the (already deduplicated-by-merges) raw table.
INSERT INTO analytics.daily_event_counts (day, event_name, events)
SELECT
    toDate(occurred_at) AS day,
    event_name AS event_name,
    countState() AS events
FROM analytics.events_raw
GROUP BY day, event_name;

INSERT INTO analytics.dau (day, users)
SELECT
    toDate(occurred_at) AS day,
    uniqCombinedState(if(user_id != '', user_id, anonymous_id)) AS users
FROM analytics.events_raw
WHERE user_id != '' OR anonymous_id != ''
GROUP BY day;

INSERT INTO analytics.wau (week, users)
SELECT
    toMonday(occurred_at) AS week,
    uniqCombinedState(if(user_id != '', user_id, anonymous_id)) AS users
FROM analytics.events_raw
WHERE user_id != '' OR anonymous_id != ''
GROUP BY week;

INSERT INTO analytics.page_views_by_route (day, route, views)
SELECT
    toDate(occurred_at) AS day,
    path(url) AS route,
    countState() AS views
FROM analytics.events_raw
WHERE event_name = 'page_view'
GROUP BY day, route;

CREATE MATERIALIZED VIEW analytics.mv_daily_event_counts
TO analytics.daily_event_counts
AS
SELECT
    toDate(occurred_at) AS day,
    event_name AS event_name,
    countState() AS events
FROM analytics.events_raw
GROUP BY day, event_name;

CREATE MATERIALIZED VIEW analytics.mv_dau
TO analytics.dau
AS
SELECT
    toDate(occurred_at) AS day,
    uniqCombinedState(if(user_id != '', user_id, anonymous_id)) AS users
FROM analytics.events_raw
WHERE user_id != '' OR anonymous_id != ''
GROUP BY day;

CREATE MATERIALIZED VIEW analytics.mv_wau
TO analytics.wau
AS
SELECT
    toMonday(occurred_at) AS week,
    uniqCombinedState(if(user_id != '', user_id, anonymous_id)) AS users
FROM analytics.events_raw
WHERE user_id != '' OR anonymous_id != ''
GROUP BY week;

CREATE MATERIALIZED VIEW analytics.mv_page_views_by_route
TO analytics.page_views_by_route
AS
SELECT
    toDate(occurred_at) AS day,
    path(url) AS route,
    countState() AS views
FROM analytics.events_raw
WHERE event_name = 'page_view'
GROUP BY day, route;
