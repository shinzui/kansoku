

-- Conflicting bindings stay visible rather than being collapsed by a
-- latest-wins table.
CREATE VIEW IF NOT EXISTS analytics.identity_conflicts
AS
SELECT
    account_id,
    signal_kind,
    signal_value,
    groupUniqArray(user_id) AS user_ids,
    uniqExact(user_id) AS user_count,
    count() AS observation_count,
    max(observed_at) AS last_observed_at
FROM analytics.identity_signals
GROUP BY account_id, signal_kind, signal_value
HAVING user_count > 1;