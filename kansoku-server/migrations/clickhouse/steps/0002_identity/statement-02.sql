

-- Latest anonymous_id -> user_id mapping, one row per anonymous_id after merges.
-- `version` is the event's received_at; the newest mapping wins.
CREATE TABLE IF NOT EXISTS analytics.identity_map
(
    anonymous_id String,
    user_id      String,
    version      DateTime64(3, 'UTC')
)
ENGINE = ReplacingMergeTree(version)
ORDER BY anonymous_id;