
CREATE TABLE analytics.identity_signals_rebuild
(
    account_id String, signal_kind LowCardinality(String), signal_value String,
    user_id String, observed_at DateTime64(3, 'UTC'), event_id String,
    received_at DateTime64(3, 'UTC'), source_service String, session_id String
)
ENGINE = ReplacingMergeTree
ORDER BY (account_id, signal_kind, signal_value, user_id, observed_at, event_id)
TTL toDateTime(observed_at) + INTERVAL 180 DAY + INTERVAL 1 SECOND DELETE WHERE signal_kind = 'fingerprint';