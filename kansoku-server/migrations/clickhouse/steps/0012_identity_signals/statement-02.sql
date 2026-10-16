

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