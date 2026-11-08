

CREATE MATERIALIZED VIEW analytics.mv_page_views_by_route
TO analytics.page_views_by_route AS
SELECT account_id, toDate(occurred_at) AS day, path(url) AS route,
       uniqExactState(event_id) AS views
FROM analytics.events_raw
WHERE event_name = 'page_view'
GROUP BY account_id, day, route;
