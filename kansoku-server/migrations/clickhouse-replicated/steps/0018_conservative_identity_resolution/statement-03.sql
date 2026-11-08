
CREATE OR REPLACE VIEW analytics.events_canonical
AS SELECT *,properties_json,identity_context_key FROM analytics.events_raw FINAL;