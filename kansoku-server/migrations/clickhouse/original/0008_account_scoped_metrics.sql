-- Account-scoped metrics. Keep the FINAL-free identity resolution and the
-- bounded v2 aggregate states while adding account_id to every query source.

DROP VIEW IF EXISTS analytics.events_resolved;

CREATE VIEW analytics.events_resolved
AS
SELECT
    e.event_id AS event_id,
    e.event_name AS event_name,
    e.occurred_at AS occurred_at,
    e.url AS url,
    e.account_id AS account_id,
    coalesce(nullIf(e.user_id, ''), nullIf(m.user_id, ''), nullIf(e.anonymous_id, ''), '') AS canonical_user
FROM analytics.events_raw AS e
LEFT JOIN
(
    SELECT
        anonymous_id,
        argMax(user_id, version) AS user_id
    FROM analytics.identity_map
    GROUP BY anonymous_id
) AS m
ON e.anonymous_id = m.anonymous_id;

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
    account_id String,
    day        Date,
    event_name String,
    events     AggregateFunction(count)
)
ENGINE = AggregatingMergeTree
ORDER BY (account_id, day, event_name);

CREATE TABLE analytics.dau
(
    account_id String,
    day        Date,
    users      AggregateFunction(uniqCombined, String)
)
ENGINE = AggregatingMergeTree
ORDER BY (account_id, day);

CREATE TABLE analytics.wau
(
    account_id String,
    week       Date,
    users      AggregateFunction(uniqCombined, String)
)
ENGINE = AggregatingMergeTree
ORDER BY (account_id, week);

CREATE TABLE analytics.page_views_by_route
(
    account_id String,
    day        Date,
    route      String,
    views      AggregateFunction(count)
)
ENGINE = AggregatingMergeTree
ORDER BY (account_id, day, route);

INSERT INTO analytics.daily_event_counts (account_id, day, event_name, events)
SELECT
    account_id,
    toDate(occurred_at) AS day,
    event_name AS event_name,
    countState() AS events
FROM analytics.events_raw
GROUP BY account_id, day, event_name;

INSERT INTO analytics.dau (account_id, day, users)
SELECT
    account_id,
    toDate(occurred_at) AS day,
    uniqCombinedState(if(user_id != '', user_id, anonymous_id)) AS users
FROM analytics.events_raw
WHERE user_id != '' OR anonymous_id != ''
GROUP BY account_id, day;

INSERT INTO analytics.wau (account_id, week, users)
SELECT
    account_id,
    toMonday(occurred_at) AS week,
    uniqCombinedState(if(user_id != '', user_id, anonymous_id)) AS users
FROM analytics.events_raw
WHERE user_id != '' OR anonymous_id != ''
GROUP BY account_id, week;

INSERT INTO analytics.page_views_by_route (account_id, day, route, views)
SELECT
    account_id,
    toDate(occurred_at) AS day,
    path(url) AS route,
    countState() AS views
FROM analytics.events_raw
WHERE event_name = 'page_view'
GROUP BY account_id, day, route;

CREATE MATERIALIZED VIEW analytics.mv_daily_event_counts
TO analytics.daily_event_counts
AS
SELECT
    account_id,
    toDate(occurred_at) AS day,
    event_name AS event_name,
    countState() AS events
FROM analytics.events_raw
GROUP BY account_id, day, event_name;

CREATE MATERIALIZED VIEW analytics.mv_dau
TO analytics.dau
AS
SELECT
    account_id,
    toDate(occurred_at) AS day,
    uniqCombinedState(if(user_id != '', user_id, anonymous_id)) AS users
FROM analytics.events_raw
WHERE user_id != '' OR anonymous_id != ''
GROUP BY account_id, day;

CREATE MATERIALIZED VIEW analytics.mv_wau
TO analytics.wau
AS
SELECT
    account_id,
    toMonday(occurred_at) AS week,
    uniqCombinedState(if(user_id != '', user_id, anonymous_id)) AS users
FROM analytics.events_raw
WHERE user_id != '' OR anonymous_id != ''
GROUP BY account_id, week;

CREATE MATERIALIZED VIEW analytics.mv_page_views_by_route
TO analytics.page_views_by_route
AS
SELECT
    account_id,
    toDate(occurred_at) AS day,
    path(url) AS route,
    countState() AS views
FROM analytics.events_raw
WHERE event_name = 'page_view'
GROUP BY account_id, day, route;
