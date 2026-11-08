

-- Query-time resolution: every raw event with its canonical user id.
-- Reads events_raw FINAL so duplicate raw rows collapse before row-level use.
-- The subquery collapses identity_map to the latest user_id per anonymous_id.
-- NOTE: nullIf(m.user_id, '') is load-bearing. With ClickHouse's default
-- join_use_nulls = 0, a LEFT JOIN miss fills m.user_id with '' (NOT NULL);
-- without the nullIf, coalesce would stop there and never reach the
-- anonymous-id fallback. The trailing '' keeps the type plain String.
CREATE VIEW IF NOT EXISTS analytics.events_resolved
AS
SELECT
    e.event_id AS event_id,
    e.event_name AS event_name,
    e.occurred_at AS occurred_at,
    e.url AS url,
    coalesce(nullIf(e.user_id, ''), nullIf(m.user_id, ''), nullIf(e.anonymous_id, ''), '') AS canonical_user
FROM analytics.events_raw AS e FINAL
LEFT JOIN
(
    SELECT
        anonymous_id,
        argMax(user_id, version) AS user_id
    FROM analytics.identity_map
    GROUP BY anonymous_id
) AS m
ON e.anonymous_id = m.anonymous_id;
