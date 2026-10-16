CREATE TABLE analytics.cohort_members
(
    account_id String,
    cohort_id String,
    user_id String,
    version DateTime64(3, 'UTC'),
    present UInt8
)
ENGINE = ReplacingMergeTree(version)
ORDER BY (account_id, cohort_id, user_id);
