

-- Still joining the identity map here; 0005 replaces these two MVs.
CREATE MATERIALIZED VIEW analytics.mv_dau
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