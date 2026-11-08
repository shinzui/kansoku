
INSERT INTO analytics.identity_context_signals_rebuild
SELECT account_id,toDate(occurred_at),tuple(source_service,session_id,anonymous_id,identifiers),sig.1,sig.2
FROM analytics.events_canonical
ARRAY JOIN arrayDistinct(arrayFilter(kv -> kv.2!='',
    arrayConcat([('cookie',anonymous_id)],JSONExtractKeysAndValues(identifiers,'String')))) AS sig
WHERE user_id='';