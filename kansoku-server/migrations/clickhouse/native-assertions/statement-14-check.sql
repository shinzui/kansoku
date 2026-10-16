INSERT INTO analytics.__chm_legacy_assert_0017_14


SELECT throwIf(count() > 0, 'canonical page-view rebuild mismatch')
FROM
(
    SELECT account_id, toDate(occurred_at) AS day, path(url) AS route, count() AS n
    FROM analytics.events_canonical WHERE event_name = 'page_view'
    GROUP BY account_id, day, route
) AS canonical
FULL OUTER JOIN
(
    SELECT account_id, day, route, uniqExactMerge(views) AS n
    FROM analytics.page_views_by_route_rebuild GROUP BY account_id, day, route
) AS replacement USING (account_id, day, route)
WHERE ifNull(canonical.n, 0) != ifNull(replacement.n, 0);