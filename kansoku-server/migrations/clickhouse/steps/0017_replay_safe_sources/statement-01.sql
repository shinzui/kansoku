-- EP-30: one immutable logical event before analytical joins/aggregations.
-- Administrative migration: keep the writer stopped throughout. A failed run
-- can be reapplied: replacement states are rebuilt from canonical retained rows,
-- rather than appended to partially populated aggregate tables.
CREATE OR REPLACE VIEW analytics.events_canonical
AS SELECT *, properties_json FROM analytics.events_raw FINAL;