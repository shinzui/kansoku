

CREATE TABLE IF NOT EXISTS analytics.trait_event_erasures
(account_id String,event_id String)
ENGINE=ReplicatedReplacingMergeTree ORDER BY (account_id,event_id);