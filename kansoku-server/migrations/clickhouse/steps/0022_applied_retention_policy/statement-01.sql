-- Applied cutoff advances only through fenced kansoku-admin apply-retention.
-- Physical TTL cleanup is separate from the immediate canonical predicate.
CREATE TABLE IF NOT EXISTS analytics.retention_policy
(
    singleton UInt8,
    revision UInt64,
    cutoff DateTime64(3, 'UTC')
)
ENGINE = ReplacingMergeTree(revision) ORDER BY singleton;