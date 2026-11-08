

-- Rebuild dau/wau contents under the new (raw-identity) semantics so the
-- tables are not a mix of stitched and unstitched day states. Column types
-- are unchanged in this migration (still AggregateFunction(uniqExact, String));
-- 0006 replaces the state type.
TRUNCATE TABLE analytics.dau;