
CREATE TABLE IF NOT EXISTS analytics.identity_signal_users
(
    account_id String, signal_kind LowCardinality(String), signal_value String, user_id String,
    observed_at SimpleAggregateFunction(max, DateTime64(3, 'UTC'))
)
ENGINE = AggregatingMergeTree ORDER BY (account_id, signal_kind, signal_value, user_id)
TTL toDateTime(observed_at) + INTERVAL 180 DAY + INTERVAL 1 SECOND DELETE WHERE signal_kind = 'fingerprint';