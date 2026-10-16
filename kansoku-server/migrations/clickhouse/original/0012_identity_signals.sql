-- EP-18 M2: retain immutable identity-binding evidence and resolve anonymous
-- events through account-scoped, confidence-ranked identifier signals.
CREATE TABLE IF NOT EXISTS analytics.identity_signals
(
    account_id   String,
    signal_kind  LowCardinality(String),
    signal_value String,
    user_id      String,
    observed_at  DateTime64(3, 'UTC'),
    event_id     String
)
ENGINE = ReplacingMergeTree
ORDER BY (account_id, signal_kind, signal_value, user_id, observed_at, event_id)
TTL toDateTime(observed_at) + INTERVAL 180 DAY DELETE
    WHERE signal_kind = 'fingerprint';

-- Cookie bindings retain the old identify/alias-only semantics. Explicit
-- identifier-map entries are binding evidence on any event carrying user_id.
CREATE MATERIALIZED VIEW IF NOT EXISTS analytics.mv_identity_signals
TO analytics.identity_signals
AS
SELECT
    account_id,
    sig.1 AS signal_kind,
    sig.2 AS signal_value,
    user_id,
    received_at AS observed_at,
    event_id
FROM analytics.events_raw
ARRAY JOIN arrayFilter(
    kv -> kv.1 != '' AND kv.2 != '',
    arrayConcat(
        [(if(event_name IN ('identify', 'alias'), 'cookie', ''), anonymous_id)],
        JSONExtractKeysAndValues(identifiers, 'String'))) AS sig
WHERE user_id != '';

-- Backfill the evidence that predates the materialized view. Replaying this
-- statement produces byte-identical rows, which the full ORDER BY key dedups.
INSERT INTO analytics.identity_signals
    (account_id, signal_kind, signal_value, user_id, observed_at, event_id)
SELECT
    account_id,
    sig.1 AS signal_kind,
    sig.2 AS signal_value,
    user_id,
    received_at AS observed_at,
    event_id
FROM analytics.events_raw
ARRAY JOIN arrayFilter(
    kv -> kv.1 != '' AND kv.2 != '',
    arrayConcat(
        [(if(event_name IN ('identify', 'alias'), 'cookie', ''), anonymous_id)],
        JSONExtractKeysAndValues(identifiers, 'String'))) AS sig
WHERE user_id != '';

-- Policy is view-time, so changing confidence later re-scores all history
-- without mutating evidence rows.
CREATE VIEW IF NOT EXISTS analytics.identity_bindings
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
FROM analytics.identity_signals;

-- Conflicting bindings stay visible rather than being collapsed by a
-- latest-wins table.
CREATE VIEW IF NOT EXISTS analytics.identity_conflicts
AS
SELECT
    account_id,
    signal_kind,
    signal_value,
    groupUniqArray(user_id) AS user_ids,
    uniqExact(user_id) AS user_count,
    count() AS observation_count,
    max(observed_at) AS last_observed_at
FROM analytics.identity_signals
GROUP BY account_id, signal_kind, signal_value
HAVING user_count > 1;

-- Resolve explicit user_id first, then the strongest and newest binding
-- reachable from the event's cookie or identifiers, then the raw cookie.
-- The ordered seven-column output is the contract recorded in ADR 0004.
CREATE VIEW IF NOT EXISTS analytics.events_resolved_v3
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
        FROM analytics.events_raw
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
FROM analytics.events_raw AS e
LEFT JOIN event_signal_users AS r
    ON r.account_id = e.account_id AND r.event_id = e.event_id;

DROP VIEW IF EXISTS analytics.events_resolved;
CREATE VIEW analytics.events_resolved
AS SELECT * FROM analytics.events_resolved_v3;
