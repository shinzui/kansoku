

CREATE OR REPLACE VIEW analytics.events_resolved_v3 AS
SELECT event_id,event_name,occurred_at,url,account_id,canonical_user,properties_json
FROM analytics.events_resolved_internal(scope_all_accounts=1,scope_account='',
    scope_from=toDateTime64('1970-01-01 00:00:00',3,'UTC'),scope_to=toDateTime64('2100-01-01 00:00:00',3,'UTC'));