

INSERT INTO analytics.page_views_by_route (account_id, day, route, views)
SELECT
    account_id,
    toDate(occurred_at) AS day,
    path(url) AS route,
    countState() AS views
FROM analytics.events_raw
WHERE event_name = 'page_view'
GROUP BY account_id, day, route;