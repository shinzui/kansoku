
CREATE MATERIALIZED VIEW analytics.mv_identity_session_users TO analytics.identity_session_users AS
SELECT account_id, source_service, session_id, signal_value, user_id, max(observed_at) AS observed_at
FROM analytics.identity_signals WHERE signal_kind = 'cookie' AND session_id != ''
GROUP BY account_id, source_service, session_id, signal_value, user_id;