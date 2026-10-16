-- EP-45: append the organization without changing the first seven columns.
-- Rollback (after reverting consumers):
-- CREATE OR REPLACE VIEW analytics.events_resolved_v3 DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
-- SELECT event_id,event_name,occurred_at,url,account_id,canonical_user,properties_json
-- FROM analytics.events_resolved_internal(scope_all_accounts=1,scope_account='',scope_from=toDateTime64('1970-01-01',3,'UTC'),scope_to=toDateTime64('2100-01-01',3,'UTC'));
-- CREATE OR REPLACE VIEW analytics.events_resolved DEFINER = CURRENT_USER SQL SECURITY DEFINER AS SELECT * FROM analytics.events_resolved_v3;
CREATE OR REPLACE VIEW analytics.events_resolved_v3
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS
SELECT event_id,event_name,occurred_at,url,account_id,canonical_user,properties_json,organization_id
FROM analytics.events_resolved_internal(scope_all_accounts=1,scope_account='',scope_from=toDateTime64('1970-01-01',3,'UTC'),scope_to=toDateTime64('2100-01-01',3,'UTC'));