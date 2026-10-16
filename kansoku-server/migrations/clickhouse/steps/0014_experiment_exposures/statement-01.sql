-- Experiment exposure rollup: unique users per account x experiment x variant x day.
--
-- Identity is the raw identity (user_id if present, else anonymous_id), matching
-- the join-free dau/wau rollups. An insert-time materialized view cannot apply
-- query-time identity resolution without freezing stale bindings. The exact,
-- stitched conversion and funnel endpoints read analytics.events_resolved.
--
-- IF NOT EXISTS plus the union semantics of uniqCombined states make a retry
-- after a partial failure safe: a repeated backfill only merges the same users.

CREATE TABLE IF NOT EXISTS analytics.experiment_exposures
(
    account_id String,
    experiment LowCardinality(String),
    variant    LowCardinality(String),
    day        Date,
    users      AggregateFunction(uniqCombined, String)
)
ENGINE = AggregatingMergeTree
ORDER BY (account_id, experiment, variant, day);