

INSERT INTO analytics.page_views_by_route_rebuild
SELECT account_id, toDate(occurred_at) AS day, path(url) AS route,
       uniqExactState(event_id) AS views
FROM analytics.events_canonical
WHERE event_name = 'page_view'
GROUP BY account_id, day, route;