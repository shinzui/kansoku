

CREATE MATERIALIZED VIEW analytics.mv_identity_signals TO analytics.identity_signals AS
SELECT account_id, sig.1 AS signal_kind, sig.2 AS signal_value, user_id,
       occurred_at AS observed_at, event_id, received_at, source_service, session_id
FROM analytics.events_raw
ARRAY JOIN arrayDistinct(arrayFilter(kv -> kv.1 != '' AND kv.2 != '',
    arrayConcat([(if(event_name IN ('identify','identify_once','alias'), 'cookie', ''), anonymous_id)],
                JSONExtractKeysAndValues(identifiers, 'String')))) AS sig
WHERE user_id != '';