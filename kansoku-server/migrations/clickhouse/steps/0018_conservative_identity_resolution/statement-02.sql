
ALTER TABLE analytics.events_raw MATERIALIZE COLUMN identity_context_key SETTINGS mutations_sync=2;