-- Final step of the events_raw v2 rewrite (0004): drop the retained v1 table.
-- 0004's row-count verification must have passed before this file is created.
DROP TABLE IF EXISTS analytics.events_raw_v2;
