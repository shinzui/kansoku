

-- ---------- Daily active users (canonical, resolved at insert time) ----------
-- NOTE: nullIf(m.user_id, '') is load-bearing (join_use_nulls = 0 fills a LEFT
-- JOIN miss with '', not NULL); the trailing '' keeps the argument a plain
-- String so the state stays AggregateFunction(uniqExact, String).
CREATE TABLE IF NOT EXISTS analytics.dau
(
    day   Date,
    users AggregateFunction(uniqExact, String)
)
ENGINE = AggregatingMergeTree
ORDER BY day;