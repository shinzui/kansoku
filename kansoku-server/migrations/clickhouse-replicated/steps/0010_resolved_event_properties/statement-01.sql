-- Property-grouped unique-user metrics need the same typed property projection
-- as raw-event metrics while retaining canonical identity stitching.
DROP VIEW IF EXISTS analytics.events_resolved;