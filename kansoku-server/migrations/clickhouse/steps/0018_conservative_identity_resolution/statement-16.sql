
CREATE TABLE IF NOT EXISTS analytics.identity_session_users
(
    account_id String, source_service String, session_id String, signal_value String, user_id String,
    observed_at SimpleAggregateFunction(max, DateTime64(3, 'UTC'))
)
ENGINE = AggregatingMergeTree ORDER BY (account_id, source_service, session_id, signal_value, user_id);