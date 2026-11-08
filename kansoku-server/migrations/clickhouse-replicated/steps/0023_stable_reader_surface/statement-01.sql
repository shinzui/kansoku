-- The seven-column contract remains frozen; SELECT rights on these deliberate
-- projections do not require rights on the changing identity/storage relations.
ALTER TABLE analytics.events_resolved_v3 MODIFY SQL SECURITY DEFINER DEFINER = CURRENT_USER;