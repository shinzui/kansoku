

INSERT INTO analytics.identity_signals_rebuild
SELECT account_id, sig.1, sig.2, user_id, occurred_at, event_id, received_at, source_service, session_id
FROM analytics.events_canonical
ARRAY JOIN arrayDistinct(arrayFilter(kv -> kv.1 != '' AND kv.2 != '',
    arrayConcat([(if(event_name IN ('identify','identify_once','alias'), 'cookie', ''), anonymous_id)],
                JSONExtractKeysAndValues(identifiers, 'String')))) AS sig
WHERE user_id != '';