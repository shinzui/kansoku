-- EP-17 Milestone 1 chose a server-side native JSON materialized column.
-- Kansoku.ClickHouse.EventRow serializes properties from a parsed Aeson Object,
-- so every properties value written by the application is valid JSON.
ALTER TABLE analytics.events_raw
    ADD COLUMN IF NOT EXISTS properties_json JSON
    MATERIALIZED CAST(properties, 'JSON');

ALTER TABLE analytics.events_raw MATERIALIZE COLUMN properties_json;
