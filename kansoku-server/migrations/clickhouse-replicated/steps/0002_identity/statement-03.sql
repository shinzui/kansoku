

-- Fill identity_map from identify/alias events as they arrive in events_raw.
-- Fires on each inserted block; ignores identity events missing either id.
CREATE MATERIALIZED VIEW IF NOT EXISTS analytics.mv_identity_map
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