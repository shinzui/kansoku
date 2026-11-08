
CREATE OR REPLACE VIEW analytics.events_resolved
DEFINER = CURRENT_USER SQL SECURITY DEFINER AS SELECT * FROM analytics.events_resolved_v3;