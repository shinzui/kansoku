

-- Compact exact indexes retain one latest timestamp per observed signal/user,
-- and one per cookie/session/user. Max is replay-safe; evidence remains auditable.
DROP TABLE IF EXISTS analytics.mv_identity_signal_users;