
CREATE MATERIALIZED VIEW analytics.mv_identity_signal_users TO analytics.identity_signal_users AS
SELECT account_id, signal_kind, signal_value, user_id, max(observed_at) AS observed_at
FROM analytics.identity_signals GROUP BY account_id, signal_kind, signal_value, user_id;