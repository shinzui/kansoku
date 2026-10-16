

-- Atomic name swap: analytics.events_raw is now the v2 table; the old v1
-- table lives on under the name analytics.events_raw_v2 as the rollback copy.
EXCHANGE TABLES analytics.events_raw AND analytics.events_raw_v2;