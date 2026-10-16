-- EP-33: additive private enrichment; no producer-chosen categorical columns.
-- Existing development facts retain unknown/version-zero enrichment. Reclassification
-- is an explicit rebuild operation, never an implicit change to accepted events.
ALTER TABLE analytics.events_raw
    ADD COLUMN IF NOT EXISTS browser_family LowCardinality(String) DEFAULT 'unknown',
    ADD COLUMN IF NOT EXISTS os_family LowCardinality(String) DEFAULT 'unknown',
    ADD COLUMN IF NOT EXISTS device_class LowCardinality(String) DEFAULT 'unknown',
    ADD COLUMN IF NOT EXISTS is_bot Bool DEFAULT false,
    ADD COLUMN IF NOT EXISTS channel LowCardinality(String) DEFAULT 'unknown',
    ADD COLUMN IF NOT EXISTS country_code LowCardinality(String) DEFAULT '',
    ADD COLUMN IF NOT EXISTS enrichment_version UInt16 DEFAULT 0,
    ADD COLUMN IF NOT EXISTS context_json JSON(max_dynamic_paths=256)
        MATERIALIZED CAST(if(isValidJSON(context),context,'{}') AS JSON(max_dynamic_paths=256));