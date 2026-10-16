

INSERT INTO analytics.page_views_by_route (day, route, views)
SELECT
    toDate(occurred_at) AS day,
    path(url) AS route,
    countState() AS views
FROM analytics.events_raw
WHERE event_name = 'page_view'
GROUP BY day, route;