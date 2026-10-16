
CREATE MATERIALIZED VIEW analytics.mv_identity_context_signals TO analytics.identity_context_signals AS
SELECT account_id,toDate(occurred_at) AS day,tuple(source_service,session_id,anonymous_id,identifiers) AS context_key,
       sig.1 AS signal_kind,sig.2 AS signal_value
FROM analytics.events_raw
ARRAY JOIN arrayDistinct(arrayFilter(kv -> kv.2!='',
    arrayConcat([('cookie',anonymous_id)],JSONExtractKeysAndValues(identifiers,'String')))) AS sig
WHERE user_id='';