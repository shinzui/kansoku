CREATE DATABASE IF NOT EXISTS analytics;

-- ---------- Daily event counts, by event_name ----------
CREATE TABLE IF NOT EXISTS analytics.daily_event_counts
(
    day        Date,
    event_name String,
    events     AggregateFunction(uniqExact, String)
)
ENGINE = AggregatingMergeTree
ORDER BY (day, event_name);

CREATE MATERIALIZED VIEW IF NOT EXISTS analytics.mv_daily_event_counts
TO analytics.daily_event_counts
AS
SELECT
    toDate(occurred_at) AS day,
    event_name AS event_name,
    uniqExactState(toString(event_id)) AS events
FROM analytics.events_raw
GROUP BY day, event_name;

-- ---------- Daily active users (canonical, resolved at insert time) ----------
-- NOTE: nullIf(m.user_id, '') is load-bearing (join_use_nulls = 0 fills a LEFT
-- JOIN miss with '', not NULL); the trailing '' keeps the argument a plain
-- String so the state stays AggregateFunction(uniqExact, String).
CREATE TABLE IF NOT EXISTS analytics.dau
(
    day   Date,
    users AggregateFunction(uniqExact, String)
)
ENGINE = AggregatingMergeTree
ORDER BY day;

CREATE MATERIALIZED VIEW IF NOT EXISTS analytics.mv_dau
TO analytics.dau
AS
SELECT
    toDate(e.occurred_at) AS day,
    uniqExactState(coalesce(nullIf(e.user_id, ''), nullIf(m.user_id, ''), nullIf(e.anonymous_id, ''), '')) AS users
FROM analytics.events_raw AS e
LEFT JOIN
(
    SELECT
        anonymous_id,
        argMax(user_id, version) AS user_id
    FROM analytics.identity_map
    GROUP BY anonymous_id
) AS m
ON e.anonymous_id = m.anonymous_id
WHERE coalesce(nullIf(e.user_id, ''), nullIf(m.user_id, ''), nullIf(e.anonymous_id, ''), '') != ''
GROUP BY day;

-- ---------- Weekly active users (canonical), keyed on the Monday of the week ----------
CREATE TABLE IF NOT EXISTS analytics.wau
(
    week  Date,
    users AggregateFunction(uniqExact, String)
)
ENGINE = AggregatingMergeTree
ORDER BY week;

CREATE MATERIALIZED VIEW IF NOT EXISTS analytics.mv_wau
TO analytics.wau
AS
SELECT
    toMonday(e.occurred_at) AS week,
    uniqExactState(coalesce(nullIf(e.user_id, ''), nullIf(m.user_id, ''), nullIf(e.anonymous_id, ''), '')) AS users
FROM analytics.events_raw AS e
LEFT JOIN
(
    SELECT
        anonymous_id,
        argMax(user_id, version) AS user_id
    FROM analytics.identity_map
    GROUP BY anonymous_id
) AS m
ON e.anonymous_id = m.anonymous_id
WHERE coalesce(nullIf(e.user_id, ''), nullIf(m.user_id, ''), nullIf(e.anonymous_id, ''), '') != ''
GROUP BY week;

-- ---------- Page views by route ----------
-- url is Nullable(String) in EP-3's schema; coalesce(url, '') keeps path()
-- non-Nullable so the insert into the String route column cannot fail.
CREATE TABLE IF NOT EXISTS analytics.page_views_by_route
(
    day   Date,
    route String,
    views AggregateFunction(uniqExact, String)
)
ENGINE = AggregatingMergeTree
ORDER BY (day, route);

CREATE MATERIALIZED VIEW IF NOT EXISTS analytics.mv_page_views_by_route
TO analytics.page_views_by_route
AS
SELECT
    toDate(occurred_at) AS day,
    path(coalesce(url, '')) AS route,
    uniqExactState(toString(event_id)) AS views
FROM analytics.events_raw
WHERE event_name = 'page_view'
GROUP BY day, route;
