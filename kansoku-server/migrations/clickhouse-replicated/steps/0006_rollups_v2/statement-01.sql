-- Rollup states v2: bounded-size states instead of exact-distinct states that
-- stored every id. events/views: AggregateFunction(uniqExact, String) over
-- event_id -> AggregateFunction(count) (dedup makes duplicate rows rare and
-- transient, so count-vs-distinct drift is negligible; exactness lives in the
-- raw table). dau/wau users: uniqExact -> uniqCombined sketch (~0.8% error at
-- scale, exact for small sets). Tables are rebuilt (state types cannot be
-- ALTERed) and backfilled from events_raw.

DROP TABLE IF EXISTS analytics.mv_daily_event_counts;