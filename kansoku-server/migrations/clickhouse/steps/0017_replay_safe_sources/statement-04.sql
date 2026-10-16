

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