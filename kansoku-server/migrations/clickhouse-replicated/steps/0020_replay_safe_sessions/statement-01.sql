-- EP-34: merge whole retained sessions, never per-block start-day groups.
-- The operator keeps writers stopped during migrations/rebuilds. Every state
-- is idempotent for immutable event IDs: sets, min/max and deterministic argmin/max.
DROP TABLE IF EXISTS analytics.mv_sessions;