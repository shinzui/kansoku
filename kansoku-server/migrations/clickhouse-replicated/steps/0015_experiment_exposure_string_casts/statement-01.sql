-- Correct EP-19's materialized-view input-block behavior without editing the
-- already-applied 0014 migration. When a block contains no experiment paths,
-- getSubcolumn over JSON can retain Dynamic even after toString; ClickHouse 26
-- rejects that alias as a GROUP BY key before the event-name filter removes the
-- rows. An explicit outer String cast makes every ordinary event block safe.

DROP TABLE IF EXISTS analytics.mv_experiment_exposures;