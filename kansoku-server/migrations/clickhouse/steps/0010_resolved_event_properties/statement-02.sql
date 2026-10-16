

CREATE VIEW analytics.events_resolved
AS
SELECT
    e.event_id AS event_id,
    e.event_name AS event_name,
    e.occurred_at AS occurred_at,
    e.url AS url,
    e.account_id AS account_id,
    coalesce(nullIf(e.user_id, ''), nullIf(m.user_id, ''), nullIf(e.anonymous_id, ''), '') AS canonical_user,
    e.properties_json AS properties_json
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
