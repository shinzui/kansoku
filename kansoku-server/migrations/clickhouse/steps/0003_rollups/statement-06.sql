

-- ---------- Weekly active users (canonical), keyed on the Monday of the week ----------
CREATE TABLE IF NOT EXISTS analytics.wau
(
    week  Date,
    users AggregateFunction(uniqExact, String)
)
ENGINE = AggregatingMergeTree
ORDER BY week;