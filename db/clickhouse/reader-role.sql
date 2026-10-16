-- Apply as the operator that owns/migrates the analytics views. This reserved
-- role is for trusted single-tenant SQL consumers, not per-account row security.
CREATE ROLE IF NOT EXISTS kansoku_reader;
GRANT SELECT ON analytics.events_resolved TO kansoku_reader;
GRANT SELECT ON analytics.events_resolved_v3 TO kansoku_reader;
GRANT SELECT ON analytics.events_analytics_v1 TO kansoku_reader;
CREATE SETTINGS PROFILE IF NOT EXISTS kansoku_reader_limits
SETTINGS readonly=2 CONST,
    max_execution_time=30 MIN 1 MAX 30,
    max_memory_usage=536870912 MIN 1 MAX 536870912,
    max_result_rows=10000 CONST,
    max_result_bytes=10485760 CONST,
    result_overflow_mode='throw' CONST,
    date_time_output_format='iso' CONST,
    max_threads=4 CONST
TO kansoku_reader;
