-- The seven-column contract remains frozen; SELECT rights on these deliberate
-- projections do not require rights on the changing identity/storage relations.
ALTER TABLE analytics.events_resolved_v3 MODIFY SQL SECURITY DEFINER DEFINER = CURRENT_USER;
ALTER TABLE analytics.events_resolved MODIFY SQL SECURITY DEFINER DEFINER = CURRENT_USER;

-- Explicit bounded candidate parameters preserve conservative current identity
-- semantics without the HTTP connection's private Join-table cache.
CREATE OR REPLACE VIEW analytics.events_analytics_v1
DEFINER = CURRENT_USER SQL SECURITY DEFINER
AS SELECT
    event_id, event_name, occurred_at, url, account_id, canonical_user, properties_json,
    source, source_service, session_id, is_bot, browser_family, os_family,
    device_class, channel, country_code
FROM analytics.events_resolved_internal(
    scope_all_accounts=0, scope_account={account:String},
    scope_from={from_time:DateTime64(3, 'UTC')}, scope_to={to_time:DateTime64(3, 'UTC')});
