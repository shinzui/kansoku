

-- Every raw-triggered projection filters the applied cutoff before updating state.
-- Keep the raw table inside the subquery so native insert-block triggers still fire.

DROP TABLE IF EXISTS analytics.mv_daily_event_counts;