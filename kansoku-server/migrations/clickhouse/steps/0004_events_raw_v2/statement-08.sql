

CREATE TABLE analytics.events_raw_v2
(
    event_id               String,
    event_name             LowCardinality(String),
    source                 LowCardinality(String),
    source_service         String DEFAULT '',
    occurred_at            DateTime64(3, 'UTC'),
    received_at            DateTime64(3, 'UTC'),
    anonymous_id           String DEFAULT '',
    user_id                String,
    organization_id        String DEFAULT '',
    account_id             String,
    session_id             String DEFAULT '',
    url                    String DEFAULT '',
    referrer               String DEFAULT '',
    utm_source             LowCardinality(String) DEFAULT '',
    utm_medium             LowCardinality(String) DEFAULT '',
    utm_campaign           LowCardinality(String) DEFAULT '',
    utm_content            String DEFAULT '',
    utm_term               String DEFAULT '',
    correlation_id         String DEFAULT '',
    causation_id           String DEFAULT '',
    source_event_id        String DEFAULT '',
    source_global_position Nullable(UInt64),
    properties             String,
    context                String
)
ENGINE = ReplacingMergeTree(received_at)
PARTITION BY toYYYYMM(occurred_at)
ORDER BY (account_id, event_name, occurred_at, event_id);