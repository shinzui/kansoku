-- Schema v2 for the raw events table: sort key (account_id, event_name,
-- occurred_at, event_id) and Nullable(String) -> String DEFAULT ''.
-- Strategy: build events_raw_v2, copy, EXCHANGE names, keep the old table
-- (now named events_raw_v2) until 0007 drops it after verification.
-- Every object reading events_raw is dropped first and recreated against the
-- new table with UNCHANGED v1 semantics; 0005/0006 change semantics later.

DROP TABLE IF EXISTS analytics.mv_identity_map;
DROP TABLE IF EXISTS analytics.mv_daily_event_counts;
DROP TABLE IF EXISTS analytics.mv_dau;
DROP TABLE IF EXISTS analytics.mv_wau;
DROP TABLE IF EXISTS analytics.mv_page_views_by_route;
DROP VIEW IF EXISTS analytics.events_resolved;
DROP TABLE IF EXISTS analytics.events_raw_v2;

CREATE TABLE analytics.events_raw_v2
(
    event_id               String,
    event_name             LowCardinality(String),
    source                 LowCardinality(String),
    source_service         String DEFAULT '',
    occurred_at            DateTime64(3, 'UTC'),
    received_at            DateTime64(3, 'UTC'),
    anonymous_id           String DEFAULT '',
    user_id                String,
    organization_id        String DEFAULT '',
    account_id             String,
    session_id             String DEFAULT '',
    url                    String DEFAULT '',
    referrer               String DEFAULT '',
    utm_source             LowCardinality(String) DEFAULT '',
    utm_medium             LowCardinality(String) DEFAULT '',
    utm_campaign           LowCardinality(String) DEFAULT '',
    utm_content            String DEFAULT '',
    utm_term               String DEFAULT '',
    correlation_id         String DEFAULT '',
    causation_id           String DEFAULT '',
    source_event_id        String DEFAULT '',
    source_global_position Nullable(UInt64),
    properties             String,
    context                String
)
ENGINE = ReplacingMergeTree(received_at)
PARTITION BY toYYYYMM(occurred_at)
ORDER BY (account_id, event_name, occurred_at, event_id);

INSERT INTO analytics.events_raw_v2
    (event_id, event_name, source, source_service, occurred_at, received_at,
     anonymous_id, user_id, organization_id, account_id, session_id, url,
     referrer, utm_source, utm_medium, utm_campaign, utm_content, utm_term,
     correlation_id, causation_id, source_event_id, source_global_position,
     properties, context)
SELECT
    event_id, event_name, source, coalesce(source_service, ''), occurred_at,
    received_at, coalesce(anonymous_id, ''), user_id,
    coalesce(organization_id, ''), account_id, coalesce(session_id, ''),
    coalesce(url, ''), coalesce(referrer, ''), coalesce(utm_source, ''),
    coalesce(utm_medium, ''), coalesce(utm_campaign, ''),
    coalesce(utm_content, ''), coalesce(utm_term, ''),
    coalesce(correlation_id, ''), coalesce(causation_id, ''),
    coalesce(source_event_id, ''), source_global_position, properties, context
FROM analytics.events_raw;

-- Atomic name swap: analytics.events_raw is now the v2 table; the old v1
-- table lives on under the name analytics.events_raw_v2 as the rollback copy.
EXCHANGE TABLES analytics.events_raw AND analytics.events_raw_v2;

-- ---- Recreate dependents against the new table, v1 semantics unchanged ----

CREATE MATERIALIZED VIEW analytics.mv_identity_map
TO analytics.identity_map
AS
SELECT
    anonymous_id,
    user_id,
    received_at AS version
FROM analytics.events_raw
WHERE event_name IN ('identify', 'alias')
  AND anonymous_id != ''
  AND user_id != '';

-- Still FINAL here; 0005 removes it.
CREATE VIEW analytics.events_resolved
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

CREATE MATERIALIZED VIEW analytics.mv_daily_event_counts
TO analytics.daily_event_counts
AS
SELECT
    toDate(occurred_at) AS day,
    event_name AS event_name,
    uniqExactState(toString(event_id)) AS events
FROM analytics.events_raw
GROUP BY day, event_name;

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

CREATE MATERIALIZED VIEW analytics.mv_wau
TO analytics.wau
AS
SELECT
    toMonday(e.occurred_at) AS week,
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
GROUP BY week;

CREATE MATERIALIZED VIEW analytics.mv_page_views_by_route
TO analytics.page_views_by_route
AS
SELECT
    toDate(occurred_at) AS day,
    path(url) AS route,
    uniqExactState(toString(event_id)) AS views
FROM analytics.events_raw
WHERE event_name = 'page_view'
GROUP BY day, route;
