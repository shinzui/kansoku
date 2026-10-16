

CREATE OR REPLACE VIEW analytics.identity_bindings AS
SELECT account_id, signal_kind, signal_value, user_id, observed_at,
       multiIf(signal_kind IN ('email_hmac','email_sha256'), 0.95,
               signal_kind = 'cookie', 0.90, signal_kind = 'device', 0.80,
               signal_kind = 'fingerprint', 0.50, 0.0) AS confidence
FROM analytics.identity_signals FINAL
WHERE signal_kind != 'fingerprint' OR observed_at >= now64(3) - INTERVAL 180 DAY;