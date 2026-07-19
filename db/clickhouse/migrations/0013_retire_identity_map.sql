-- EP-18 M3: identity_signals and identity_bindings supersede the old
-- latest-wins cookie map. Migration 0012 backfilled equivalent cookie evidence,
-- and the pre-retirement stability battery preserved canonical-user results.
DROP TABLE IF EXISTS analytics.mv_identity_map;
DROP TABLE IF EXISTS analytics.identity_map;
