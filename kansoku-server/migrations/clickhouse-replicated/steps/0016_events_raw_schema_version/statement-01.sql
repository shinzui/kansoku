ALTER TABLE analytics.events_raw
    ADD COLUMN IF NOT EXISTS schema_version UInt16 DEFAULT 1 AFTER identifiers;
