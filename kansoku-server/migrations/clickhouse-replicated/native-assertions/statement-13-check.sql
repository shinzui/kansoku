INSERT INTO analytics.__chm_legacy_assert_0017_13


-- Verify complete replacement groups before publishing either table.
SELECT throwIf(count() > 0, 'canonical daily-event rebuild mismatch')
FROM
(
    SELECT account_id, toDate(occurred_at) AS day, event_name, count() AS n
    FROM analytics.events_canonical GROUP BY account_id, day, event_name
) AS canonical
FULL OUTER JOIN
(
    SELECT account_id, day, event_name, uniqExactMerge(events) AS n
    FROM analytics.daily_event_counts_rebuild GROUP BY account_id, day, event_name
) AS replacement USING (account_id, day, event_name)
WHERE ifNull(canonical.n, 0) != ifNull(replacement.n, 0);