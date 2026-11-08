-- Schema v2 for the raw events table: sort key (account_id, event_name,
-- occurred_at, event_id) and Nullable(String) -> String DEFAULT ''.
-- Strategy: build events_raw_v2, copy, EXCHANGE names, keep the old table
-- (now named events_raw_v2) until 0007 drops it after verification.
-- Every object reading events_raw is dropped first and recreated against the
-- new table with UNCHANGED v1 semantics; 0005/0006 change semantics later.

DROP TABLE IF EXISTS analytics.mv_identity_map;