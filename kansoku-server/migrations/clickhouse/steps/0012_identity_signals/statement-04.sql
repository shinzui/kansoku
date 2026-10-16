

-- Policy is view-time, so changing confidence later re-scores all history
-- without mutating evidence rows.
CREATE VIEW IF NOT EXISTS analytics.identity_bindings
AS
SELECT
    account_id,
    signal_kind,
    signal_value,
    user_id,
    observed_at,
    multiIf(
        signal_kind = 'email_sha256', 0.95,
        signal_kind = 'cookie',       0.90,
        signal_kind = 'device',       0.80,
        signal_kind = 'fingerprint',  0.50,
        0.0) AS confidence
FROM analytics.identity_signals;