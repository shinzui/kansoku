

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