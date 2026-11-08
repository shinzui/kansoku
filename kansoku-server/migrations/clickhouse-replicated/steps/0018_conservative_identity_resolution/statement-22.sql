
INSERT INTO analytics.identity_session_users_rebuild
SELECT account_id, source_service, session_id, signal_value, user_id, max(observed_at)
FROM analytics.identity_signals FINAL WHERE signal_kind = 'cookie' AND session_id != ''
GROUP BY account_id, source_service, session_id, signal_value, user_id;