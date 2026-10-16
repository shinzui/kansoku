

CREATE TABLE IF NOT EXISTS analytics.events_raw
(
    event_id               String,
    event_name             LowCardinality(String),
    source                 LowCardinality(String),
    source_service         Nullable(String),
    occurred_at            DateTime64(3, 'UTC'),
    received_at            DateTime64(3, 'UTC'),
    anonymous_id           Nullable(String),
    user_id                String,
    organization_id        Nullable(String),
    account_id             String,
    session_id             Nullable(String),
    url                    Nullable(String),
    referrer               Nullable(String),
    utm_source             Nullable(String),
    utm_medium             Nullable(String),
    utm_campaign           Nullable(String),
    utm_content            Nullable(String),
    utm_term               Nullable(String),
    correlation_id         Nullable(String),
    causation_id           Nullable(String),
    source_event_id        Nullable(String),
    source_global_position Nullable(UInt64),
    properties             String,
    context                String
)
ENGINE = ReplacingMergeTree(received_at)
PARTITION BY toYYYYMM(occurred_at)
ORDER BY (account_id, user_id, event_name, occurred_at, event_id);
