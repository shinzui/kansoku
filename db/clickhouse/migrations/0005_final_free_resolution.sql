-- FINAL-free identity resolution and join-free DAU/WAU.
-- events_resolved consumers aggregate with uniqExact/min, which are
-- insensitive to the transient duplicate rows FINAL would remove; row-COUNT
-- consumers must protect themselves (count DISTINCT event_id).
-- mv_dau/mv_wau stop joining the identity map at insert time and count raw
-- identities (user_id if present, else anonymous_id); the stitched number
-- stays available at query time through events_resolved.

DROP VIEW IF EXISTS analytics.events_resolved;

CREATE VIEW analytics.events_resolved
AS
SELECT
    e.event_id AS event_id,
    e.event_name AS event_name,
    e.occurred_at AS occurred_at,
    e.url AS url,
    coalesce(nullIf(e.user_id, ''), nullIf(m.user_id, ''), nullIf(e.anonymous_id, ''), '') AS canonical_user
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

DROP TABLE IF EXISTS analytics.mv_dau;
DROP TABLE IF EXISTS analytics.mv_wau;

-- Rebuild dau/wau contents under the new (raw-identity) semantics so the
-- tables are not a mix of stitched and unstitched day states. Column types
-- are unchanged in this migration (still AggregateFunction(uniqExact, String));
-- 0006 replaces the state type.
TRUNCATE TABLE analytics.dau;
TRUNCATE TABLE analytics.wau;

INSERT INTO analytics.dau (day, users)
SELECT
    toDate(occurred_at) AS day,
    uniqExactState(if(user_id != '', user_id, anonymous_id)) AS users
FROM analytics.events_raw
WHERE user_id != '' OR anonymous_id != ''
GROUP BY day;

INSERT INTO analytics.wau (week, users)
SELECT
    toMonday(occurred_at) AS week,
    uniqExactState(if(user_id != '', user_id, anonymous_id)) AS users
FROM analytics.events_raw
WHERE user_id != '' OR anonymous_id != ''
GROUP BY week;

CREATE MATERIALIZED VIEW analytics.mv_dau
TO analytics.dau
AS
SELECT
    toDate(occurred_at) AS day,
    uniqExactState(if(user_id != '', user_id, anonymous_id)) AS users
FROM analytics.events_raw
WHERE user_id != '' OR anonymous_id != ''
GROUP BY day;

CREATE MATERIALIZED VIEW analytics.mv_wau
TO analytics.wau
AS
SELECT
    toMonday(occurred_at) AS week,
    uniqExactState(if(user_id != '', user_id, anonymous_id)) AS users
FROM analytics.events_raw
WHERE user_id != '' OR anonymous_id != ''
GROUP BY week;
