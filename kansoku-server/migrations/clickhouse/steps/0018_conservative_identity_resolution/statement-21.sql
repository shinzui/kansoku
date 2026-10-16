
INSERT INTO analytics.identity_signal_users_rebuild
SELECT account_id, signal_kind, signal_value, user_id, max(observed_at)
FROM analytics.identity_signals FINAL GROUP BY account_id, signal_kind, signal_value, user_id;