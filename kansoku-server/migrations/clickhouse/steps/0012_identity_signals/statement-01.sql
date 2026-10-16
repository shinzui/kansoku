-- EP-18 M2: retain immutable identity-binding evidence and resolve anonymous
-- events through account-scoped, confidence-ranked identifier signals.
CREATE TABLE IF NOT EXISTS analytics.identity_signals
(
    account_id   String,
    signal_kind  LowCardinality(String),
    signal_value String,
    user_id      String,
    observed_at  DateTime64(3, 'UTC'),
    event_id     String
)
ENGINE = ReplacingMergeTree
ORDER BY (account_id, signal_kind, signal_value, user_id, observed_at, event_id)
TTL toDateTime(observed_at) + INTERVAL 180 DAY DELETE
    WHERE signal_kind = 'fingerprint';