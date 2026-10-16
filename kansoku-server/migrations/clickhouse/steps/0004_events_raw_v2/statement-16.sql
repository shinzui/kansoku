

CREATE MATERIALIZED VIEW analytics.mv_page_views_by_route
TO analytics.page_views_by_route
AS
SELECT
    toDate(occurred_at) AS day,
    path(url) AS route,
    uniqExactState(toString(event_id)) AS views
FROM analytics.events_raw
WHERE event_name = 'page_view'
GROUP BY day, route;
