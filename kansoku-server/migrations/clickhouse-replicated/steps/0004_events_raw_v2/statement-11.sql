

-- ---- Recreate dependents against the new table, v1 semantics unchanged ----

CREATE MATERIALIZED VIEW analytics.mv_identity_map
TO analytics.identity_map
AS
SELECT
    anonymous_id,
    user_id,
    received_at AS version
FROM analytics.events_raw
WHERE event_name IN ('identify', 'alias')
  AND anonymous_id != ''
  AND user_id != '';