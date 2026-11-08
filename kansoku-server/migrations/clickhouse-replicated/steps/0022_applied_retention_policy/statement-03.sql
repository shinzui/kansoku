
CREATE OR REPLACE VIEW analytics.events_canonical AS
SELECT *, properties_json, identity_context_key, context_json
FROM analytics.events_raw FINAL
WHERE occurred_at >= (SELECT argMax(cutoff,revision) FROM analytics.retention_policy);