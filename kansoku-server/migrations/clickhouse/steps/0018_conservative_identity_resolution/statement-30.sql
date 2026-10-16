
CREATE TABLE IF NOT EXISTS analytics.identity_context_signals
(
    account_id String, day Date,
    context_key Tuple(String,String,String,String),
    signal_kind LowCardinality(String), signal_value String
)
ENGINE = ReplacingMergeTree ORDER BY (account_id,day,context_key,signal_kind,signal_value);