-- Account-scoped metrics. Keep the FINAL-free identity resolution and the
-- bounded v2 aggregate states while adding account_id to every query source.

DROP VIEW IF EXISTS analytics.events_resolved;