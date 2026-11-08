-- FINAL-free identity resolution and join-free DAU/WAU.
-- events_resolved consumers aggregate with uniqExact/min, which are
-- insensitive to the transient duplicate rows FINAL would remove; row-COUNT
-- consumers must protect themselves (count DISTINCT event_id).
-- mv_dau/mv_wau stop joining the identity map at insert time and count raw
-- identities (user_id if present, else anonymous_id); the stitched number
-- stays available at query time through events_resolved.

DROP VIEW IF EXISTS analytics.events_resolved;