-- EP-30: one immutable logical event before analytical joins/aggregations.
-- Administrative migration: keep the writer stopped throughout. A failed run
-- can be reapplied: replacement states are rebuilt from canonical retained rows,
-- rather than appended to partially populated aggregate tables.
CREATE OR REPLACE VIEW analytics.events_canonical
AS SELECT *, properties_json FROM analytics.events_raw FINAL;

CREATE OR REPLACE VIEW analytics.identity_bindings
AS
SELECT
    account_id,
    signal_kind,
    signal_value,
    user_id,
    observed_at,
    multiIf(
        signal_kind = 'email_sha256', 0.95,
        signal_kind = 'cookie',       0.90,
        signal_kind = 'device',       0.80,
        signal_kind = 'fingerprint',  0.50,
        0.0) AS confidence
FROM analytics.identity_signals FINAL;

-- Conflicting bindings stay visible rather than being collapsed by a
-- latest-wins table.
CREATE OR REPLACE VIEW analytics.identity_conflicts
AS
SELECT
    account_id,
    signal_kind,
    signal_value,
    groupUniqArray(user_id) AS user_ids,
    uniqExact(user_id) AS user_count,
    count() AS observation_count,
    max(observed_at) AS last_observed_at
FROM analytics.identity_signals FINAL
GROUP BY account_id, signal_kind, signal_value
HAVING user_count > 1;

CREATE OR REPLACE VIEW analytics.events_resolved_v3
AS
WITH event_signal_users AS
(
    SELECT
        s.account_id AS account_id,
        s.event_id AS event_id,
        argMax(b.user_id, tuple(b.confidence, b.observed_at)) AS stitched_user
    FROM
    (
        SELECT
            account_id,
            event_id,
            sig.1 AS signal_kind,
            sig.2 AS signal_value
        FROM analytics.events_canonical
        ARRAY JOIN arrayFilter(
            kv -> kv.2 != '',
            arrayConcat(
                [('cookie', anonymous_id)],
                JSONExtractKeysAndValues(identifiers, 'String'))) AS sig
        WHERE user_id = ''
    ) AS s
    INNER JOIN analytics.identity_bindings AS b
        ON  b.account_id = s.account_id
        AND b.signal_kind = s.signal_kind
        AND b.signal_value = s.signal_value
    WHERE b.confidence >= 0.50
    GROUP BY s.account_id, s.event_id
)
SELECT
    e.event_id AS event_id,
    e.event_name AS event_name,
    e.occurred_at AS occurred_at,
    e.url AS url,
    e.account_id AS account_id,
    multiIf(
        e.user_id != '', e.user_id,
        r.stitched_user != '', r.stitched_user,
        e.anonymous_id) AS canonical_user,
    e.properties_json AS properties_json
FROM analytics.events_canonical AS e
LEFT JOIN event_signal_users AS r
    ON r.account_id = e.account_id AND r.event_id = e.event_id;


DROP TABLE IF EXISTS analytics.mv_daily_event_counts;
DROP TABLE IF EXISTS analytics.mv_page_views_by_route;
DROP TABLE IF EXISTS analytics.daily_event_counts_rebuild;
DROP TABLE IF EXISTS analytics.page_views_by_route_rebuild;

CREATE TABLE analytics.daily_event_counts_rebuild
(
    account_id String,
    day Date,
    event_name String,
    events AggregateFunction(uniqExact, String)
)
ENGINE = AggregatingMergeTree
ORDER BY (account_id, day, event_name);

CREATE TABLE analytics.page_views_by_route_rebuild
(
    account_id String,
    day Date,
    route String,
    views AggregateFunction(uniqExact, String)
)
ENGINE = AggregatingMergeTree
ORDER BY (account_id, day, route);

INSERT INTO analytics.daily_event_counts_rebuild
SELECT account_id, toDate(occurred_at) AS day, event_name,
       uniqExactState(event_id) AS events
FROM analytics.events_canonical
GROUP BY account_id, day, event_name;

INSERT INTO analytics.page_views_by_route_rebuild
SELECT account_id, toDate(occurred_at) AS day, path(url) AS route,
       uniqExactState(event_id) AS views
FROM analytics.events_canonical
WHERE event_name = 'page_view'
GROUP BY account_id, day, route;

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

-- Each swap is atomic. The writer stays stopped across both. On interruption,
-- discard/rebuild the temporary tables and swap again from canonical data;
-- this works whether the public name has its old or its replacement schema.
EXCHANGE TABLES analytics.daily_event_counts AND analytics.daily_event_counts_rebuild;
EXCHANGE TABLES analytics.page_views_by_route AND analytics.page_views_by_route_rebuild;
DROP TABLE analytics.daily_event_counts_rebuild;
DROP TABLE analytics.page_views_by_route_rebuild;

-- Trigger inputs are the current inserted block. Distinct-ID states compose
-- across arbitrary retry batches, parts, restarts and old archive replays.
CREATE MATERIALIZED VIEW analytics.mv_daily_event_counts
TO analytics.daily_event_counts AS
SELECT account_id, toDate(occurred_at) AS day, event_name,
       uniqExactState(event_id) AS events
FROM analytics.events_raw
GROUP BY account_id, day, event_name;

CREATE MATERIALIZED VIEW analytics.mv_page_views_by_route
TO analytics.page_views_by_route AS
SELECT account_id, toDate(occurred_at) AS day, path(url) AS route,
       uniqExactState(event_id) AS views
FROM analytics.events_raw
WHERE event_name = 'page_view'
GROUP BY account_id, day, route;
